defmodule PinchflatWeb.Settings.VideoClientTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  describe "Settings › YouTube Access" do
    test "the default client is off, with no client picker", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/youtube")

      assert html =~ "Use a default client"
      refute has_element?(view, "#setting_default_client")
    end

    test "turning it on shows the picker and saves both", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      view |> form("#settings-form", setting: %{default_client_enabled: "true"}) |> render_change()
      assert has_element?(view, "#setting_default_client")

      view
      |> form("#settings-form", setting: %{default_client_enabled: "true", default_client: "tv"})
      |> render_submit()

      assert Settings.get!(:default_client_enabled)
      assert Settings.get!(:default_client) == "tv"
    end

    test "turning it off keeps the chosen client for next time", %{conn: conn} do
      Settings.set(default_client_enabled: true)
      Settings.set(default_client: "tv")
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      view |> form("#settings-form", setting: %{default_client_enabled: "false"}) |> render_submit()

      refute Settings.get!(:default_client_enabled)
      assert Settings.get!(:default_client) == "tv"
    end

    test "warns when the client can't use cookies and some sources do", %{conn: conn} do
      source_fixture(cookie_behaviour: :when_needed)
      Settings.set(default_client_enabled: true)
      Settings.set(default_client: "android_vr")

      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      assert view |> element("#default-client-cookie-note") |> render() =~
               "Sources that use cookies (1) keep the automatic choice"
    end
  end

  describe "a source" do
    test "Edit offers the default by name when it's on", %{conn: conn} do
      # Cookies in use opens the advanced cards, where the client picker lives
      source = source_fixture(cookie_behaviour: :when_needed)

      {:ok, _view, html} = live(conn, ~p"/sources/#{source}/edit")
      assert html =~ "Automatic (recommended)"

      Settings.set(default_client_enabled: true)
      {:ok, _view, html} = live(conn, ~p"/sources/#{source}/edit")
      assert html =~ "Use the default (web_creator, tv)"
    end

    test "the source page shows the client in use", %{conn: conn} do
      source = source_fixture()

      html = conn |> get(~p"/sources/#{source}") |> html_response(200)
      refute html =~ ~s(id="source-client")

      Settings.set(default_client_enabled: true)
      html = conn |> get(~p"/sources/#{source}") |> html_response(200)
      assert html =~ "Client: web_creator, tv (default)"

      own = source_fixture(client_override: "android_vr")
      html = conn |> get(~p"/sources/#{own}") |> html_response(200)
      assert html =~ "Client: android_vr"
      refute html =~ "android_vr (default)"
    end
  end
end
