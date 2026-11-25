defmodule PinchflatWeb.MediaItems.MediaItemController do
  use PinchflatWeb, :controller
  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.SkipReason
  alias Pinchflat.Downloading.MediaDownloadWorker

  def show(conn, %{"id" => id}) do
    media_item =
      id
      |> Media.get_media_item!()
      |> Repo.preload(source: :media_profile, tasks: [:job])

    jobs =
      media_item.tasks
      |> Enum.filter(&(&1.job && to_string(&1.job.state) in ~w(executing available scheduled retryable)))
      |> Enum.sort_by(& &1.job.scheduled_at, {:desc, DateTime})

    render(conn, :show,
      media_item: media_item,
      status: status(media_item),
      jobs: jobs,
      page_title: media_item.title
    )
  end

  # The two switches used to live on their own edit page; they're on the video page now
  def edit(conn, %{"id" => id}) do
    media_item = Media.get_media_item!(id)

    redirect(conn, to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")
  end

  def update(conn, %{"id" => id, "media_item" => params}) do
    media_item = Media.get_media_item!(id)

    case Media.update_media_item(media_item, switch_attrs(media_item, params)) do
      {:ok, media_item} ->
        conn
        |> put_flash(:info, "Saved.")
        |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "That couldn't be saved.")
        |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")
    end
  end

  # Turning automatic download off records it as the person's choice, so the video shows as
  # "Turned off" rather than skipped. Turning it back on clears that, and a permanent failure
  # with it, so the video is tried again.
  defp switch_attrs(media_item, params) do
    attrs = Map.take(params, ~w(prevent_download prevent_culling))

    case attrs["prevent_download"] do
      "true" when not media_item.prevent_download ->
        Map.put(attrs, "download_prevented_reason", "manual")

      "false" when media_item.prevent_download ->
        attrs
        |> Map.put("download_prevented_reason", nil)
        |> then(&if(to_string(media_item.error_type) == "permanent", do: Map.put(&1, "error_type", nil), else: &1))

      _ ->
        attrs
    end
  end

  # Where this video stands, as {state, detail}. Same buckets as the source page's counts.
  defp status(%MediaItem{} = item) do
    source = item.source
    prevented = to_string(item.download_prevented_reason)

    cond do
      item.media_filepath -> {:downloaded, nil}
      to_string(item.error_type) == "permanent" -> {:failed, nil}
      prevented in ["manual", "user_script"] -> {:off, prevented}
      prevented == "policy_other" -> {:skipped, :unavailable}
      pending?(item) -> {if(item.last_error, do: :retrying, else: :pending), nil}
      to_string(item.error_type) == "transient" and not item.prevent_download -> {:retrying, nil}
      item.culled_at -> {:removed, source.retention_period_days}
      true -> {:skipped, SkipReason.for_item(item, source, source.media_profile)}
    end
  end

  defp pending?(item) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where([mi], mi.id == ^item.id)
    |> where(^dynamic(^MediaQuery.staged_pending()))
    |> Repo.exists?()
  end

  def delete(conn, %{"id" => id} = params) do
    # F5: normalize string param to boolean — query params arrive as strings, not booleans
    prevent_download = Map.get(params, "prevent_download", "") == "true"
    media_item = Media.get_media_item!(id)
    {:ok, _} = Media.delete_media_files(media_item, %{prevent_download: prevent_download})

    message =
      if prevent_download,
        do: "Files deleted. This video won't be downloaded again.",
        else: "Files deleted."

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")
  end

  def force_download(conn, %{"media_item_id" => id}) do
    media_item = Media.get_media_item!(id)

    :ok =
      case MediaDownloadWorker.kickoff_with_task(media_item, %{force: true}) do
        {:ok, _} -> :ok
        {:error, :duplicate_job} -> :ok
        err -> err
      end

    conn
    |> put_flash(:info, "Download queued. It'll start in a moment.")
    |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")
  end

  # See here for details on streaming files and range requests:
  # https://www.zeng.dev/post/2023-http-range-and-play-mp4-in-browser/
  #
  # Uses the UUID instead of the ID to avoid enumeration attacks
  # since streaming is a public endpoint (ie: no auth required)
  def stream(conn, %{"uuid" => uuid}) do
    media_item = Repo.get_by!(MediaItem, uuid: uuid)

    if File.exists?(media_item.media_filepath) do
      file_size = File.stat!(media_item.media_filepath).size
      mime_type = MIME.from_path(media_item.media_filepath)

      # S1+S5: strip CR/LF/quotes from title before embedding in response header.
      # media_item.title comes from yt-dlp metadata (untrusted); a title containing
      # \r\n would allow CRLF injection into response headers on this unauthenticated endpoint.
      safe_title = String.replace(media_item.title, ~r/[\r\n"]/, " ")

      case parse_range(conn, file_size) do
        {:ok, {start_pos, end_pos}} ->
          Logger.debug("Streaming media item: #{media_item.uuid} from #{start_pos} to #{end_pos}")
          length = end_pos - start_pos + 1

          conn
          |> put_resp_content_type(mime_type)
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-range", "bytes #{start_pos}-#{end_pos}/#{file_size}")
          |> put_resp_header("content-length", to_string(length))
          |> put_resp_header("content-disposition", "inline; filename=\"#{safe_title}\"")
          |> send_file(206, media_item.media_filepath, start_pos, length)

        {:error, :invalid_range} ->
          Logger.debug("Invalid range request for media item: #{media_item.uuid} - serving full file")

          conn
          |> put_resp_content_type(mime_type)
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-range", "bytes 0-#{file_size - 1}/#{file_size}")
          |> put_resp_header("content-length", to_string(file_size))
          |> put_resp_header("content-disposition", "inline; filename=\"#{safe_title}\"")
          |> send_file(200, media_item.media_filepath)
      end
    else
      send_resp(conn, 404, "File not found")
    end
  end

  defp parse_range(conn, file_size) do
    with [range_header | _] <- get_req_header(conn, "range"),
         ["bytes", range] <- String.split(range_header, "="),
         [start_pos, end_pos] <- String.split(range, "-") do
      validate_range(start_pos, end_pos, file_size)
    else
      _ -> {:error, :invalid_range}
    end
  end

  defp validate_range(start_pos, end_pos, file_size) do
    case {Integer.parse(start_pos), Integer.parse(end_pos)} do
      {:error, :error} ->
        {:error, :invalid_range}

      {{start_pos, _}, :error} ->
        {:ok, {start_pos, file_size - 1}}

      # See RFC7233
      {{start_pos, _}, {end_pos, _}} when end_pos >= file_size ->
        {:ok, {start_pos, file_size - 1}}

      {{start_pos, _}, {end_pos, _}} ->
        {:ok, {start_pos, end_pos}}

      # B2: catch-all for any unmatched combination (e.g. non-numeric start with numeric end).
      # Without this, Integer.parse returning {:error, {n, ""}} raises CaseClauseError
      # on this unauthenticated public endpoint.
      _ ->
        {:error, :invalid_range}
    end
  end
end
