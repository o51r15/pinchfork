defmodule Pinchflat.Repo.Migrations.AddClientOverrideToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :client_override, :string, default: nil
    end
  end
end
