defmodule Pinchflat.Profiles.OutputPathPreview do
  @moduledoc """
  Shows roughly where a download would land for a file name template, so people can see the
  folder layout while they type. yt-dlp works out the real path at download time; this fills in
  the common fields from a real video (or a made-up one) and marks anything it can't know.
  """

  alias Pinchflat.Downloading.OutputPathBuilder

  @ytdlp_field ~r/%\(([^)]*)\)[a-zA-Z]/

  @doc """
  A stand-in video for when the library has nothing to show yet.
  """
  def sample do
    %{
      title: "How to Build a Bookshelf",
      media_id: "aBcD123xYz0",
      uploaded_at: ~U[2024-03-09 15:00:00Z],
      duration_seconds: 754,
      playlist_index: 3,
      upload_date_index: 0,
      id: 1,
      source: %{
        id: 1,
        custom_name: "Example Channel",
        collection_id: "UCexample",
        collection_name: "Example Channel",
        collection_type: :channel,
        media_profile_id: 1
      }
    }
  end

  @doc """
  Builds the preview path, relative to the downloads folder. `video` is a media item with its
  source loaded, or `sample/0`. `ext` is the file extension to show.

  Returns {:ok, binary()} | :error
  """
  def build(template, video, ext) when is_binary(template) and template != "" do
    case OutputPathBuilder.build(template, custom_options(video)) do
      {:ok, ytdlp_template} ->
        {:ok, Regex.replace(@ytdlp_field, ytdlp_template, fn _match, inner -> fill(inner, video, ext) end)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  def build(_template, _video, _ext), do: :error

  @doc """
  The file extension a profile would produce, for the preview. Audio kept in its original
  format could be several things, so that's left for yt-dlp (nil).
  """
  def extension(resolution, container) when container in [nil, ""] do
    if to_string(resolution) == "audio", do: nil, else: "mp4"
  end

  def extension(_resolution, container), do: container

  defp custom_options(video) do
    source = video.source

    %{
      "media_item_id" => to_string(video.id),
      "source_id" => to_string(source.id),
      "media_profile_id" => to_string(source.media_profile_id),
      "source_custom_name" => source.custom_name,
      "source_collection_id" => source.collection_id,
      "source_collection_name" => source.collection_name,
      "source_collection_type" => to_string(source.collection_type),
      "media_playlist_index" => pad(video.playlist_index),
      "media_upload_date_index" => pad(video.upload_date_index)
    }
  end

  # One yt-dlp field, like "title", "upload_date>%Y-%m-%d" or "artist,creator,uploader|Unknown"
  defp fill(inner, video, ext) do
    {fields, default} =
      case String.split(inner, "|", parts: 2) do
        [fields, default] -> {fields, default}
        [fields] -> {fields, nil}
      end

    {names, format} =
      case String.split(fields, ">", parts: 2) do
        [names, format] -> {names, format}
        [names] -> {names, nil}
      end

    names
    |> String.split(",", trim: true)
    |> Enum.find_value(&value(String.trim(&1), video, ext))
    |> case do
      nil -> default || "‹#{names}›"
      value -> format_value(value, format)
    end
  end

  defp value("title", video, _ext), do: video.title
  defp value("fulltitle", video, _ext), do: video.title
  defp value("id", video, _ext), do: video.media_id
  defp value("ext", _video, ext), do: ext
  defp value(name, video, _ext) when name in ~w(uploader channel), do: video.source.collection_name
  defp value(name, video, _ext) when name in ~w(uploader_id channel_id), do: video.source.collection_id
  defp value("upload_date", video, _ext), do: video.uploaded_at && DateTime.to_date(video.uploaded_at)
  defp value("duration", video, _ext), do: video.duration_seconds && to_string(video.duration_seconds)
  defp value("duration_string", video, _ext), do: video.duration_seconds && duration_string(video.duration_seconds)
  defp value("playlist_index", video, _ext), do: pad(video.playlist_index)
  defp value(_name, _video, _ext), do: nil

  defp format_value(%Date{} = date, nil), do: Calendar.strftime(date, "%Y%m%d")
  defp format_value(%Date{} = date, format), do: Calendar.strftime(date, format)
  defp format_value(value, _format), do: to_string(value)

  defp duration_string(seconds) do
    {h, rest} = {div(seconds, 3600), rem(seconds, 3600)}
    {m, s} = {div(rest, 60), rem(rest, 60)}
    two = &String.pad_leading(to_string(&1), 2, "0")

    if h > 0, do: "#{h}:#{two.(m)}:#{two.(s)}", else: "#{m}:#{two.(s)}"
  end

  defp pad(nil), do: "00"
  defp pad(integer), do: integer |> to_string() |> String.pad_leading(2, "0")
end
