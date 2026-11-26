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

    test "sends unknown pages to General", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/settings/general"}}} = live(conn, ~p"/settings/nope")
    end

    test "every page renders with its title and the sidebar", %{conn: conn} do
      for {page, title} <- [
            {"downloads", "Downloads"},
            {"youtube", "YouTube Access"},
            {"notifications", "Notifications"},
            {"feeds", "Feeds &amp; Sharing"},
            {"discovery", "Discovery"},
            {"general", "General"}
          ] do
        {:ok, _view, html} = live(conn, "/settings/#{page}")

        assert html =~ title
        assert html =~ ~s(href="/settings/#{page}")
      end
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

  describe "Downloads" do
    test "hides formats until Show advanced is pressed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/downloads")
      refute has_element?(view, "#advanced-formats")

      view |> element("#toggle-advanced") |> render_click()

      assert has_element?(view, "#advanced-formats")
      assert has_element?(view, "#setting_video_codec_preference option[value=av01]")
    end

    test "checks the speed limit as you type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/downloads")

      html = view |> form("#settings-form", setting: %{download_throughput_limit: "fast"}) |> render_change()
      assert html =~ "use a number with K, M or G"

      html = view |> form("#settings-form", setting: %{download_throughput_limit: "4.2M"}) |> render_change()
      refute html =~ "use a number with K, M or G"
    end

    test "saves pacing and keeps hidden advanced values", %{conn: conn} do
      Settings.set(video_codec_preference: "vp9")
      {:ok, view, _html} = live(conn, ~p"/settings/downloads")

      view
      |> form("#settings-form", setting: %{extractor_sleep_interval_seconds: "5", download_throughput_limit: "500K"})
      |> render_submit()

      assert Settings.get!(:extractor_sleep_interval_seconds) == 5
      assert Settings.get!(:download_throughput_limit) == "500K"
      assert Settings.get!(:video_codec_preference) == "vp9"
    end

    test "warns when the pause between requests is shorter than the recommended 60", %{conn: conn} do
      Settings.set(extractor_sleep_interval_seconds: 60)
      {:ok, view, html} = live(conn, ~p"/settings/downloads")

      refute html =~ "short-pause-warning"

      html = view |> form("#settings-form", setting: %{extractor_sleep_interval_seconds: "5"}) |> render_change()

      assert html =~ "short-pause-warning"
    end

    test "saves codecs and plain file names", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/downloads")
      view |> element("#toggle-advanced") |> render_click()

      view
      |> form("#settings-form",
        setting: %{video_codec_preference: "av01", audio_codec_preference: "opus", restrict_filenames: "true"}
      )
      |> render_submit()

      assert Settings.get!(:video_codec_preference) == "av01"
      assert Settings.get!(:audio_codec_preference) == "opus"
      assert Settings.get!(:restrict_filenames)
    end

    test "keeps an unusual codec someone typed in the old free-text box", %{conn: conn} do
      Settings.set(video_codec_preference: "vp9.2")
      {:ok, view, _html} = live(conn, ~p"/settings/downloads")

      assert view |> element("#toggle-advanced") |> render_click() =~ "vp9.2 (custom value)"
    end
  end

  describe "Notifications" do
    test "builds a Pushover URL from the two fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      view
      |> form("#settings-form", pushover: %{user_key: "user123", api_token: "token456"})
      |> render_submit()

      assert Settings.get!(:apprise_server) == "pover://user123@token456"
    end

    test "opens an existing Pushover URL as its two fields", %{conn: conn} do
      Settings.set(apprise_server: "pover://user123@token456")
      {:ok, _view, html} = live(conn, ~p"/settings/notifications")

      assert html =~ ~s(value="user123")
      assert html =~ ~s(value="token456")
    end

    test "saves any other Apprise URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      view |> element("button", "Other service") |> render_click()

      view |> form("#settings-form", setting: %{apprise_server: "ntfys://ntfy.sh/topic"}) |> render_submit()

      assert Settings.get!(:apprise_server) == "ntfys://ntfy.sh/topic"
    end

    test "sends a test to what's typed", %{conn: conn} do
      expect(AppriseRunnerMock, :run, fn ["ntfys://ntfy.sh/topic"], opts ->
        assert opts[:title] == "Pinchfork test"
        {:ok, ""}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      view |> element("button", "Other service") |> render_click()
      view |> form("#settings-form", setting: %{apprise_server: "ntfys://ntfy.sh/topic"}) |> render_change()
      view |> element("button", "Send a test") |> render_click()

      assert render_async(view) =~ "Sent. Check your device."
    end

    test "asks for a server before testing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      assert view |> element("button", "Send a test") |> render_click() =~ "Enter a server first."
    end
  end

  describe "Feeds & Sharing" do
    test "shows the OPML link with its token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/feeds")

      assert html =~ "route_token=#{Settings.get!(:route_token)}"
    end

    test "can make a new OPML link", %{conn: conn} do
      old_token = Settings.get!(:route_token)
      {:ok, view, _html} = live(conn, ~p"/settings/feeds")

      html = view |> element("button", "Make a new link") |> render_click()

      new_token = Settings.get!(:route_token)
      assert new_token != old_token
      assert html =~ "route_token=#{new_token}"
    end
  end

  describe "Discovery" do
    test "saves the switches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/discovery")

      view
      |> form("#settings-form", setting: %{discovery_enabled: "true", discovery_g2_enabled: "false"})
      |> render_submit()

      assert Settings.get!(:discovery_enabled)
      refute Settings.get!(:discovery_g2_enabled)
    end

    test "hides the methods that don't exist yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/discovery")
      # Visible text only: CSRF tokens in the markup are random and can contain "G1"
      text = view |> render() |> Floki.parse_fragment!() |> Floki.text()

      refute text =~ "LLM"
      refute text =~ "G1"
    end

    test "restores a dismissed channel", %{conn: conn} do
      {:ok, suggestion} =
        Pinchflat.Discovery.upsert_suggestion(%{
          channel_id: "UC123",
          url: "https://www.youtube.com/channel/UC123",
          name: "Woodworking Weekly",
          scanned_at: DateTime.utc_now()
        })

      Pinchflat.Discovery.dismiss_suggestion(suggestion)
      {:ok, view, html} = live(conn, ~p"/settings/discovery")
      assert html =~ "Woodworking Weekly"

      html = view |> element("#dismissed-#{suggestion.id} button", "Restore") |> render_click()

      refute html =~ "Woodworking Weekly"
      assert Pinchflat.Discovery.get_suggestion!(suggestion.id).status == "pending"
    end
  end

  describe "General" do
    test "shows the account and Docker settings", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/settings/general")

      assert html =~ user.username
      assert html =~ "YT_DLP_WORKER_CONCURRENCY"
      assert html =~ "Copy diagnostic info"
    end

    test "refuses a password change with the wrong current password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/general")

      html =
        view
        |> form("#password-form",
          password: %{
            current_password: "not my password",
            password: "a brand new password",
            password_confirmation: "a brand new password"
          }
        )
        |> render_submit()

      assert html =~ "That isn&#39;t your current password"
    end

    test "changing the password signs you out", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings/general")

      result =
        view
        |> form("#password-form",
          password: %{
            current_password: Pinchflat.AccountsFixtures.valid_password(),
            password: "a brand new password",
            password_confirmation: "a brand new password"
          }
        )
        |> render_submit()

      assert {:error, {:redirect, %{to: "/login"}}} = result
      assert Pinchflat.Accounts.get_user_by_username_and_password(user.username, "a brand new password")
    end

    test "can run the setup wizard again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/general")

      assert {:error, {:live_redirect, %{to: "/setup/storage"}}} =
               view |> element("button", "Run setup again") |> render_click()

      assert Settings.get!(:onboarding)
    end
  end

  defp cookies_path do
    Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")
  end
end
