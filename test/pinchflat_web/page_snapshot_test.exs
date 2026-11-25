defmodule PinchflatWeb.PageSnapshotTest do
  @moduledoc """
  Writes the full HTML of key pages to tmp/snapshots so they can be screenshotted for
  visual review. Not part of the normal suite; run with `mix test --only snapshot`.
  """

  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.AccountsFixtures

  alias Pinchflat.Settings

  @moduletag :snapshot
  @out_dir "tmp/snapshots"

  setup_all do
    File.rm_rf!(@out_dir)
    File.mkdir_p!(Path.join(@out_dir, "assets"))
    File.mkdir_p!(Path.join(@out_dir, "fonts"))
    File.cp!("priv/static/assets/app.css", Path.join([@out_dir, "assets", "app.css"]))

    for font <- File.ls!("priv/static/fonts"), String.ends_with?(font, ".woff2") do
      File.cp!(Path.join("priv/static/fonts", font), Path.join([@out_dir, "fonts", font]))
    end

    :ok
  end

  describe "signed out" do
    @describetag :unauthenticated

    test "setup account", %{conn: conn} do
      snapshot("01-setup-account", conn |> get(~p"/setup") |> html_response(200))
    end

    test "sign in", %{conn: conn} do
      user_fixture(%{username: "michael"})
      snapshot("02-login", conn |> get(~p"/login") |> html_response(200))

      conn = post(conn, ~p"/login", %{"user" => %{"username" => "michael", "password" => "nope nope nope"}})
      snapshot("02b-login-error", html_response(conn, 401))
    end
  end

  describe "setup wizard" do
    setup do
      Settings.set(onboarding: true)
      :ok
    end

    test "steps", %{conn: conn} do
      snapshot("03-setup-storage", conn |> get(~p"/setup/storage") |> html_response(200))
      snapshot("04-setup-youtube", conn |> get(~p"/setup/youtube") |> html_response(200))
      snapshot("05-setup-profile", conn |> get(~p"/setup/profile") |> html_response(200))
      media_profile_fixture(%{name: "Default"})
      snapshot("06-setup-source", conn |> get(~p"/setup/source") |> html_response(200))
    end
  end

  describe "app pages" do
    setup do
      Settings.set(onboarding: false)
      profile = media_profile_fixture(%{name: "Youtube no ads"})

      sources =
        for name <- ["That Chapter", "History Time", "The Why Files", "Financial Audit"] do
          source_fixture(%{custom_name: name, media_profile_id: profile.id})
        end

      for source <- sources, i <- 1..3 do
        media_item_fixture(%{source_id: source.id, media_downloaded_at: if(rem(i, 2) == 0, do: DateTime.utc_now())})
      end

      %{profile: profile, source: hd(sources)}
    end

    test "pages", %{conn: conn, source: source, profile: profile} do
      snapshot("18-media-profile-show", conn |> get(~p"/media_profiles/#{profile}") |> html_response(200))
      snapshot("20-settings-youtube", conn |> get(~p"/settings/youtube") |> html_response(200))

      snapshot_live("21-settings-youtube-edited", conn, ~p"/settings/youtube", fn view ->
        view |> form("#settings-form", setting: %{youtube_api_key: "AIzaSyD-example-key"}) |> render_change()
      end)

      snapshot("10-sources", conn |> get(~p"/sources") |> html_response(200))
      snapshot("11-source-show", conn |> get(~p"/sources/#{source}") |> html_response(200))
      snapshot("12-source-new", conn |> get(~p"/sources/new") |> html_response(200))

      stub(YtDlpRunnerMock, :run, fn _, :get_source_details, _, _, _ ->
        {:ok, ~s({"channel": "Pavlos Kapralos", "channel_id": "UCzgAonk4-uVhXXjKSF-Nz1A", "playlist_id": "UCzgAonk4-uVhXXjKSF-Nz1A"})}
      end)

      snapshot_live("12b-source-new-found", conn, ~p"/sources/new", fn view ->
        view
        |> form("#source-form", source: %{url: "https://www.youtube.com/@pavloskapralos", mode: "date"})
        |> render_change()

        render_async(view)
        view |> element("button", "Last year") |> render_click()
      end)

      for page <- ~w(downloads notifications feeds discovery general) do
        snapshot("22-settings-#{page}", conn |> get("/settings/#{page}") |> html_response(200))
      end

      snapshot_live("23-settings-downloads-advanced", conn, ~p"/settings/downloads", fn view ->
        view |> element("#toggle-advanced") |> render_click()
      end)

      snapshot("14-media-profiles", conn |> get(~p"/media_profiles") |> html_response(200))
      snapshot("15-media-profile-new", conn |> get(~p"/media_profiles/new") |> html_response(200))
      snapshot("16-activity", conn |> get(~p"/activity") |> html_response(200))
      snapshot("17-stats", conn |> get(~p"/stats") |> html_response(200))
    end
  end

  # Drives a LiveView into some state, then puts its live render into the page's static shell
  # (which carries the <head> and stylesheet) so the result can be screenshotted.
  defp snapshot_live(name, conn, path, interact) do
    shell = conn |> get(path) |> html_response(200)
    {:ok, view, _html} = live(conn, path)
    interact.(view)
    render_async(view, 10_000)
    body = render(view)

    snapshot(name, Regex.replace(~r{(<body[^>]*>).*(</body>)}s, shell, fn _, open, close -> open <> body <> close end))
  end

  defp snapshot(name, html) do
    html =
      html
      |> String.replace(~r{href="/assets/app\.css[^"]*"}, ~s(href="assets/app.css"))
      |> String.replace(~r{href="/fonts/}, ~s(href="fonts/))
      |> String.replace(~r{<script defer phx-track-static[^>]*></script>}, "")

    File.write!(Path.join(@out_dir, name <> ".html"), html)
  end
end
