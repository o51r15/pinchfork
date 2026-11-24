defmodule PinchflatWeb.Auth.AuthFlowTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.AccountsFixtures

  alias Pinchflat.Accounts
  alias Pinchflat.Settings

  describe "with no users yet" do
    @describetag :unauthenticated

    test "every page sends you to setup", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/sources/new")) == ~p"/setup"
      assert redirected_to(get(conn, ~p"/settings")) == ~p"/setup"
    end

    test "the sign-in page sends you to setup", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/login")) == ~p"/setup"
    end

    test "the setup page shows the account form", %{conn: conn} do
      html = conn |> get(~p"/setup") |> html_response(200)

      assert html =~ "Welcome to Pinchfork"
      assert html =~ "Create account"
    end

    test "creating the account signs you in and continues setup", %{conn: conn} do
      Settings.set(onboarding: true)

      conn =
        post(conn, ~p"/setup", %{
          "user" => %{
            "username" => "michael",
            "password" => valid_password(),
            "password_confirmation" => valid_password()
          }
        })

      assert redirected_to(conn) == ~p"/setup/storage"
      assert get_session(conn, :user_token)
      assert Accounts.any_users?()
    end

    test "an existing install skips the rest of setup after the account", %{conn: conn} do
      Settings.set(onboarding: false)

      conn =
        post(conn, ~p"/setup", %{
          "user" => %{
            "username" => "michael",
            "password" => valid_password(),
            "password_confirmation" => valid_password()
          }
        })

      assert redirected_to(conn) == ~p"/sources"
    end

    test "shows errors for a bad account form", %{conn: conn} do
      conn =
        post(conn, ~p"/setup", %{
          "user" => %{"username" => "michael", "password" => "short", "password_confirmation" => "short"}
        })

      assert html_response(conn, 422) =~ "Use at least 12 characters"
      refute Accounts.any_users?()
    end
  end

  describe "once a user exists" do
    @describetag :unauthenticated

    setup do
      %{user: user_fixture(%{username: "michael"})}
    end

    test "pages send you to sign in and remember where you were going", %{conn: conn} do
      conn = get(conn, ~p"/settings")

      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, :user_return_to) == ~p"/settings"
    end

    test "the setup account step can't be replayed", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/setup")) == ~p"/login"

      conn =
        post(conn, ~p"/setup", %{
          "user" => %{
            "username" => "intruder",
            "password" => valid_password(),
            "password_confirmation" => valid_password()
          }
        })

      assert redirected_to(conn) == ~p"/login"
      refute Accounts.get_user_by_username_and_password("intruder", valid_password())
    end

    test "signing in with the right password works", %{conn: conn} do
      Settings.set(onboarding: false)

      conn = post(conn, ~p"/login", %{"user" => %{"username" => "michael", "password" => valid_password()}})

      assert redirected_to(conn) == ~p"/sources"
      assert get_session(conn, :user_token)
    end

    test "signing in goes back to the page you wanted", %{conn: conn} do
      conn = get(conn, ~p"/settings")
      conn = post(recycle(conn), ~p"/login", %{"user" => %{"username" => "michael", "password" => valid_password()}})

      assert redirected_to(conn) == ~p"/settings"
    end

    test "a wrong password shows an error and no session", %{conn: conn} do
      conn = post(conn, ~p"/login", %{"user" => %{"username" => "michael", "password" => "wrong password!!"}})

      assert html_response(conn, 401) =~ "don&#39;t match"
      refute get_session(conn, :user_token)
    end

    test "the sign-in page renders", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)

      assert html =~ "Sign in"
      assert html =~ "reset_password"
    end
  end

  describe "when signed in" do
    test "the sign-in page sends you onward", %{conn: conn} do
      Settings.set(onboarding: false)
      assert redirected_to(get(conn, ~p"/login")) == ~p"/sources"
    end

    test "signing out ends the session", %{conn: conn} do
      token = get_session(conn, :user_token)
      conn = delete(conn, ~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert is_nil(Accounts.get_user_by_session_token(token))
    end

    test "the app shell shows the account menu", %{conn: conn, user: user} do
      Settings.set(onboarding: false)
      html = conn |> get(~p"/settings") |> html_response(200)

      assert html =~ "Signed in as"
      assert html =~ user.username
    end
  end

  describe "LiveView pages" do
    @describetag :unauthenticated

    test "redirect to sign in when nobody is signed in", %{conn: conn} do
      user_fixture()
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/sources")
    end
  end
end
