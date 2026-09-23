defmodule Pinchflat.Discovery.ScanWorker do
  @moduledoc """
  Oban worker that orchestrates the discovery pipeline:
  G1 (mention mining) → G2 (featured channels) → validate → score → persist.

  Runs daily via Oban cron (03:00 UTC) and on demand from the Discovery page.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    # Only an in-flight scan blocks a new one. With the default unique states a scan that had
    # just COMPLETED also counted, so "Scan Now" returned a silent conflict and spun forever.
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  require Logger

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.MentionMiner
  alias Pinchflat.Discovery.FeaturedChannels
  alias Pinchflat.Discovery.Validator
  alias Pinchflat.Discovery.Scorer

  @max_candidates_to_validate 50

  @impl Oban.Worker
  def perform(_job) do
    settings = Discovery.discovery_settings()

    result =
      if settings.enabled do
        run_scan(settings)
      else
        Logger.info("[Discovery] Scan skipped — discovery is disabled")
        {:ok, :disabled}
      end

    # Always tell the Discovery page the scan is over (including disabled / no-candidate
    # outcomes), otherwise its "Scanning..." spinner never clears.
    broadcast_complete(result)
    result
  rescue
    e ->
      broadcast_complete({:error, Exception.message(e)})
      reraise e, __STACKTRACE__
  end

  defp broadcast_complete(result) do
    payload =
      case result do
        {:ok, %{persisted: persisted, validated: validated}} -> %{persisted: persisted, validated: validated}
        {:ok, _other} -> %{persisted: 0, validated: 0}
        {:error, message} -> %{persisted: 0, validated: 0, error: message}
      end

    Phoenix.PubSub.broadcast(Pinchflat.PubSub, "discovery:scan", {:scan_complete, payload})
  end

  defp run_scan(settings) do
    Logger.info("[Discovery] Scan starting")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {accepted, reopened} = Discovery.reconcile_with_sources()
    Logger.info("[Discovery] Reconciled with sources: #{accepted} marked accepted, #{reopened} reopened")

    # Phase 1: Generate candidates from enabled generators
    candidates = generate_candidates(settings)
    Logger.info("[Discovery] Generated #{length(candidates)} raw candidates")

    if candidates == [] do
      Logger.info("[Discovery] No candidates found, scan complete")
      {:ok, :no_candidates}
    else
      # Phase 2: Drop anything we already know to skip (own sources by UC id or @handle,
      # dismissed/accepted suggestions) BEFORE the top-N cut, so it doesn't burn validation slots.
      excluded = Discovery.excluded_identifiers()

      {skipped, eligible} =
        Enum.split_with(candidates, fn c -> MapSet.member?(excluded, String.downcase(c.identifier)) end)

      top_candidates =
        eligible
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(@max_candidates_to_validate)

      Logger.info(
        "[Discovery] Validating top #{length(top_candidates)} candidates (skipped #{length(skipped)} already-known)"
      )

      validated =
        top_candidates
        |> Validator.validate_and_enrich()
        |> merge_by_channel_id()

      Logger.info("[Discovery] #{length(validated)} candidates passed validation")

      # Phase 3: Score with tier balancing
      scored = Scorer.score(validated, max_results: length(validated))
      Logger.info("[Discovery] Scored and balanced to #{length(scored)} suggestions")

      # Phase 4: Persist to discovery_suggestions
      persisted = persist_suggestions(scored, now)
      Logger.info("[Discovery] Scan complete — #{persisted} suggestions saved")

      {:ok, %{candidates: length(candidates), validated: length(validated), persisted: persisted}}
    end
  end

  defp generate_candidates(settings) do
    g1 = if settings.generators.g1, do: run_g1(), else: []
    g2 = if settings.generators.g2, do: run_g2(), else: []

    # Merge G1 and G2 by channel identifier, tracking which generators found each
    merge_candidates(g1, g2)
  end

  defp run_g1 do
    Logger.info("[Discovery] Running G1 (mention mining)")
    results = MentionMiner.mine()
    Enum.map(results, fn c -> Map.put(c, :generators, ["G1"]) end)
  rescue
    e ->
      Logger.error("[Discovery] G1 failed: #{Exception.message(e)}")
      []
  end

  defp run_g2 do
    Logger.info("[Discovery] Running G2 (featured channels)")
    results = FeaturedChannels.crawl()
    Enum.map(results, fn c -> Map.put(c, :generators, ["G2"]) end)
  rescue
    e ->
      Logger.error("[Discovery] G2 failed: #{Exception.message(e)}")
      []
  end

  defp merge_candidates(g1, g2) do
    # Index G2 results by identifier for fast lookup
    g2_by_id = Map.new(g2, fn c -> {String.downcase(c.identifier), c} end)

    # Walk G1, merging any G2 match
    {merged, matched_g2_ids} =
      Enum.reduce(g1, {[], MapSet.new()}, fn g1_candidate, {acc, matched} ->
        key = String.downcase(g1_candidate.identifier)

        case Map.get(g2_by_id, key) do
          nil ->
            {[g1_candidate | acc], matched}

          g2_match ->
            combined =
              Map.merge(g1_candidate, %{
                generators: ["G1", "G2"],
                featured_by_count: g2_match.featured_by_count,
                featured_by_source_ids: g2_match.featured_by_source_ids,
                score: g1_candidate.score + g2_match.score
              })

            {[combined | acc], MapSet.put(matched, key)}
        end
      end)

    # Add G2-only candidates (not matched to G1)
    g2_only =
      g2
      |> Enum.reject(fn c -> MapSet.member?(matched_g2_ids, String.downcase(c.identifier)) end)

    Enum.reverse(merged) ++ g2_only
  end

  # G1 yields @handles and G2 yields UC… ids, so the same channel can arrive as two
  # candidates. Once the validator has resolved everything to a channel_id, fold duplicates
  # together so provenance (generators, mentions, featured-by) is combined, not overwritten.
  defp merge_by_channel_id(validated) do
    validated
    |> Enum.group_by(& &1.channel_id)
    |> Enum.map(fn {_channel_id, [first | rest]} -> Enum.reduce(rest, first, &combine_candidates/2) end)
  end

  defp combine_candidates(other, acc) do
    featured_ids = union_sets(acc[:featured_by_source_ids], other[:featured_by_source_ids])

    Map.merge(acc, %{
      generators: Enum.uniq(Map.get(acc, :generators, []) ++ Map.get(other, :generators, [])),
      mention_count: Map.get(acc, :mention_count, 0) + Map.get(other, :mention_count, 0),
      mentioning_source_ids: union_sets(acc[:mentioning_source_ids], other[:mentioning_source_ids]),
      featured_by_source_ids: featured_ids,
      featured_by_count: MapSet.size(featured_ids),
      score: Map.get(acc, :score, 0) + Map.get(other, :score, 0),
      name: acc[:name] || other[:name]
    })
  end

  defp union_sets(a, b), do: MapSet.union(a || MapSet.new(), b || MapSet.new())

  defp persist_suggestions(scored, now) do
    Enum.reduce(scored, 0, fn candidate, count ->
      attrs = %{
        channel_id: candidate.channel_id,
        url: candidate[:url] || "https://www.youtube.com/channel/#{candidate.channel_id}",
        name: candidate[:name],
        description: nil,
        thumbnail_url: candidate[:thumbnail_url],
        subscriber_count: candidate[:subscriber_count],
        video_count: candidate[:video_count],
        last_upload_at: candidate[:last_upload_at],
        cluster: candidate[:cluster],
        reason: candidate[:reason],
        provenance: build_provenance(candidate),
        score: candidate.score,
        scanned_at: now
      }

      case Discovery.upsert_suggestion(attrs) do
        {:ok, _} ->
          count + 1

        {:error, changeset} ->
          Logger.warning("[Discovery] Failed to persist #{candidate.channel_id}: #{inspect(changeset.errors)}")
          count
      end
    end)
  end

  defp build_provenance(candidate) do
    %{
      "generators" => Map.get(candidate, :generators, []),
      "mention_count" => Map.get(candidate, :mention_count, 0),
      "mentioning_source_count" => source_count(candidate),
      "featured_by_count" => Map.get(candidate, :featured_by_count, 0)
    }
  end

  defp source_count(candidate) do
    case Map.get(candidate, :mentioning_source_ids) do
      %MapSet{} = ms -> MapSet.size(ms)
      _ -> 0
    end
  end
end
