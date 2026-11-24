defmodule PinchflatWeb.Setup.SetupController do
  @moduledoc """
  First step of the setup wizard: creating the admin account. It's a plain controller (not a
  LiveView) because signing in has to write the session cookie. The remaining steps live in
  `PinchflatWeb.Setup.SetupLive`.
  """

  use PinchflatWeb, :controller

  alias Pinchflat.Accounts
  alias Pinchflat.Accounts.User
  alias PinchflatWeb.UserAuth

  plug :put_layout, html: {PinchflatWeb.Layouts, :auth}

  def account(conn, _params) do
    cond do
      not Accounts.any_users?() ->
        render_account(conn, Accounts.change_user_registration(%User{}, %{"username" => suggested_username()}))

      conn.assigns[:current_user] ->
        redirect(conn, to: UserAuth.after_sign_in_path())

      true ->
        redirect(conn, to: ~p"/login")
    end
  end

  def create_account(conn, %{"user" => user_params}) do
    case Accounts.create_first_user(user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Account created. You're signed in.")
        |> UserAuth.log_in_user(user)

      {:error, :already_set_up} ->
        redirect(conn, to: ~p"/login")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_account(changeset)
    end
  end

  def create_account(conn, _params), do: redirect(conn, to: ~p"/setup")

  defp render_account(conn, changeset) do
    render(conn, :account,
      page_title: "Set up Pinchfork",
      form: Phoenix.Component.to_form(changeset, as: :user),
      env_username: env_username(),
      min_password: User.min_password_length()
    )
  end

  # Existing installs that used basic auth keep the same username by default
  defp suggested_username, do: env_username() || ""

  defp env_username do
    case Application.get_env(:pinchflat, :basic_auth_username) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end
end
