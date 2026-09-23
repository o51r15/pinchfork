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

    output_template = "%(.{channel_id,channel,channel_follower_count,channel_url,playlist_count,upload_date})j"

    case runner.run(url, :discovery_enrich, command_opts, output_template, skip_sleep_interval: true) do
      {:ok, output} ->
        parse_enrichment(output, candidate)

      {:error, output, _status} ->
        {:error, output}
    end
  end

  defp parse_enrichment(output, candidate) do
    # Take the last non-empty line (yt-dlp may output multiple lines)
    line =
      output
      |> String.split("\n", trim: true)
      |> List.last("")

    case Phoenix.json_library().decode(line) do
      {:ok, data} ->
        enriched =
          Map.merge(candidate, %{
            channel_id: data["channel_id"],
            name: data["channel"],
            url: data["channel_url"] || "https://www.youtube.com/channel/#{data["channel_id"]}",
            subscriber_count: data["channel_follower_count"],
            video_count: data["playlist_count"],
            last_upload_at: parse_upload_date(data["upload_date"]),
            thumbnail_url: nil
          })

        if enriched.channel_id do
          {:ok, enriched}
        else
          {:error, "No channel_id in response"}
        end

      {:error, _} ->
        {:error, "Failed to parse JSON: #{String.slice(line, 0, 200)}"}
    end
  end

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
