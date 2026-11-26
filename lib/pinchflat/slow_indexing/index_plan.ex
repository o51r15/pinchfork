defmodule Pinchflat.SlowIndexing.IndexPlan do
  @moduledoc """
  Works out what a slow (yt-dlp) index of a source should read and where it can stop.

  A YouTube channel is read tab by tab (Videos, Shorts, Live) so the tabs the media
  profile leaves out are never read at all, and each tab can stop on its own:

    - Tabs list newest first, so with a cutoff date a tab stops at the first video
      older than the cutoff (`--break-match-filters`) and the next tab starts
      (`--break-per-input`).
    - Until a channel's first index has finished, a rerun skips the videos it already
      has without opening them (download archive, no break), so a restart picks up
      where it left off instead of starting over.
    - After that, a scheduled index stops when it reaches videos it already knows
      (`--break-on-existing`), as before.

  Playlists, URLs that already point at one tab and non-YouTube URLs are read as given.
  Playlists aren't in date order, so they can't stop at the cutoff.
  """

  alias Pinchflat.Sources.Source

  # Path segments that are a channel tab yt-dlp lists in date order
  @date_ordered_tabs ~w(videos shorts streams)
  # Other channel pages: strip them and read the tabs instead
  @other_pages ~w(featured about playlists community posts releases podcasts courses store search live)

  @doc """
  The URLs to read for a source: the channel's tabs the profile wants, or the source's
  own URL. Expects the media profile to be preloaded.

  Returns [binary()]
  """
  def urls(%Source{collection_type: :channel, original_url: url} = source) do
    case channel_base(url) do
      {:tab, _tab} -> [url]
      {:base, base} -> Enum.map(tabs_for(source.media_profile), &"#{base}/#{&1}")
      :other -> [url]
    end
  end

  def urls(%Source{original_url: url}), do: [url]

  @doc """
  The tabs a channel index reads, from the profile's shorts and livestream settings.

  Returns [binary()]
  """
  def tabs_for(profile) do
    shorts = behaviour(profile, :shorts_behaviour)
    live = behaviour(profile, :livestream_behaviour)

    cond do
      shorts == :only and live == :only -> ["shorts", "streams"]
      shorts == :only -> ["shorts"]
      live == :only -> ["streams"]
      true -> ["videos"] ++ if_tab(shorts, "shorts") ++ if_tab(live, "streams")
    end
  end

  @doc """
  True when the index reads lists in date order, so it can stop at the cutoff date.
  """
  def date_ordered?(%Source{collection_type: :channel, original_url: url}) do
    channel_base(url) != :other
  end

  def date_ordered?(_source), do: false

  @doc """
  yt-dlp options for reading a source's lists.

  For date-ordered channel tabs:
    - `--lazy-playlist`: handle videos as each page of the tab arrives. Without it yt-dlp
      first pages through the whole tab (tens of thousands of videos on a big channel)
      before looking at a single video, so no stop can kick in early.
    - With a cutoff date, `--break-match-filters` stops the tab at the first older video.
      `>=?` lets videos with no date (upcoming premieres) through.

  None for playlists, which aren't in date order.

  Returns list()
  """
  def read_options(%Source{} = source) do
    if date_ordered?(source) do
      [:lazy_playlist] ++ cutoff_options(source)
    else
      []
    end
  end

  defp cutoff_options(%Source{download_cutoff_date: %Date{} = cutoff}) do
    [break_match_filters: "upload_date>=?#{Calendar.strftime(cutoff, "%Y%m%d")}"]
  end

  defp cutoff_options(_source), do: []

  # {:tab, tab} when the URL already points at a date-ordered tab,
  # {:base, channel_url} when it points at the channel (or one of its other pages),
  # :other when it isn't a YouTube channel URL we understand.
  defp channel_base(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    with true <- youtube_host?(uri.host),
         segments when segments != [] <- String.split(uri.path || "", "/", trim: true),
         {:ok, base_segments, rest} <- split_channel_path(segments) do
      base = "https://www.youtube.com/" <> Enum.join(base_segments, "/")

      case rest do
        [] -> {:base, base}
        [tab | _] when tab in @date_ordered_tabs -> {:tab, tab}
        [page | _] when page in @other_pages -> {:base, base}
        _ -> :other
      end
    else
      _ -> :other
    end
  end

  defp channel_base(_url), do: :other

  defp youtube_host?(host) when is_binary(host) do
    host in ["youtube.com", "www.youtube.com", "m.youtube.com"]
  end

  defp youtube_host?(_host), do: false

  defp split_channel_path(["@" <> _ = handle | rest]), do: {:ok, [handle], rest}
  defp split_channel_path([kind, id | rest]) when kind in ["channel", "c", "user"], do: {:ok, [kind, id], rest}
  defp split_channel_path(_segments), do: :error

  defp behaviour(%{} = profile, field), do: Map.get(profile, field) || :include
  defp behaviour(_profile, _field), do: :include

  defp if_tab(:exclude, _tab), do: []
  defp if_tab(_behaviour, tab), do: [tab]
end
