defmodule PinchflatWeb.UserAuth do
  @moduledoc """
  Sign-in sessions for the web UI.

  - While no user exists, every page sends the visitor to the setup wizard.
  - Otherwise every page needs a signed-in user and sends everyone else to the sign-in page.
  - Feed, stream and health URLs are not covered here; they keep their own token and
    basic-auth rules so podcast apps keep working.
  """

  use PinchflatWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Pinchflat.Accounts
  alias Pinchflat.Settings

  @remember_cookie "_pinchfork_remember"
  @remember_options [
    sign: true,
    max_age: 60 * 60 * 24 * Pinchflat.Accounts.UserToken.session_validity_days(),
    same_site: "Lax"
  ]

  @doc """
  Signs the user in: renews the session (against fixation), stores a fresh token and
  redirects to where they were going.
  """
  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_cookie(token, params)
    |> redirect(to: return_to || after_sign_in_path())
  end

  @doc """
  Where to go after signing in: the rest of the setup wizard if it isn't finished,
  otherwise the library.
  """
  def after_sign_in_path do
    if setup_in_progress?(), do: ~p"/setup/storage", else: ~p"/sources"
  end

  @doc """
  Signs the user out everywhere this browser knows about.
  """
  def log_out_user(conn) do
    if token = get_session(conn, :user_token), do: Accounts.delete_user_session_token(token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      PinchflatWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_cookie)
    |> redirect(to: ~p"/login")
  end

  @doc """
  Plug: loads the signed-in user (from the session or the remember-me cookie) into
  `conn.assigns.current_user`.
  """
  def fetch_current_user(conn, _opts) do
    {token, conn} = ensure_user_token(conn)
    assign(conn, :current_user, token && Accounts.get_user_by_session_token(token))
  end

  @doc """
  Plug: lets the request through only for a signed-in user. Sends visitors to setup when
  there are no users yet, and to the sign-in page otherwise.
  """
  def require_authenticated_user(conn, _opts) do
    cond do
      conn.assigns[:current_user] ->
        conn

      not Accounts.any_users?() ->
        conn |> redirect(to: ~p"/setup") |> halt()

      true ->
        conn
        |> maybe_store_return_to()
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end

  @doc """
  Plug: keeps signed-in users away from the sign-in page.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: after_sign_in_path()) |> halt()
    else
      conn
    end
  end

  @doc """
  LiveView hooks.

    * `:ensure_authenticated` - halts and redirects when nobody is signed in
    * `:mount_current_user` - just assigns `current_user` (may be nil)
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if token = session["user_token"], do: Accounts.get_user_by_session_token(token)
    end)
  end

  @doc """
  Whether the first user exists but the rest of the setup wizard isn't finished.
  """
  def setup_in_progress? do
    case Settings.get(:onboarding) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_cookie])

      if token = conn.cookies[@remember_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  defp maybe_write_remember_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_cookie, token, @remember_options)
  end

  defp maybe_write_remember_cookie(conn, _token, _params), do: conn

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
