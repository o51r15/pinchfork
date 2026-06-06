defmodule Pinchflat.Repo.Migrations.AddErrorTypeToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :error_type, :string, size: 50
    end
  end
end
