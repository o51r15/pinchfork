defmodule Pinchflat.Discovery.ScanWorker do
  @moduledoc """
  Oban worker that orchestrates the discovery pipeline:
  G1 (mention mining) → G2 (featured channels) → validate → score → persist.

  Triggered manually from the Discovery page — no schedule (by design).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 300]

  require Logger
  import Ecto.Query

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.MentionMiner
  alias Pinchflat.Discovery.FeaturedChannels
  alias Pinchflat.Discovery.Validator
  alias Pinchflat.Discovery.Scorer

  @max_candidates_to_validate 50

  @impl Oban.Worker
  def perform(_job) do
    settings = Discovery.discovery_settings()

    unless settings.enabled do
      Logger.info("[Discovery] Scan skipped — discovery is disabled")
      {:ok, :disabled}
    else
      run_scan(settings)
    end
  end

  defp run_scan(settings) do
    Logger.info("[Discovery] Scan starting")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Phase 1: Generate candidates from enabled generators
    candidates = generate_candidates(settings)
    Logger.info("[Discovery] Generated #{length(candidates)} raw candidates")

    if candidates == [] do
      Logger.info("[Discovery] No candidates found, scan complete")
      {:ok, :no_candidates}
    else
      # Phase 2: Take top candidates by raw score, validate and enrich
      top_candidates =
        candidates
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(@max_candidates_to_validate)

      # Exclude channels already dismissed or accepted from validation
      excluded_suggestions =
        Pinchflat.Repo.all(
          from(d in Pinchflat.Discovery.DiscoverySuggestion,
            where: d.status in ["dismissed", "accepted"],
            select: d.channel_id
          )
        )
        |> MapSet.new()

      top_candidates =
        top_candidates
        |> Enum.reject(fn c -> MapSet.member?(excluded_suggestions, c[:channel_id]) end)

      Logger.info(
        "[Discovery] Validating top #{length(top_candidates)} candidates (excluded #{MapSet.size(excluded_suggestions)} dismissed/accepted)"
      )

      validated = Validator.validate_and_enrich(top_candidates)
      Logger.info("[Discovery] #{length(validated)} candidates passed validation")

      # Phase 3: Score with tier balancing
      scored = Scorer.score(validated, max_results: length(validated))
      Logger.info("[Discovery] Scored and balanced to #{length(scored)} suggestions")

      # Phase 4: Persist to discovery_suggestions
      persisted = persist_suggestions(scored, now)
      Logger.info("[Discovery] Scan complete — #{persisted} suggestions saved")

      Phoenix.PubSub.broadcast(
        Pinchflat.PubSub,
        "discovery:scan",
        {:scan_complete, %{persisted: persisted, validated: length(validated)}}
      )

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
