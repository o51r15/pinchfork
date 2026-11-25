defmodule Pinchflat.Repo.Migrations.AddNotificationEventsToSettings do
  use Ecto.Migration

  # One switch per notification event. "New videos found" was the only notification before,
  # so it starts on; the rest start off. health_problems remembers which problems were last
  # reported, so each one is only sent when it starts and when it's fixed.
  def change do
    alter table(:settings) do
      add :notify_new_media, :boolean, default: true, null: false
      add :notify_download_finished, :boolean, default: false, null: false
      add :notify_download_failed, :boolean, default: false, null: false
      add :notify_source_added, :boolean, default: false, null: false
      add :notify_source_removed, :boolean, default: false, null: false
      add :notify_problems, :boolean, default: false, null: false
      add :health_problems, {:array, :string}, default: [], null: false
    end
  end
end
