defmodule PinchflatWeb.PageSnapshotTest do
  @moduledoc """
  Writes the full HTML of key pages to tmp/snapshots so they can be screenshotted for
  visual review. Not part of the normal suite; run with `mix test --only snapshot`.
  """

  use PinchflatWeb.ConnCase

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

    test "pages", %{conn: conn, source: source} do
      snapshot("10-sources", conn |> get(~p"/sources") |> html_response(200))
      snapshot("11-source-show", conn |> get(~p"/sources/#{source}") |> html_response(200))
      snapshot("12-source-new", conn |> get(~p"/sources/new") |> html_response(200))
      snapshot("13-settings", conn |> get(~p"/settings") |> html_response(200))
      snapshot("14-media-profiles", conn |> get(~p"/media_profiles") |> html_response(200))
      snapshot("15-media-profile-new", conn |> get(~p"/media_profiles/new") |> html_response(200))
      snapshot("16-activity", conn |> get(~p"/activity") |> html_response(200))
      snapshot("17-stats", conn |> get(~p"/stats") |> html_response(200))
    end
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
