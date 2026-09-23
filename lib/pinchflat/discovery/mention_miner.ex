defmodule Pinchflat.Discovery.MentionMiner do
  @moduledoc """
  Generator G1 — mines video descriptions in the local DB for @handles and
  youtube.com channel URLs. Pure SQL + Elixir regex, zero network calls.

  Returns a list of candidate maps: %{handle_or_url: ..., mention_count: N,
  mentioning_sources: [source_id, ...]}
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo

  # Patterns that identify YouTube channel references in descriptions
  # The negative lookbehind skips email addresses ("name@agency.co") — a real @mention is
  # preceded by whitespace/punctuation/start-of-text, never by a word character or a dot.
  @handle_regex ~r/(?<![\w.])@([\w.-]{2,})/u
  @channel_url_regex ~r{youtube\.com/(?:channel/|c/|user/|@)([\w.-]+)}iu

  @doc """
  Scans all media item descriptions for channel mentions.
  Returns a list of candidate maps sorted by score (mention_count * distinct_sources).

  Each candidate:
    %{
      identifier: "@handle" | "UCxxxxxx" | "username",
      identifier_type: :handle | :channel_id | :legacy,
      mention_count: integer,
      mentioning_source_ids: MapSet.t(),
      score: float
    }
  """
  def mine do
    fetch_mentions()
    |> aggregate_mentions()
    |> sort_and_return()
  end

  # Streams descriptions in batches inside a transaction and keeps only the extracted
  # mentions, rather than loading every description in the library into memory at once.
  defp fetch_mentions do
    query =
      from(m in "media_items",
        where: not is_nil(m.description) and m.description != "",
        select: %{description: m.description, source_id: m.source_id}
      )

    {:ok, mentions} =
      Repo.transaction(
        fn ->
          query
          |> Repo.stream(max_rows: 500)
          |> Stream.flat_map(fn %{description: desc, source_id: source_id} ->
            desc
            |> extract_mentions()
            |> Enum.map(fn {identifier, type} -> {identifier, type, source_id} end)
          end)
          |> Enum.to_list()
        end,
        timeout: :infinity
      )

    mentions
  end

  @doc """
  Extracts channel identifiers from a single description string.
  Returns a list of {identifier, type} tuples.
  """
  def extract_mentions(description) when is_binary(description) do
    handles = extract_handles(description)
    urls = extract_url_refs(description)
    Enum.uniq(handles ++ urls)
  end

  def extract_mentions(_), do: []

  defp extract_handles(text) do
    Regex.scan(@handle_regex, text)
    |> Enum.map(fn [_full, handle] -> {"@#{trim_trailing_punctuation(handle)}", :handle} end)
    |> Enum.reject(fn {handle, _} -> String.length(handle) < 3 end)
    |> Enum.reject(fn {handle, _} -> noise_handle?(handle) end)
  end

  defp extract_url_refs(text) do
    Regex.scan(@channel_url_regex, text)
    |> Enum.map(fn [full, ref] -> [full, trim_trailing_punctuation(ref)] end)
    |> Enum.reject(fn [_full, ref] -> noise_handle?("@#{ref}") end)
    |> Enum.map(fn [_full, ref] ->
      cond do
        String.starts_with?(ref, "UC") and byte_size(ref) == 24 ->
          {ref, :channel_id}

        String.starts_with?(ref, "@") ->
          {ref, :handle}

        true ->
          # Legacy /c/ or /user/ paths — normalize to @handle format
          {"@#{ref}", :handle}
      end
    end)
  end

  # "Follow @someone." / "…/@someone-" — sentence punctuation isn't part of the handle.
  defp trim_trailing_punctuation(ref), do: ref |> String.trim_trailing(".") |> String.trim_trailing("-")

  # Filter out common noise — email-like @mentions, social media handles that
  # aren't YouTube channels, and known non-channel patterns.
  defp noise_handle?(handle) do
    downcased = String.downcase(handle)

    String.contains?(downcased, ".com") or
      String.contains?(downcased, ".org") or
      String.contains?(downcased, ".net") or
      downcased in ~w(@gmail @yahoo @outlook @hotmail @proton @icloud
                      @twitter @instagram @tiktok @facebook @discord
                      @twitch @patreon @paypal @venmo @cashapp)
  end

  defp aggregate_mentions(mentions) do
    mentions
    |> Enum.group_by(fn {identifier, _type, _source_id} -> identifier end)
    |> Enum.map(fn {identifier, entries} ->
      {_id, type, _sid} = hd(entries)
      source_ids = entries |> Enum.map(fn {_, _, sid} -> sid end) |> MapSet.new()

      %{
        identifier: identifier,
        identifier_type: type,
        mention_count: length(entries),
        mentioning_source_ids: source_ids,
        score: length(entries) * MapSet.size(source_ids)
      }
    end)
  end

  defp sort_and_return(candidates) do
    Enum.sort_by(candidates, & &1.score, :desc)
  end
end
