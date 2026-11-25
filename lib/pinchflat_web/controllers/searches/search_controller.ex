defmodule PinchflatWeb.Searches.SearchController do
  use PinchflatWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources.Source

  @limit 50

  def show(conn, params) do
    search_term = params |> Map.get("q", "") |> to_string() |> String.trim()

    {results, sources} =
      if search_term == "" do
        {[], []}
      else
        {Media.search(search_term, limit: @limit) |> Repo.preload(:source), matching_sources(search_term)}
      end

    render(conn, :show,
      search_term: search_term,
      search_results: results,
      sources: sources,
      limit: @limit,
      page_title: if(search_term == "", do: "Search", else: "Search: #{search_term}")
    )
  end

  # Sources whose name contains the term, so searching a channel's name finds the channel too
  defp matching_sources(term) do
    pattern = "%" <> String.replace(term, ~w(\\ % _), &("\\" <> &1)) <> "%"

    Repo.all(
      from s in Source,
        where: is_nil(s.marked_for_deletion_at) and ilike(s.custom_name, ^pattern),
        order_by: [asc: s.custom_name],
        limit: 8
    )
  end
end
