defmodule Pinchflat.Discovery.Validator do
  @moduledoc """
  Resolves discovery candidates to canonical UC… channel IDs, enriches them
  with subscriber/video counts and last-upload date, and filters out channels
  that are already sources or previously dismissed.

  Uses yt-dlp with --playlist-end 1 to resolve handles cheaply (~2s per candidate).
  Rate-limited with a configurable sleep between calls.
  """

  require Logger

  alias Pinchflat.Discovery

  @sleep_between_ms 2_000

  @doc """
  Takes a list of raw candidates (from G1/G2/etc), resolves and enriches them,
  filters out excluded channels, and returns validated candidates.

  Each input candidate must have at minimum:
    - :identifier (string — "@handle", "UCxxxxxx", or legacy username)
    - :identifier_type (:handle | :channel_id | :legacy)

  All other fields are passed through and merged with enrichment data.

  Returns [validated_candidate_map, ...]
  """
  def validate_and_enrich(candidates) do
    excluded = Discovery.excluded_channel_ids()

    candidates
    |> deduplicate_inputs()
    |> Enum.reject(fn c ->
      # Skip channel IDs we already know are excluded (saves a yt-dlp call)
      c.identifier_type == :channel_id and MapSet.member?(excluded, c.identifier)
    end)
    |> Enum.reduce({[], 0}, fn candidate, {acc, call_count} ->
      # Rate-limit yt-dlp calls
      if call_count > 0, do: Process.sleep(@sleep_between_ms)

      case resolve_and_enrich(candidate) do
        {:ok, enriched} ->
          if MapSet.member?(excluded, enriched.channel_id) do
            Logger.debug("[Discovery Validator] Skipping #{enriched.channel_id} (already a source or dismissed)")
            {acc, call_count + 1}
          else
            {[enriched | acc], call_count + 1}
          end

        {:error, reason} ->
          Logger.warning("[Discovery Validator] Failed to resolve #{candidate.identifier}: #{inspect(reason)}")
          {acc, call_count + 1}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp deduplicate_inputs(candidates) do
    candidates
    |> Enum.uniq_by(fn c -> String.downcase(c.identifier) end)
  end

  defp resolve_and_enrich(candidate) do
    case candidate.identifier_type do
      :channel_id ->
        # Already have a UC… ID — resolve via channel URL
        enrich_by_url("https://www.youtube.com/channel/#{candidate.identifier}", candidate)

      :handle ->
        # @handle — resolve via handle URL
        handle = String.trim_leading(candidate.identifier, "@")
        enrich_by_url("https://www.youtube.com/@#{handle}", candidate)

      :legacy ->
        # /user/ or /c/ path
        enrich_by_url("https://www.youtube.com/c/#{candidate.identifier}", candidate)
    end
  end

  defp enrich_by_url(url, candidate) do
    runner = Application.get_env(:pinchflat, :yt_dlp_runner)

    command_opts = [
      :simulate,
      :skip_download,
      :ignore_no_formats_error,
      :no_warnings,
      playlist_end: 1
    ]

    # Printed at playlist level, so the channel's pictures (thumbnails) are there. A channel
    # with tabs prints a line for its Videos tab (newest video = entries.0) and one for the
    # channel (newest video = entries.0.entries.0); parse_enrichment/2 merges the lines.
    # No video count: at this level playlist_count counts tabs, not videos.
    output_template =
      "playlist:%(.{channel_id,channel,channel_follower_count,channel_url,entries.0.upload_date,entries.0.entries.0.upload_date,thumbnails})j"

    case runner.run(url, :discovery_enrich, command_opts, output_template, skip_sleep_interval: true) do
      {:ok, output} ->
        parse_enrichment(output, candidate)

      {:error, output, _status} ->
        {:error, output}
    end
  end

  defp parse_enrichment(output, candidate) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Phoenix.json_library().decode(line) do
          {:ok, %{} = data} -> [data]
          _ -> []
        end
      end)

    case Enum.find(lines, & &1["channel_id"]) do
      nil when lines == [] ->
        {:error, "Failed to parse JSON: #{String.slice(output, 0, 200)}"}

      nil ->
        {:error, "No channel_id in response"}

      _first ->
        # Later lines (the channel) fill in what earlier ones (a tab) lack
        data = Enum.reduce(lines, %{}, fn l, acc -> Map.merge(acc, Map.reject(l, fn {_k, v} -> is_nil(v) end)) end)

        upload_date =
          Enum.find_value(lines, fn l ->
            l["entries.0.upload_date"] || l["entries.0.entries.0.upload_date"] || l["upload_date"]
          end)

        {:ok,
         Map.merge(candidate, %{
           channel_id: data["channel_id"],
           name: data["channel"],
           url: data["channel_url"] || "https://www.youtube.com/channel/#{data["channel_id"]}",
           subscriber_count: data["channel_follower_count"],
           video_count: nil,
           last_upload_at: parse_upload_date(upload_date),
           thumbnail_url: Enum.find_value(lines, &avatar_url(&1["thumbnails"]))
         })}
    end
  end

  # The channel picture: the square avatar (not the uncropped one or a banner), asked for at a
  # small size. yt3.googleusercontent.com URLs carry the size as =s<pixels>.
  @doc false
  def avatar_url(thumbnails) when is_list(thumbnails) do
    thumbnails
    |> Enum.filter(fn t -> is_binary(t["url"]) and t["width"] != nil and t["width"] == t["height"] end)
    |> Enum.max_by(& &1["width"], fn -> nil end)
    |> case do
      nil -> nil
      %{"url" => url} -> String.replace(url, ~r/=s\d+(?=-|$)/, "=s176")
    end
  end

  def avatar_url(_), do: nil

  defp parse_upload_date(nil), do: nil

  defp parse_upload_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(
           String.slice(date_str, 0, 4) <>
             "-" <>
             String.slice(date_str, 4, 2) <>
             "-" <>
             String.slice(date_str, 6, 2)
         ) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_upload_date(_), do: nil
end
