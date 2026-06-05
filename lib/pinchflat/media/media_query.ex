defmodule Pinchflat.Media.MediaQuery do
  @moduledoc """
  Query helpers for the Media context.

  These methods are made to be one-ish liners used
  to compose queries. Each method should strive to do
  _one_ thing. These don't need to be tested as
  they are just building blocks for other functionality
  which, itself, will be tested.
  """
  import Ecto.Query, warn: false

  alias Pinchflat.Media.MediaItem

  # This allows the module to be aliased and query methods to be used
  # all in one go
  # usage: use Pinchflat.Media.MediaQuery
  defmacro __using__(_opts) do
    quote do
      import Ecto.Query, warn: false

      alias unquote(__MODULE__)
    end
  end

  def new do
    MediaItem
  end

  def for_source(source_id) when is_integer(source_id), do: dynamic([mi], mi.source_id == ^source_id)
  def for_source(source), do: dynamic([mi], mi.source_id == ^source.id)

  def downloaded, do: dynamic([mi], not is_nil(mi.media_filepath))
  def download_prevented, do: dynamic([mi], mi.prevent_download == true)
  def culling_prevented, do: dynamic([mi], mi.prevent_culling == true)
  def redownloaded, do: dynamic([mi], not is_nil(mi.media_redownloaded_at))
  def upload_date_matches(%DateTime{} = dt), do: upload_date_matches(DateTime.to_date(dt))
  def upload_date_matches(%NaiveDateTime{} = ndt), do: upload_date_matches(NaiveDateTime.to_date(ndt))
  def upload_date_matches(other_date), do: dynamic([mi], fragment("?::date = ?", mi.uploaded_at, ^other_date))

  def upload_date_after_source_cutoff do
    dynamic(
      [mi, source],
      is_nil(source.download_cutoff_date) or
        fragment("?::date >= ?", mi.uploaded_at, source.download_cutoff_date)
    )
  end

  def format_matching_profile_preference do
    dynamic(
      [mi, source, media_profile],
      fragment("""
        CASE
          WHEN shorts_behaviour = 'only' AND livestream_behaviour = 'only' THEN
            livestream = true OR short_form_content = true
          WHEN shorts_behaviour = 'only' THEN
            short_form_content = true
          WHEN livestream_behaviour = 'only' THEN
            livestream = true
          WHEN shorts_behaviour = 'exclude' AND livestream_behaviour = 'exclude' THEN
            short_form_content = false AND livestream = false
          WHEN shorts_behaviour = 'exclude' THEN
            short_form_content = false
          WHEN livestream_behaviour = 'exclude' THEN
            livestream = false
          ELSE
            true
        END
      """)
    )
  end

  def matches_source_title_regex do
    dynamic(
      [mi, source],
      is_nil(source.title_filter_regex) or fragment("? ~ ?", mi.title, source.title_filter_regex)
    )
  end

  def meets_min_and_max_duration do
    dynamic(
      [mi, source],
      (is_nil(source.min_duration_seconds) or fragment("duration_seconds >= ?", source.min_duration_seconds)) and
        (is_nil(source.max_duration_seconds) or fragment("duration_seconds <= ?", source.max_duration_seconds))
    )
  end

  def past_retention_period do
    dynamic(
      [mi, source],
      fragment("""
        COALESCE(retention_period_days, 0) > 0 AND
        media_downloaded_at + (retention_period_days * INTERVAL '1 day') < NOW()
      """)
    )
  end

  def past_redownload_delay do
    dynamic(
      [mi, source, media_profile],
      # Returns media items where the uploaded_at is at least redownload_delay_days ago AND
      # downloaded_at minus the redownload_delay_days is before the upload date
      fragment("""
        COALESCE(redownload_delay_days, 0) > 0 AND
        (NOW() - (redownload_delay_days * INTERVAL '1 day'))::date > uploaded_at::date AND
        (media_downloaded_at - (redownload_delay_days * INTERVAL '1 day'))::date < uploaded_at::date
      """)
    )
  end

  def cullable do
    dynamic(
      [mi, source],
      ^downloaded() and
        ^past_retention_period() and
        not (^culling_prevented())
    )
  end

  def deletable_based_on_source_cutoff do
    dynamic(
      [mi, source],
      ^downloaded() and
        not (^upload_date_after_source_cutoff()) and
        not (^culling_prevented())
    )
  end

  def pending do
    dynamic(
      [mi],
      not (^downloaded()) and
        not (^download_prevented()) and
        ^upload_date_after_source_cutoff() and
        ^format_matching_profile_preference() and
        ^matches_source_title_regex() and
        ^meets_min_and_max_duration()
    )
  end

  def upgradeable do
    dynamic(
      [mi, source],
      ^downloaded() and
        not (^download_prevented()) and
        not (^redownloaded()) and
        ^past_redownload_delay()
    )
  end

  # Dynamic filter: returns a boolean expression usable inside a where clause.
  # Used when search is one of several filters being composed together.
  def matches_search_term(nil), do: dynamic([mi], true)

  def matches_search_term(term) do
    case String.trim(term) do
      "" ->
        dynamic([mi], true)

      trimmed ->
        tsquery = build_tsquery(trimmed)
        dynamic([mi], fragment("search_vector @@ to_tsquery('english', ?)", ^tsquery))
    end
  end

  def require_assoc(query, identifier) do
    if has_named_binding?(query, identifier) do
      query
    else
      do_require_assoc(query, identifier)
    end
  end

  defp do_require_assoc(query, :source) do
    from(mi in query, join: s in assoc(mi, :source), as: :source)
  end

  defp do_require_assoc(query, :media_profile) do
    query
    |> require_assoc(:source)
    |> join(:inner, [mi, source], mp in assoc(source, :media_profile), as: :media_profile)
  end

  # Non-dynamic query: controls ordering and produces highlighted snippets.
  # Uses ts_headline for snippet generation and ts_rank for relevance ordering.
  def matching_search_term(query, nil), do: query

  def matching_search_term(query, term) do
    case String.trim(term) do
      "" ->
        query

      trimmed ->
        tsquery = build_tsquery(trimmed)

        from(mi in query,
          where: fragment("search_vector @@ to_tsquery('english', ?)", ^tsquery),
          select_merge: %{
            matching_search_term:
              fragment("""
                coalesce(ts_headline('english', ?, to_tsquery('english', ?),
                  'StartSel=[PF_HIGHLIGHT], StopSel=[/PF_HIGHLIGHT], MaxWords=20, MinWords=5, ShortWord=3'), '')
                || ' ' ||
                coalesce(ts_headline('english', ?, to_tsquery('english', ?),
                  'StartSel=[PF_HIGHLIGHT], StopSel=[/PF_HIGHLIGHT], MaxWords=20, MinWords=5'), '')
              """, mi.title, ^tsquery, mi.description, ^tsquery)
          },
          order_by: [desc: fragment("ts_rank(search_vector, to_tsquery('english', ?))", ^tsquery)]
        )
    end
  end

  # Converts a plain search term into a Postgres tsquery string.
  # Each whitespace-separated word becomes a prefix-match term joined with &.
  # Example: "hello world" -> "hello:* & world:*"
  # This gives similar behaviour to the old SQLite FTS5 trigram tokenizer:
  # partial word matches are supported and multiple words must all be present.
  defp build_tsquery(term) do
    term
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.split(" ")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn word -> Regex.replace(~r/[^a-zA-Z0-9\-]/, word, "") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join(" & ", fn word -> "#{word}:*" end)
  end
end
