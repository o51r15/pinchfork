defmodule Pinchflat.Media.MediaItemsSearchIndex do
  @moduledoc """
  Represents the tsvector search_vector column on media_items used for
  Postgres full-text search. Kept as a thin module so the rest of the
  codebase can reference it by name without knowing the underlying mechanism.

  In the SQLite version this was an FTS5 virtual table. In Postgres it is
  simply a maintained tsvector column with a GIN index, updated by a trigger.
  """

  # No separate schema needed — search_vector lives on media_items itself.
  # This module exists only as a named anchor for query helpers.
end
