defmodule PinchflatWeb.Searches.SearchHTML do
  use PinchflatWeb, :html

  embed_templates "search_html/*"

  @doc """
  Highlight search terms in a string of text based on `[PF_HIGHLIGHT]` and `[/PF_HIGHLIGHT]` tags.
  Everything outside the tags is escaped as normal text.
  """
  attr :text, :string, required: true

  def highlight_search_terms(assigns) do
    assigns = assign(assigns, :marked, marked(assigns.text))

    ~H"{@marked}"
  end

  # Built as one string so no template whitespace lands between a word and its mark
  defp marked(text) do
    (text || "")
    |> String.split(~r{\[PF_HIGHLIGHT\]|\[/PF_HIGHLIGHT\]}, include_captures: true)
    |> Enum.map(fn
      "[PF_HIGHLIGHT]" -> ~s(<mark class="rounded-sm bg-accent-soft text-fg">)
      "[/PF_HIGHLIGHT]" -> "</mark>"
      fragment -> fragment |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    end)
    |> raw()
  end

  @doc """
  The description snippet with "…" where it was cut, at the start or the end.
  """
  def excerpt(%{matching_excerpt: snippet, description: description}) when is_binary(snippet) and snippet != "" do
    plain = snippet |> String.replace(~r{\[/?PF_HIGHLIGHT\]}, "") |> String.trim()
    full = String.trim(description || "")

    lead = if String.starts_with?(full, plain), do: "", else: "… "
    tail = if String.ends_with?(full, plain), do: "", else: " …"

    lead <> String.trim(snippet) <> tail
  end

  def excerpt(_result), do: nil

  @doc """
  The line under the page title.
  """
  def summary("", _count, _limit), do: nil
  # The empty card says it; a source match still shows above it
  def summary(_term, 0, _limit), do: nil
  def summary(term, 1, _limit), do: "1 video for “#{term}”."
  def summary(term, count, limit) when count >= limit, do: "The #{limit} best matches for “#{term}”."
  def summary(term, count, _limit), do: "#{count} videos for “#{term}”."
end
