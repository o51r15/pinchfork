defmodule Pinchflat.Repo.Migrations.AddSearchFieldToMediaItems do
  use Ecto.Migration

  def up do
    # Enable pg_trgm for future fuzzy/trigram search if needed
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

    # Add a tsvector column for full-text search
    alter table(:media_items) do
      add :search_vector, :tsvector
    end

    # GIN index for fast FTS lookups
    execute "CREATE INDEX media_items_search_vector_idx ON media_items USING GIN(search_vector);"

    # Trigger function to maintain search_vector on insert/update
    execute """
      CREATE OR REPLACE FUNCTION media_items_search_vector_trigger() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector :=
          setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
          setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B');
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    """

    execute """
      CREATE TRIGGER media_items_search_vector_update
      BEFORE INSERT OR UPDATE ON media_items
      FOR EACH ROW EXECUTE FUNCTION media_items_search_vector_trigger();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS media_items_search_vector_update ON media_items;"
    execute "DROP FUNCTION IF EXISTS media_items_search_vector_trigger();"
    execute "DROP INDEX IF EXISTS media_items_search_vector_idx;"

    alter table(:media_items) do
      remove :search_vector
    end
  end
end
