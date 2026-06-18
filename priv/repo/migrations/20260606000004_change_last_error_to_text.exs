defmodule Pinchflat.Repo.Migrations.ChangeLastErrorToText do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE media_items ALTER COLUMN last_error TYPE text")
  end

  def down do
    execute(
      "ALTER TABLE media_items ALTER COLUMN last_error TYPE varchar(255) USING left(last_error, 255)"
    )
  end
end
