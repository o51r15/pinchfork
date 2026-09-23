defmodule Pinchflat.Discovery.Scorer do
  @moduledoc """
  Scores and ranks discovery candidates using heuristic signals.
  P1 uses mention count, source agreement, activity, and sub-tier balancing.
  P2 will add LLM re-ranking via a pluggable rerank step.
  """

  @doc """
  Scores a list of validated/enriched candidates and returns the top N,
  balanced across subscriber-count tiers.

  Options:
    - :max_results — maximum suggestions to return (default 10)
    - :reranker — optional function for P2 LLM re-ranking (default nil/no-op)
  """
  def score(candidates, opts \\ []) do
    max_results = Keyword.get(opts, :max_results, 10)

    candidates
    |> Enum.map(&compute_score/1)
    |> rerank(Keyword.get(opts, :reranker))
    |> balance_tiers(max_results)
  end

  defp compute_score(candidate) do
    mention_score = mention_signal(candidate)
    agreement_score = generator_agreement_signal(candidate)
    activity_score = activity_signal(candidate)

    total = mention_score + agreement_score + activity_score

    Map.merge(candidate, %{
      score: total,
      reason: build_reason(candidate)
    })
  end

  # Mention count weighted by distinct sources — the core G1 signal.
  # Multi-source mentions are worth much more than single-source spam.
  defp mention_signal(candidate) do
    mention_count = Map.get(candidate, :mention_count, 0)
    source_count = source_count(candidate)

    cond do
      mention_count == 0 -> 0.0
      source_count >= 3 -> mention_count * 3.0
      source_count == 2 -> mention_count * 2.0
      true -> mention_count * 0.5
    end
  end

  # Candidates found by multiple generators get a big boost.
  defp generator_agreement_signal(candidate) do
    generators = Map.get(candidate, :generators, [])
    featured_count = Map.get(candidate, :featured_by_count, 0)

    gen_count = length(generators) + if featured_count > 0, do: 1, else: 0

    case gen_count do
      n when n >= 3 -> 100.0
      2 -> 50.0
      _ -> 0.0
    end
  end

  # Recent uploads = active channel = better suggestion.
  defp activity_signal(candidate) do
    case candidate[:last_upload_at] do
      nil ->
        0.0

      %DateTime{} = dt ->
        days_ago = DateTime.diff(DateTime.utc_now(), dt, :day)

        cond do
          days_ago <= 30 -> 20.0
          days_ago <= 90 -> 10.0
          days_ago <= 365 -> 5.0
          true -> -10.0
        end

      _ ->
        0.0
    end
  end

  # P2 hook — no-op in P1
  defp rerank(candidates, nil), do: candidates
  defp rerank(candidates, reranker) when is_function(reranker, 1), do: reranker.(candidates)

  @doc """
  Balances results across subscriber-count tiers so no single tier dominates.
  Tiers: micro (<10K), small (10K-100K), medium (100K-1M), large (>1M).
  Takes top candidates from each tier in round-robin order.
  """
  def balance_tiers(candidates, max_results) do
    # Sort within each tier by score
    grouped =
      candidates
      |> Enum.group_by(&sub_tier/1)
      |> Enum.map(fn {tier, items} ->
        {tier, Enum.sort_by(items, & &1.score, :desc)}
      end)
      |> Map.new()

    tiers = [:micro, :small, :medium, :large]
    round_robin(tiers, grouped, max_results, [])
  end

  defp sub_tier(candidate) do
    case candidate[:subscriber_count] do
      nil -> :micro
      n when n < 10_000 -> :micro
      n when n < 100_000 -> :small
      n when n < 1_000_000 -> :medium
      _ -> :large
    end
  end

  defp round_robin(_tiers, _grouped, 0, acc), do: Enum.reverse(acc)

  defp round_robin(tiers, grouped, remaining, acc) do
    {new_grouped, new_acc, taken} =
      Enum.reduce(tiers, {grouped, acc, 0}, fn tier, {g, a, t} ->
        case Map.get(g, tier, []) do
          [head | rest] when remaining - t > 0 ->
            {Map.put(g, tier, rest), [head | a], t + 1}

          _ ->
            {g, a, t}
        end
      end)

    if taken == 0 do
      # All tiers exhausted
      Enum.reverse(new_acc)
    else
      round_robin(tiers, new_grouped, remaining - taken, new_acc)
    end
  end

  defp build_reason(candidate) do
    parts = []

    mention_count = Map.get(candidate, :mention_count, 0)
    source_count = source_count(candidate)

    parts =
      if mention_count > 0 do
        src_text = if source_count > 1, do: "#{source_count} of your sources", else: "one of your sources"
        ["Mentioned #{mention_count} times by #{src_text}" | parts]
      else
        parts
      end

    featured_count = Map.get(candidate, :featured_by_count, 0)

    parts =
      if featured_count > 0 do
        ["Featured by #{featured_count} of your channels" | parts]
      else
        parts
      end

    case parts do
      [] -> "Discovered by scan"
      _ -> Enum.join(Enum.reverse(parts), ". ")
    end
  end

  defp source_count(candidate) do
    case Map.get(candidate, :mentioning_source_ids) do
      %MapSet{} = ms -> MapSet.size(ms)
      _ -> Map.get(candidate, :featured_by_count, 1)
    end
  end
end
