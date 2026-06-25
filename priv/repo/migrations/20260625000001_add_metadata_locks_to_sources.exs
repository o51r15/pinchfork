defmodule Pinchflat.Repo.Migrations.AddMetadataLocksToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :custom_name_locked, :boolean, default: false, null: false
      add :description_locked, :boolean, default: false, null: false
      add :custom_poster_filepath, :string
    end
  end
end
