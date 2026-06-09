defmodule Pinchflat.Repo.Migrations.SwitchFtsToSimpleAndGuardTrigger do
  use Ecto.Migration

  # Two changes in one migration:
  #
  # 1. Switch the search vector from the 'english' text-search config to 'simple'.
  #    'english' stems words and drops stopwords, which mangles the non-English
  #    titles that are common on YouTube and diverges from the old SQLite trigram
  #    behaviour. 'simple' does no stemming or stopword removal, which (combined
  #    with the prefix `:*` matching in MediaQuery.build_tsquery) is much closer to
  #    the original behaviour and language-agnostic.
  #
  # 2. Replace the single BEFORE INSERT OR UPDATE trigger with separate INSERT and
  #    UPDATE triggers, where the UPDATE trigger only fires when title/description
  #    actually change. Previously the tsvector was recomputed on every write to a
  #    media item (every last_error / prevent_download update, etc.).

  def up do
    execute("""
      CREATE OR REPLACE FUNCTION media_items_search_vector_trigger() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector :=
          setweight(to_tsvector('simple', coalesce(NEW.title, '')), 'A') ||
          setweight(to_tsvector('simple', coalesce(NEW.description, '')), 'B');
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS media_items_search_vector_update ON media_items;")

    execute("""
      CREATE TRIGGER media_items_search_vector_insert
      BEFORE INSERT ON media_items
      FOR EACH ROW EXECUTE FUNCTION media_items_search_vector_trigger();
    """)

    execute("""
      CREATE TRIGGER media_items_search_vector_update
      BEFORE UPDATE ON media_items
      FOR EACH ROW
      WHEN (OLD.title IS DISTINCT FROM NEW.title OR OLD.description IS DISTINCT FROM NEW.description)
      EXECUTE FUNCTION media_items_search_vector_trigger();
    """)

    # Backfill existing rows under the new 'simple' config
    execute("""
      UPDATE media_items SET search_vector =
        setweight(to_tsvector('simple', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('simple', coalesce(description, '')), 'B');
    """)
  end

  def down do
    execute("""
      CREATE OR REPLACE FUNCTION media_items_search_vector_trigger() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector :=
          setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
          setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B');
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS media_items_search_vector_insert ON media_items;")
    execute("DROP TRIGGER IF EXISTS media_items_search_vector_update ON media_items;")

    execute("""
      CREATE TRIGGER media_items_search_vector_update
      BEFORE INSERT OR UPDATE ON media_items
      FOR EACH ROW EXECUTE FUNCTION media_items_search_vector_trigger();
    """)

    execute("""
      UPDATE media_items SET search_vector =
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(description, '')), 'B');
    """)
  end
end
