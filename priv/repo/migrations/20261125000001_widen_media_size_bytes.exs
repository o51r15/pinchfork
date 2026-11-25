defmodule Pinchflat.Repo.Migrations.WidenMediaSizeBytes do
  use Ecto.Migration

  # media_size_bytes came over from SQLite, where integers are 64-bit, as a Postgres `integer`
  # (32-bit, max 2,147,483,647). Any single video over ~2.1 GB couldn't store its size.
  def change do
    alter table(:media_items) do
      modify :media_size_bytes, :bigint, from: :integer
    end
  end
end
