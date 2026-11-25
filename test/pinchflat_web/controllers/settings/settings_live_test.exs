defmodule PinchflatWeb.Settings.SettingsLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  @cookie_file "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tabc123\n"

  setup do
    Settings.set(onboarding: false)
    File.write!(cookies_path(), "")

    :ok
  end

  describe "routing" do
    test "renders the YouTube Access page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/youtube")

      assert html =~ "YouTube Access"
      assert html =~ "YouTube Data API"
      assert html =~ "Cookies"
      assert html =~ "PO token server"
    end

    test "sends unknown pages to the first settings page", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/settings/youtube"}}} = live(conn, ~p"/settings/nope")
    end

    @tag :unauthenticated
    test "requires a signed-in user", %{conn: conn} do
      Pinchflat.AccountsFixtures.user_fixture()

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/settings/youtube")
    end
  end

  describe "save model" do
    test "shows the save bar only once something changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")
      refute has_element?(view, "#settings-form-save-bar")

      view |> form("#settings-form", setting: %{youtube_api_key: "abc"}) |> render_change()
      assert has_element?(view, "#settings-form-save-bar")
    end

    test "saves the page's fields and hides the bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      view |> form("#settings-form", setting: %{youtube_api_key: "abc"}) |> render_change()
      html = view |> form("#settings-form", setting: %{youtube_api_key: "abc"}) |> render_submit()

      assert html =~ "Settings saved."
      assert Settings.get!(:youtube_api_key) == "abc"
      refute has_element?(view, "#settings-form-save-bar")
    end

    test "never saves fields that belong to another page", %{conn: conn} do
      Settings.set(apprise_server: "keep://me")
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      render_submit(view, "save", %{"setting" => %{"youtube_api_key" => "abc", "apprise_server" => "changed://"}})

      assert Settings.get!(:apprise_server) == "keep://me"
      assert Settings.get!(:youtube_api_key) == "abc"
    end

    test "discard puts the saved value back", %{conn: conn} do
      Settings.set(youtube_api_key: "original")
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      view |> form("#settings-form", setting: %{youtube_api_key: "edited"}) |> render_change()
      html = view |> element("#settings-form-save-bar button", "Discard") |> render_click()

      assert html =~ ~s(value="original")
      refute has_element?(view, "#settings-form-save-bar")
      assert Settings.get!(:youtube_api_key) == "original"
    end
  end

  describe "API key" do
    test "asks for a key before testing an empty one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      assert view |> element("button", "Test key") |> render_click() =~ "Enter a key first."
    end

    test "tests the key that's typed in, even before saving", %{conn: conn} do
      expect(HTTPClientMock, :get, fn url, _opts ->
        assert url =~ "key=typed-key"
        {:ok, ~s({"items": []})}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings/youtube")
      view |> form("#settings-form", setting: %{youtube_api_key: "typed-key, second"}) |> render_change()
      view |> element("button", "Test key") |> render_click()

      assert render_async(view) =~ "Key works"
    end

    test "counts the sources that use Fast Indexing", %{conn: conn} do
      source_fixture(fast_index: true)
      source_fixture(fast_index: true)
      source_fixture(fast_index: false)

      {:ok, _view, html} = live(conn, ~p"/settings/youtube")

      assert html =~ "Used by Fast Indexing on 2 sources"
    end
  end

  describe "cookies" do
    test "shows when there is no file", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/youtube")

      assert html =~ "No file"
      assert html =~ "Upload file"
    end

    test "uploading saves the file straight away", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      upload =
        file_input(view, "#cookies-form", :cookies, [
          %{name: "cookies.txt", content: @cookie_file, type: "text/plain"}
        ])

      render_upload(upload, "cookies.txt")

      assert File.read!(cookies_path()) == @cookie_file
      html = render(view)
      assert html =~ "Cookies file saved."
      assert html =~ "Replace file"
    end

    test "warns when the file has no YouTube cookies", %{conn: conn} do
      File.write!(cookies_path(), "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tSID\tabc\n")

      {:ok, _view, html} = live(conn, ~p"/settings/youtube")

      assert html =~ "No YouTube cookies in file"
    end

    test "remove empties the file", %{conn: conn} do
      File.write!(cookies_path(), @cookie_file)
      {:ok, view, html} = live(conn, ~p"/settings/youtube")
      assert html =~ "Saved"

      html = view |> element("button", "Remove") |> render_click()

      assert html =~ "No file"
      assert File.read!(cookies_path()) == ""
    end
  end

  describe "PO token server" do
    test "reports the sidecar status after the page loads", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/youtube")

      # There is no bgutil-provider in the test environment
      assert render_async(view, 10_000) =~ "Not reachable"
    end
  end

  defp cookies_path do
    Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")
  end
end
