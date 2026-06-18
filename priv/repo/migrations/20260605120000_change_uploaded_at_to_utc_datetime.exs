defmodule Pinchflat.Repo.Migrations.ChangeUploadedAtToUtcDatetime do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE media_items ALTER COLUMN uploaded_at TYPE timestamptz USING uploaded_at::timestamptz"
    )
  end

  def down do
    execute("ALTER TABLE media_items ALTER COLUMN uploaded_at TYPE date USING uploaded_at::date")
  end
end
