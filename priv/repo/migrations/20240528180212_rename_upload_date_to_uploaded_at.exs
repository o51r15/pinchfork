defmodule Pinchflat.Repo.Migrations.RenameUploadDateToUploadedAt do
  use Ecto.Migration

  def up do
    rename table(:media_items), :upload_date, to: :uploaded_at
    # Data migration removed: original converted SQLite date strings to datetime
    # strings, not needed on a fresh Postgres install with no existing data
  end

  def down do
    rename table(:media_items), :uploaded_at, to: :upload_date
  end
end
