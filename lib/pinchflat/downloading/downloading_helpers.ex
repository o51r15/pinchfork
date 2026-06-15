defmodule Pinchflat.Downloading.DownloadingHelpers do
  @moduledoc """
  Methods for helping download media

  Many of these methods are made to be kickoff or be consumed by workers.
  """

  require Logger

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.MediaDownloadWorker

  @doc """
  Starts tasks for downloading media for any of a sources _pending_ media items.
  Jobs are not enqueued if the source is set to not download media. This will return :ok.

  NOTE: this starts a download for each media item that is pending,
  not just the ones that were indexed in this job run. This should ensure
  that any stragglers are caught if, for some reason, they weren't enqueued
  or somehow got de-queued.

  Returns :ok
  """
  def enqueue_pending_download_tasks(source, job_opts \\ [])

  def enqueue_pending_download_tasks(%Source{download_media: true} = source, job_opts) do
    source
    |> Media.list_pending_media_items_for()
    |> Enum.each(&MediaDownloadWorker.kickoff_with_task(&1, %{}, job_opts))
  end

  def enqueue_pending_download_tasks(%Source{download_media: false}, _job_opts) do
    :ok
  end

  @doc """
  Deletes ALL pending tasks for a source's media items.

  Returns :ok
  """
  def dequeue_pending_download_tasks(%Source{} = source) do
    source
    |> Media.list_pending_media_items_for()
    |> Enum.each(&Tasks.delete_pending_tasks_for/1)
  end

  @doc """
  Takes a single media item and enqueues a download job if the media should be
  downloaded, based on the source's download settings and whether media is
  considered pending.

  Returns {:ok, %Task{}} | {:error, :should_not_download} | {:error, any()}
  """
  def kickoff_download_if_pending(%MediaItem{} = media_item, job_opts \\ []) do
    media_item = Repo.preload(media_item, :source)

    if media_item.source.download_media && Media.pending_download?(media_item) do
      Logger.info("Kicking off download for media item ##{media_item.id} (#{media_item.media_id})")

      MediaDownloadWorker.kickoff_with_task(media_item, %{}, job_opts)
    else
      {:error, :should_not_download}
    end
  end

  @doc """
  For a given source, enqueues download jobs for all media items _that have already been downloaded_.

  This is useful for when a source's download settings have changed and you want to run through all
  existing media and retry the download. For instance, if the source didn't originally download thumbnails
  and you've changed the source to download them, you can use this to download all the thumbnails for
  existing media items.

  NOTE: does not delete existing files whatsoever. Does not overwrite the existing media file if it exists
  at the location it expects. Will cause a full redownload of everything if the output template has changed

  NOTE: unrelated to the MediaQualityUpgradeWorker, which is for redownloading media items for quality upgrades
  or improved sponsorblock segments

  Returns [{:ok, %Task{}} | {:error, any()}]
  """
  def kickoff_redownload_for_existing_media(%Source{} = source) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(
      ^dynamic(
        [m, s, mp],
        ^MediaQuery.for_source(source) and
          ^MediaQuery.downloaded() and
          not (^MediaQuery.download_prevented())
      )
    )
    |> Repo.all()
    |> Enum.map(&MediaDownloadWorker.kickoff_with_task/1)
  end

  @doc """
  Forces a media item that is currently waiting on a retry backoff to be attempted NOW,
  rather than waiting for its scheduled retry time.

  Used by the home page "Retry" tab's "Retry Now" button. This is the gentle action: it does
  NOT clear the item's error fields (only a successful download clears those) — it simply moves
  the existing retry up to now. It finds the item's existing MediaDownloadWorker job in a
  retryable/scheduled/available state and reschedules it to run immediately via Oban.

  Returns :ok | {:error, :no_retryable_job}
  """
  def retry_now(%MediaItem{} = media_item) do
    # Find the item's MediaDownloadWorker job(s) sitting in a not-yet-run state, reachable via the
    # tasks join. NOTE: oban_jobs.state is a Postgres enum (oban_job_state), not text — Ecto won't
    # auto-cast it to match plain string literals, so we cast to text in a fragment (same fix as
    # the Retry-tab countdown query). Without the cast the comparison silently matches nothing,
    # which would make this button appear to do nothing.
    job_ids =
      from(t in Pinchflat.Tasks.Task,
        join: j in assoc(t, :job),
        where: t.media_item_id == ^media_item.id,
        where: like(j.worker, "%MediaDownloadWorker"),
        where: fragment("?::text", j.state) in ["available", "scheduled", "retryable"],
        select: j.id
      )
      |> Repo.all()

    case job_ids do
      [] ->
        {:error, :no_retryable_job}

      ids ->
        # Move the job(s) to run immediately. Setting state to available with scheduled_at = now
        # makes Oban pick them up on the next poll regardless of the remaining backoff. last_error
        # is intentionally left untouched (only a successful download clears it).
        from(j in Oban.Job, where: j.id in ^ids)
        |> Repo.update_all(set: [state: "available", scheduled_at: DateTime.utc_now()])

        Logger.info("Forced immediate retry for media item ##{media_item.id} (#{media_item.media_id})")

        :ok
    end
  end

  @doc """
  Fully resets a failed media item and re-queues it from scratch.

  Used by the home page "Failed" tab's "Force Retry" button (behind a confirmation prompt).
  Unlike `retry_now/1`, this WIPES the item's error state — error_type, last_error, and the
  error-driven prevent_download flag — and starts a brand-new download attempt.

  Because the old Oban job may be discarded/cancelled/pruned (a permanently-failed item is not
  in a retryable state), we do NOT try to mutate it. Instead we delete any lingering tasks/jobs
  for the item (which also clears the unique-job constraint that would otherwise block a new
  job) and then kick off a fresh download via the normal path.

  Returns {:ok, %Task{}} | {:error, any()}
  """
  def force_retry(%MediaItem{} = media_item) do
    {:ok, cleared_media_item} =
      Media.update_media_item(media_item, %{
        error_type: nil,
        last_error: nil,
        prevent_download: false
      })

    # Remove any existing tasks/jobs (any state) so the unique constraint won't reject the new
    # job and no stale job lingers. Cancels attached Oban jobs as part of deletion.
    Tasks.delete_tasks_for(cleared_media_item, "MediaDownloadWorker")

    cleared_media_item = Repo.preload(cleared_media_item, :source, force: true)

    Logger.info("Force-retrying media item ##{cleared_media_item.id} (#{cleared_media_item.media_id})")

    MediaDownloadWorker.kickoff_with_task(cleared_media_item)
  end
end
