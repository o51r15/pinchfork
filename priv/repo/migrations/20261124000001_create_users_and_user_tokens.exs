defmodule Pinchflat.Repo.Migrations.CreateUsersAndUserTokens do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # Usernames are unique regardless of letter case
    create unique_index(:users, ["lower(username)"], name: :users_username_lower_index)

    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:context, :token])
  end
end
