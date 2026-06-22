defmodule PinchflatWeb.Sources.SourceController do
  use PinchflatWeb, :controller
  use Pinchflat.Sources.SourcesQuery
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  def index(conn, _params) do
    sources =
      from(s in Source,
        where: is_nil(s.marked_for_deletion_at),
        order_by: [asc: s.custom_name]
      )
      |> Repo.all()

    source_ids = Enum.map(sources, & &1.id)

    counts_by_source =
      from(mi in MediaItem,
        where: mi.source_id in ^source_ids,
        group_by: mi.source_id,
        select: {
          mi.source_id,
          %{
            total: count(mi.id),
            downloaded: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", mi.media_filepath))
          }
        }
      )
      |> Repo.all()
      |> Map.new()

    render(conn, :index, sources: sources, counts_by_source: counts_by_source)
  end

  # Serves the poster image for a source. Falls back to an SVG placeholder
  # with the source's initial when no poster file exists on disk.
  def poster(conn, %{"id" => id}) do
    source = Sources.get_source!(id)

    poster_path =
      source.poster_filepath ||
        case Repo.preload(source, :metadata) do
          %{metadata: %{poster_filepath: path}} when not is_nil(path) -> path
          _ -> nil
        end

    if poster_path && File.exists?(poster_path) do
      mime_type =
        case Path.extname(poster_path) |> String.downcase() do
          ".png" -> "image/png"
          ".webp" -> "image/webp"
          _ -> "image/jpeg"
        end

      conn
      |> put_resp_content_type(mime_type)
      |> send_file(200, poster_path)
    else
      initial = (source.custom_name || source.collection_name || "?") |> String.first() |> String.upcase()

      svg = """
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 300">
        <rect width="200" height="300" fill="#1c2333"/>
        <text x="100" y="175" text-anchor="middle" dominant-baseline="middle"
              font-size="110" font-family="sans-serif" font-weight="bold" fill="#374151">
          #{initial}
        </text>
      </svg>
      """

      conn
      |> put_resp_content_type("image/svg+xml")
      |> send_resp(200, svg)
    end
  end

  # Serves the fanart (banner) image for a source. Falls back to a dark SVG
  # gradient when no fanart file exists — used as the show page header background.
  def fanart(conn, %{"id" => id}) do
    source = Sources.get_source!(id)

    fanart_path =
      source.fanart_filepath ||
        case Repo.preload(source, :metadata) do
          %{metadata: %{fanart_filepath: path}} when not is_nil(path) -> path
          _ -> nil
        end

    if fanart_path && File.exists?(fanart_path) do
      mime_type =
        case Path.extname(fanart_path) |> String.downcase() do
          ".png" -> "image/png"
          ".webp" -> "image/webp"
          _ -> "image/jpeg"
        end

      conn
      |> put_resp_content_type(mime_type)
      |> send_file(200, fanart_path)
    else
      svg = """
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 720">
        <defs>
          <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stop-color="#111827"/>
            <stop offset="100%" stop-color="#1f2937"/>
          </linearGradient>
        </defs>
        <rect width="1280" height="720" fill="url(#bg)"/>
      </svg>
      """

      conn
      |> put_resp_content_type("image/svg+xml")
      |> send_resp(200, svg)
    end
  end

  def new(conn, params) do
    # This lets me preload the settings from another source for more efficient creation
    cs_struct =
      case to_string(params["template_id"]) do
        "" -> %Source{}
        template_id -> Repo.get(Source, template_id) || %Source{}
      end

    render(conn, :new,
      media_profiles: media_profiles(),
      layout: get_onboarding_layout(),
      # Most of these don't actually _need_ to be nullified at this point,
      # but if I don't do it now I know it'll bite me
      changeset:
        Sources.change_source(%Source{
          cs_struct
          | id: nil,
            uuid: nil,
            custom_name: nil,
            description: nil,
            collection_name: nil,
            collection_id: nil,
            collection_type: nil,
            original_url: nil,
            marked_for_deletion_at: nil
        })
    )
  end

  def create(conn, %{"source" => source_params}) do
    case Sources.create_source(source_params) do
      {:ok, source} ->
        conn
        |> put_flash(:info, "Source created successfully.")
        |> redirect(to: ~p"/sources/#{source}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new,
          changeset: changeset,
          media_profiles: media_profiles(),
          layout: get_onboarding_layout()
        )
    end
  end

  def show(conn, %{"id" => id}) do
    source = Repo.preload(Sources.get_source!(id), :media_profile)

    pending_tasks =
      source
      |> Tasks.list_tasks_for(nil, [:executing, :available, :scheduled, :retryable])
      |> Repo.preload(:job)

    base_stats =
      from(mi in MediaItem,
        where: mi.source_id == ^source.id,
        select: %{
          total: count(mi.id),
          downloaded: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", mi.media_filepath)),
          # Permanently failed items also have prevent_download = true, so exclude them from
          # the prevented count to avoid double-counting across the two buckets.
          failed: count(fragment("CASE WHEN ?::text = 'permanent' THEN 1 END", mi.error_type)),
          # Only count items the USER explicitly prevented — manual eye-off or user script.
          # Policy-stamped items (policy_members, policy_public, etc.) are system-driven and
          # belong in the skipped bucket, not here.
          prevented: count(fragment("CASE WHEN ?::text IN ('manual', 'user_script') THEN 1 END", mi.download_prevented_reason)),
          # Retrying items have a transient error but are not yet downloaded or prevented.
          # We track them so they can be subtracted when computing the skipped remainder.
          retrying: count(fragment("CASE WHEN ?::text = 'transient' AND ? IS NULL AND ? = false THEN 1 END", mi.error_type, mi.media_filepath, mi.prevent_download))
        }
      )
      |> Repo.one()

    # Use the full staged_pending logic (joins through source → media_profile) so that
    # shorts, livestreams, members-only content, and cutoff-date items are NOT counted
    # as pending in the stats bar.
    pending_count =
      MediaQuery.new()
      |> MediaQuery.require_assoc(:media_profile)
      |> where(^MediaQuery.for_source(source))
      |> where(^dynamic(^MediaQuery.staged_pending()))
      |> Repo.aggregate(:count, :id)

    # Skipped = items the system filtered out (shorts, live, members-only, cutoff, duration,
    # regex) — evaluated dynamically by staged_pending/0 so not stamped on the row.
    # Computed as the arithmetic remainder after all other known states are subtracted.
    skipped =
      base_stats.total - base_stats.downloaded - pending_count -
        base_stats.failed - base_stats.prevented - base_stats.retrying

    counts =
      base_stats
      |> Map.put(:pending, pending_count)
      |> Map.put(:skipped, skipped)

    render(conn, :show, source: source, pending_tasks: pending_tasks, counts: counts)
  end

  def edit(conn, %{"id" => id}) do
    source = Sources.get_source!(id)
    changeset = Sources.change_source(source)

    render(conn, :edit, source: source, changeset: changeset, media_profiles: media_profiles())
  end

  def update(conn, %{"id" => id, "source" => source_params}) do
    source = Sources.get_source!(id)

    case Sources.update_source(source, source_params) do
      {:ok, source} ->
        conn
        |> put_flash(:info, "Source updated successfully.")
        |> redirect(to: ~p"/sources/#{source}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit,
          source: source,
          changeset: changeset,
          media_profiles: media_profiles()
        )
    end
  end

  def delete(conn, %{"id" => id} = params) do
    # This awkward comparison converts the string to a boolean
    delete_files = Map.get(params, "delete_files", "") == "true"
    source = Sources.get_source!(id)

    {:ok, _} = Sources.update_source(source, %{marked_for_deletion_at: DateTime.utc_now()})
    SourceDeletionWorker.kickoff(source, %{delete_files: delete_files})

    conn
    |> put_flash(:info, "Source deletion started. This may take a while to complete.")
    |> redirect(to: ~p"/sources")
  end

  def force_download_pending(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing download of pending media items.",
      &DownloadingHelpers.enqueue_pending_download_tasks/1
    )
  end

  def force_redownload(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing re-download of downloaded media items.",
      &DownloadingHelpers.kickoff_redownload_for_existing_media/1
    )
  end

  def force_index(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Index enqueued.",
      &SlowIndexingHelpers.kickoff_indexing_task(&1, %{force: true})
    )
  end

  def force_metadata_refresh(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Metadata refresh enqueued.",
      &SourceMetadataStorageWorker.kickoff_with_task/1
    )
  end

  def sync_files_on_disk(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "File sync enqueued.",
      &FileSyncingWorker.kickoff_with_task/1
    )
  end

  defp wrap_forced_action(conn, source_id, message, fun) do
    source = Sources.get_source!(source_id)
    fun.(source)

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/sources/#{source}")
  end

  defp media_profiles do
    MediaProfile
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp get_onboarding_layout do
    {Layouts, :app}
  end
end
