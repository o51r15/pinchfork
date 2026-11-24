defmodule Pinchflat.Accounts.UserToken do
  @moduledoc """
  Session tokens. A random token is stored server-side and in the browser session, so signing
  out (or deleting a user) invalidates the session immediately.
  """

  use Ecto.Schema
  import Ecto.Query

  alias Pinchflat.Accounts.User

  @rand_size 32
  @session_validity_days 60

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def session_validity_days, do: @session_validity_days

  @doc """
  Builds a new session token for a user.

  Returns {binary(), %UserToken{}}
  """
  def build_session_token(%User{} = user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: token, context: "session", user_id: user.id}}
  end

  @doc """
  Query for the user behind a still-valid session token.
  """
  def verify_session_token_query(token) do
    from t in __MODULE__,
      join: u in assoc(t, :user),
      where: t.token == ^token and t.context == "session",
      where: t.inserted_at > ago(@session_validity_days, "day"),
      select: u
  end

  def by_token_and_context_query(token, context) do
    from t in __MODULE__, where: t.token == ^token and t.context == ^context
  end

  def by_user_and_contexts_query(%User{} = user, contexts) do
    from t in __MODULE__, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
