defmodule Pinchflat.Downloading.MediaDownloadWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :media_fetching,
    priority: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "media_fetching", "show_in_dashboard"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.FileSyncing
  alias Pinchflat.Downloading.MediaDownloader
  alias Pinchflat.Downloading.StagingCleaner
  alias Pinchflat.Lifecycle.Notifications.Notifier

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  # 4-hour timeout prevents infinite fragment retries from pinning a worker slot forever.
  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(4)

  @doc """
  Starts the media_item media download worker and creates a task for the media_item.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(media_item, job_args \\ %{}, job_opts \\ []) do
    %{id: media_item.id}
    |> Map.merge(job_args)
    |> MediaDownloadWorker.new(job_opts)
    |> Tasks.create_job_with_task(media_item)
  end

  @doc """
  For a given media item, download the media alongside any options.
  Does not download media if its source is set to not download media
  (unless forced).

  Options:
    - `force`: force download even if the source is set to not download media. Fully
      re-downloads media, including the video
    - `quality_upgrade?`: re-downloads media, including the video. Does not force download
      if the source is set to not download media

  Returns :ok | {:error, any, ...any}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => media_item_id} = args}) do
    should_force = Map.get(args, "force", false)
    is_quality_upgrade = Map.get(args, "quality_upgrade?", false)

    media_item = fetch_and_run_prevent_download_user_script(media_item_id)

    if should_download_media?(media_item, should_force, is_quality_upgrade) do
      download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force)
    else
      :ok
    end
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} stale")
  end

  # If this is a quality upgrade, only check if the source is set to download media
  # or that the media item's download hasn't been prevented
  defp should_download_media?(media_item, should_force, true = _is_quality_upgrade) do
    (media_item.source.download_media && !media_item.prevent_download) || should_force
  end

  # If it's not a quality upgrade, additionally check if the media item is pending download
  defp should_download_media?(media_item, should_force, _is_quality_upgrade) do
    source = media_item.source
    is_pending = Media.pending_download?(media_item)

    (is_pending && source.download_media && !media_item.prevent_download) || should_force
  end

  # If a user script exists and, when run, returns a non-zero exit code, prevent this and all future downloads
  # of the media item.
  defp fetch_and_run_prevent_download_user_script(media_item_id) do
    media_item = Media.get_media_item!(media_item_id)

    {:ok, media_item} =
      case run_user_script(:media_pre_download, media_item) do
        {:ok, _, exit_code} when exit_code != 0 ->
          Media.update_media_item(media_item, %{
            prevent_download: true,
            download_prevented_reason: "user_script"
          })

        _ ->
          {:ok, media_item}
      end

    Repo.preload(media_item, :source)
  end

  defp download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force) do
    overwrite_behaviour = if should_force || is_quality_upgrade, do: :force_overwrites, else: :no_force_overwrites
    override_opts = [overwrite_behaviour: overwrite_behaviour]

    # Clear any staging orphans left by a prior failed/abandoned/crashed attempt BEFORE starting,
    # so this attempt never inherits dirty staging state. No-op when local staging is disabled,
    # and a no-op on a first attempt (the per-item staging dir won't exist yet).
    StagingCleaner.clean(media_item)

    case MediaDownloader.download_for_media_item(media_item, override_opts) do
      {:ok, downloaded_media_item} ->
        {:ok, updated_media_item} =
          Media.update_media_item(downloaded_media_item, %{
            media_size_bytes: compute_media_filesize(downloaded_media_item),
            media_redownloaded_at: get_redownloaded_at(is_quality_upgrade),
            error_type: nil,
            last_error: nil
          })

        :ok = FileSyncing.delete_outdated_files(media_item, updated_media_item)

        # On success yt-dlp has already moved the finished files to their final location; remove
        # the now-empty (or stray-leftover) per-item staging dir so it doesn't accumulate across
        # re-downloads/quality-upgrades.
        StagingCleaner.clean(updated_media_item)

        run_user_script(:media_downloaded, updated_media_item)

        unless is_quality_upgrade do
          Notifier.notify(:download_finished, "Downloaded", item_text(media_item))
        end

        :ok

      {:recovered, _media_item, _message} ->
        {:error, :retry}

      {:error, :unsuitable_for_download, _message} ->
        {:ok, :non_retry}

      {:error, _error_atom, message} ->
        action_on_error(media_item, message)
    end
  end

  # "Title (Source)" for notifications
  defp item_text(media_item), do: "#{media_item.title} (#{media_item.source.custom_name})"

  # The first line of yt-dlp's error, without its "ERROR: [youtube] <id>:" prefix
  defp short_error(message) do
    message
    |> String.split("\n", trim: true)
    |> Enum.find("", &String.contains?(&1, "ERROR"))
    |> case do
      "" -> message |> String.split("\n", trim: true) |> List.first("Unknown error")
      line -> line
    end
    |> String.replace(~r/^ERROR:\s*(\[[^\]]+\]\s*)?([\w-]+:\s*)?/, "")
    |> String.slice(0, 200)
  end

  defp compute_media_filesize(media_item) do
    case File.stat(media_item.media_filepath) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp get_redownloaded_at(true), do: DateTime.utc_now()
  defp get_redownloaded_at(_), do: nil

  defp action_on_error(media_item, message) do
    message_str = to_string(message)

    # The download failed, so any files yt-dlp wrote into this item's staging dir are orphans.
    # Clear them now so they can't corrupt or confuse the next attempt. No-op when local staging
    # is disabled. Applies to every classification branch below.
    StagingCleaner.clean(media_item)

    cond do
      # PO Token errors: the bgutil POT provider sidecar is missing, unreachable, or the plugin
      # didn't load. These are TRANSIENT on purpose — retrying won't help until the sidecar is
      # running, but once it is, the item self-heals on the next retry with NO manual intervention
      # (unlike permanent, which sets prevent_download and would require manual un-prevention).
      # Checked BEFORE permanent_failure_strings so a token error never gets misfiled as permanent.
      # Distinct log line so logs point at the real cause (sidecar) rather than a generic retry.
      String.contains?(message_str, po_token_error_strings()) ->
        Logger.error(
          "yt-dlp download failed: PO Token unavailable (check the bgutil-provider sidecar is " <>
            "running and the plugin loaded). Will retry — item self-heals once tokens are available. " <>
            "#{inspect(message)}"
        )

        Media.update_media_item(media_item, %{
          error_type: "transient",
          last_error: message_str
        })

        {:error, :download_failed}

      # Members-only, and this source doesn't download members-only videos: it was never
      # wanted, so it's skipped (like one marked members-only at index time), not failed.
      # Indexing can't always tell members-only videos apart, so this is where they surface.
      members_skip?(message_str, media_item) ->
        Logger.info("Skipping members-only video #{media_item.id}: the source doesn't download members-only videos")

        Media.update_media_item(media_item, %{
          prevent_download: true,
          error_type: nil,
          last_error: message_str,
          availability: "subscriber_only",
          download_prevented_reason: "policy_members"
        })

        {:ok, :non_retry}

      String.contains?(message_str, permanent_failure_strings()) ->
        Logger.error("yt-dlp download permanently failed: #{inspect(message)}")

        Media.update_media_item(media_item, %{
          prevent_download: true,
          error_type: "permanent",
          last_error: message_str,
          download_prevented_reason: "permanent_error"
        })

        Notifier.notify(:download_failed, "Download failed", "#{item_text(media_item)}: #{short_error(message_str)}")

        {:ok, :non_retry}

      true ->
        Logger.error("yt-dlp download failed (will retry): #{inspect(message)}")

        Media.update_media_item(media_item, %{
          error_type: "transient",
          last_error: message_str
        })

        {:error, :download_failed}
    end
  end

  # A failure on a source that doesn't download members-only videos, for a video that is
  # members-only: yt-dlp says so, or the video is already known to be members-only (YouTube
  # sometimes just answers "Video unavailable" for those).
  defp members_skip?(message_str, media_item) do
    media_item.source.download_members_videos != true and
      (String.contains?(message_str, members_only_strings()) or
         (media_item.availability in ~w(subscriber_only premium_only needs_auth) and
            String.contains?(message_str, permanent_failure_strings())))
  end

  # yt-dlp's members-only errors (also in permanent_failure_strings/0). Same strings as the
  # 20261125000004 migration that reclassified existing failures.
  defp members_only_strings do
    [
      "This video is available to this channel's members",
      "members-only"
    ]
  end

  # PO Token error markers. The GVS-token warning yt-dlp emits is:
  #   "<client> client https formats require a GVS PO Token which was not provided"
  # We match the stable, distinctive fragments. NOTE: deliberately does NOT include the
  # "Sign in to confirm you're not a bot" string — that one is the bot-check (a different,
  # genuinely permanent condition already covered by permanent_failure_strings via "Sign in
  # to confirm"), and the sidecar does NOT reliably fix it. Keep these two concerns separate.
  defp po_token_error_strings do
    [
      "PO Token",
      "po_token",
      "youtubepot",
      "requires a GVS"
    ]
  end

  # NOTE: some of these strings (the members/sign-in ones) ALSO appear in
  # MediaDownloader.recoverable_cookie_errors/0. That overlap is intentional and
  # order-dependent: the downloader's cookie-retry runs FIRST during the download
  # attempt. We only reach this classifier after that retry was unavailable or also
  # failed, so by the time a members/sign-in error lands here it really is permanent.
  # If you edit one list, check the other.
  defp permanent_failure_strings do
    [
      # Deleted or removed
      "Video unavailable",
      "This video has been removed",
      "This video is not available",
      # Auth / age-gated
      "Sign in to confirm",
      "age-restricted",
      "requires payment",
      # Members / premium
      "This video is available to this channel's members",
      "members-only",
      "YouTube Premium",
      # Geo-blocked
      "not available in your country",
      "not available in your region",
      # Private
      "Private video"
    ]
  end

  # NOTE: I like this pattern of using the default value so that I don't have to
  # define it in config.exs (and friends). Consider using this elsewhere.
  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
