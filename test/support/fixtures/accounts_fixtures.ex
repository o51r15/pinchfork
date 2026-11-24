defmodule Pinchflat.AccountsFixtures do
  @moduledoc """
  Test helpers for creating users.
  """

  def valid_password, do: "correct horse battery"

  def unique_username, do: "user#{System.unique_integer([:positive])}"

  def user_fixture(attrs \\ %{}) do
    password = attrs[:password] || valid_password()

    {:ok, user} =
      attrs
      |> Enum.into(%{
        username: unique_username(),
        password: password,
        password_confirmation: password
      })
      |> Pinchflat.Accounts.create_user()

    user
  end
end
