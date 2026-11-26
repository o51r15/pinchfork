defmodule Pinchflat.Repo.Migrations.DefaultRequestPause60 do
  use Ecto.Migration

  # New installs start at the recommended 60-second pause between requests to YouTube.
  # Existing installs keep whatever they have set.
  def up do
    alter table(:settings) do
      modify :extractor_sleep_interval_seconds, :integer, default: 60, null: false
    end
  end

  def down do
    alter table(:settings) do
      modify :extractor_sleep_interval_seconds, :integer, default: 0, null: false
    end
  end
end
