defmodule Pinchflat.Accounts.User do
  @moduledoc """
  A person who can sign in to Pinchfork. The first one is created by the setup wizard.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Accounts.Password

  @min_password 12
  @max_password 128

  schema "users" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  def min_password_length, do: @min_password

  @doc """
  Changeset for creating a user. Validates and hashes the password.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:username, :password, :password_confirmation])
    |> validate_username()
    |> validate_password(opts)
  end

  @doc """
  Changeset for changing an existing user's password.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_password(opts)
  end

  defp validate_username(changeset) do
    changeset
    |> update_change(:username, &String.trim/1)
    |> validate_required([:username], message: "Enter a username")
    |> validate_length(:username, min: 3, max: 40, message: "Use 3 to 40 characters")
    |> validate_format(:username, ~r/^[A-Za-z0-9._-]+$/, message: "Use letters, numbers, dots, dashes or underscores")
    |> unique_constraint(:username, name: :users_username_lower_index, message: "That username is taken")
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password], message: "Enter a password")
    |> validate_length(:password,
      min: @min_password,
      max: @max_password,
      message: "Use at least #{@min_password} characters"
    )
    |> validate_confirmation(:password, message: "The passwords don't match")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    password = get_change(changeset, :password)

    if Keyword.get(opts, :hash_password, true) && password && changeset.valid? do
      changeset
      |> put_change(:password_hash, Password.hash(password))
      |> delete_change(:password)
      |> delete_change(:password_confirmation)
    else
      changeset
    end
  end
end
