defmodule Pinchflat.Repo.Migrations.ChangeMediaItemsSearchIndexTokenizer do
  use Ecto.Migration

  # In SQLite this rebuilt the FTS5 index with a trigram tokenizer.
  # In Postgres, the tsvector trigger already handles this correctly,
  # and pg_trgm is available for trigram-style search if needed.
  # This migration backfills existing rows that were inserted before the trigger existed.
  def up do
    execute """
      UPDATE media_items SET search_vector =
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(description, '')), 'B');
    """
  end

  def down do
    execute "UPDATE media_items SET search_vector = NULL;"
  end
end
