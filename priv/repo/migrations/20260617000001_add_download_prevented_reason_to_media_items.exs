defmodule Pinchflat.Repo.Migrations.AddDownloadPreventedReasonToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :download_prevented_reason, :string, null: true, default: nil
    end
  end
end
