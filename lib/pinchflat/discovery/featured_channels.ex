defmodule Pinchflat.Discovery.FeaturedChannels do
  @moduledoc """
  Generator G2 — crawls the "Channels" tab of each existing source to find
  featured/recommended channels. Uses yt-dlp --flat-playlist, zero API quota.

  Channels featured by 2+ of the user's sources are near-certain hits.
  """

  require Logger

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  @sleep_between_sources_ms 2_000

  @doc """
  Crawls the /channels tab for every channel-type source and returns aggregated
  candidates sorted by how many sources feature them.

  Each candidate:
    %{
      identifier: "UCxxxxxx",
      identifier_type: :channel_id,
      name: "Channel Name" | nil,
      featured_by_source_ids: MapSet.t(),
      featured_by_count: integer,
      score: float
    }
  """
  def crawl do
    sources = list_channel_sources()
    Logger.info("[Discovery G2] Crawling featured channels for #{length(sources)} sources")

    sources
    |> Enum.with_index()
    |> Enum.flat_map(fn {source, index} ->
      # Space out the channel-tab crawls — these hit YouTube from the same IP (and cookies)
      # the downloads use, so a tight burst risks tripping the bot check for everything.
      if index > 0, do: Process.sleep(@sleep_between_sources_ms)
      crawl_source(source)
    end)
    |> aggregate()
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp list_channel_sources do
    # Only channel sources have a /channels tab; playlists don't
    from(s in Source,
      where: not is_nil(s.collection_id),
      select: %{id: s.id, original_url: s.original_url, collection_id: s.collection_id}
    )
    |> Repo.all()
    |> Enum.reject(fn s -> String.contains?(s.original_url, "playlist?list=") end)
  end

  defp crawl_source(source) do
    channels_url = channels_tab_url(source.original_url)
    Logger.info("[Discovery G2] Fetching #{channels_url}")

    case run_ytdlp_flat(channels_url) do
      {:ok, entries} ->
        Enum.map(entries, fn entry ->
          %{
            channel_id: entry["id"],
            name: entry["title"],
            source_id: source.id
          }
        end)
        |> Enum.filter(fn e -> e.channel_id != nil end)

      {:error, reason} ->
        Logger.warning("[Discovery G2] Failed to crawl #{channels_url}: #{inspect(reason)}")
        []
    end
  end

  defp channels_tab_url(original_url) do
    # Strip trailing slash and any existing tab path, then append /channels
    base =
      original_url
      |> String.trim_trailing("/")
      |> String.replace(~r{/(videos|shorts|streams|playlists|community|channels|about)$}, "")

    "#{base}/channels"
  end

  defp run_ytdlp_flat(url) do
    runner = Application.get_env(:pinchflat, :yt_dlp_runner)

    command_opts = [
      :simulate,
      :skip_download,
      :flat_playlist,
      :ignore_no_formats_error,
      :no_warnings
    ]

    output_template = "%(.{id,title,channel_id,url})j"

    case runner.run(url, :discovery_featured_channels, command_opts, output_template, skip_sleep_interval: true) do
      {:ok, output} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case Phoenix.json_library().decode(line) do
              {:ok, parsed} -> parsed
              _ -> nil
            end
          end)
          |> Enum.filter(& &1)

        {:ok, entries}

      {:error, output, _status} ->
        {:error, output}
    end
  end

  defp aggregate(results) do
    results
    |> Enum.group_by(fn r -> r.channel_id end)
    |> Enum.map(fn {channel_id, entries} ->
      source_ids = entries |> Enum.map(& &1.source_id) |> MapSet.new()
      name = entries |> Enum.map(& &1.name) |> Enum.find(& &1)

      %{
        identifier: channel_id,
        identifier_type: :channel_id,
        name: name,
        featured_by_source_ids: source_ids,
        featured_by_count: MapSet.size(source_ids),
        score: MapSet.size(source_ids) * 10.0
      }
    end)
  end
end
