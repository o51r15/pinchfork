defmodule Pinchflat.Accounts do
  @moduledoc """
  Users and sign-in sessions.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Accounts.User
  alias Pinchflat.Accounts.Password
  alias Pinchflat.Accounts.UserToken

  @doc """
  Whether any user has been created yet. While none exists, Pinchfork sends every
  visitor to the setup wizard.

  Returns boolean()
  """
  def any_users? do
    Repo.exists?(User)
  end

  @doc """
  Returns a changeset for the account-creation form.
  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Creates a user.

  Returns {:ok, %User{}} | {:error, %Ecto.Changeset{}}
  """
  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates the first user, but only while no user exists. Used by the setup wizard so the
  account step can't be replayed to add a second admin.

  Returns {:ok, %User{}} | {:error, %Ecto.Changeset{}} | {:error, :already_set_up}
  """
  def create_first_user(attrs) do
    if any_users?(), do: {:error, :already_set_up}, else: create_user(attrs)
  end

  @doc """
  Finds a user by username (any letter case) and checks the password.

  Returns %User{} | nil
  """
  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = Repo.one(from u in User, where: fragment("lower(?)", u.username) == ^String.downcase(String.trim(username)))

    cond do
      user && Password.verify(password, user.password_hash) ->
        user

      user ->
        nil

      true ->
        Password.no_user_verify()
        nil
    end
  end

  def get_user_by_username_and_password(_, _), do: nil

  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Changes a user's password after checking the current one. Signs out every other session.

  Returns {:ok, %User{}} | {:error, %Ecto.Changeset{}}
  """
  def update_user_password(%User{} = user, current_password, attrs) do
    changeset = User.password_changeset(user, attrs)

    if Password.verify(current_password || "", user.password_hash) do
      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, changeset)
      |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, ["session"]))
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, :user, changeset, _} -> {:error, changeset}
      end
    else
      {:error,
       Ecto.Changeset.add_error(%{changeset | action: :update}, :current_password, "That isn't your current password")}
    end
  end

  @doc """
  Sets a new password without checking the old one. For the command-line reset only.

  Returns {:ok, %User{}} | {:error, %Ecto.Changeset{}}
  """
  def reset_user_password(%User{} = user, new_password) do
    user
    |> User.password_changeset(%{password: new_password, password_confirmation: new_password})
    |> Repo.update()
    |> tap(fn
      {:ok, user} -> Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session"]))
      _ -> :ok
    end)
  end

  @doc """
  Creates a session token for a user.

  Returns binary()
  """
  def generate_user_session_token(%User{} = user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Returns the user for a valid session token.

  Returns %User{} | nil
  """
  def get_user_by_session_token(token) when is_binary(token) do
    Repo.one(UserToken.verify_session_token_query(token))
  end

  def get_user_by_session_token(_), do: nil

  @doc """
  Deletes a session token (signing that session out).
  """
  def delete_user_session_token(token) when is_binary(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  def delete_user_session_token(_), do: :ok
end
