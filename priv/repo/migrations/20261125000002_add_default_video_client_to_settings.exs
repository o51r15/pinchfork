defmodule Pinchflat.Repo.Migrations.AddDefaultVideoClientToSettings do
  use Ecto.Migration

  # A default yt-dlp video client for every source that doesn't choose its own.
  # Off by default, so existing installs keep yt-dlp's automatic choice.
  def change do
    alter table(:settings) do
      add :default_client_enabled, :boolean, default: false, null: false
      add :default_client, :string, default: "web_creator,tv", null: false
    end
  end
end
