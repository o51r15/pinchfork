defmodule PinchflatWeb.Auth.UserSessionController do
  use PinchflatWeb, :controller

  alias Pinchflat.Accounts
  alias Pinchflat.Accounts.LoginThrottle
  alias PinchflatWeb.UserAuth

  plug :put_layout, html: {PinchflatWeb.Layouts, :auth}

  def new(conn, _params) do
    if Accounts.any_users?() do
      render(conn, :new, page_title: "Sign in", username: nil, error: nil)
    else
      redirect(conn, to: ~p"/setup")
    end
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password} = user_params}) do
    throttle_key = client_ip(conn)

    cond do
      LoginThrottle.blocked?(throttle_key) ->
        conn
        |> put_status(:too_many_requests)
        |> render(:new,
          page_title: "Sign in",
          username: username,
          error: "Too many failed attempts. Wait 15 minutes and try again."
        )

      user = Accounts.get_user_by_username_and_password(username, password) ->
        LoginThrottle.reset(throttle_key)
        UserAuth.log_in_user(conn, user, user_params)

      true ->
        LoginThrottle.record_failure(throttle_key)

        conn
        |> put_status(:unauthorized)
        |> render(:new, page_title: "Sign in", username: username, error: "That username and password don't match.")
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/login")

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "You've been signed out.")
    |> UserAuth.log_out_user()
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
