defmodule Pinchflat.Repo.Migrations.AddAvailabilityFiltersToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :download_public_videos, :boolean, default: true, null: false
      add :download_members_videos, :boolean, default: false, null: false
    end
  end
end
