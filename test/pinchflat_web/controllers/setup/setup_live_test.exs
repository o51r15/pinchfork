defmodule PinchflatWeb.Setup.SetupLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Profiles.MediaProfile

  setup do
    Settings.set(onboarding: true)
    :ok
  end

  test "the storage step lists the folder checks", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup/storage")

    assert html =~ "Storage check"
    assert html =~ "Downloads folder"
    assert html =~ "Writable"
  end

  test "an unknown step goes back to the first step", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/setup/storage"}}} = live(conn, ~p"/setup/nope")
  end

  test "the YouTube step saves the API key", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/youtube")

    view
    |> form("form", youtube: %{api_key: "  my-key  "})
    |> render_submit()

    assert_patch(view, ~p"/setup/profile")
    assert Settings.get!(:youtube_api_key) == "my-key"
  end

  test "the profile step creates a profile from the chosen preset", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/setup/profile")

    assert html =~ "TV &amp; media center"

    view |> element("button[phx-value-key=media_center]") |> render_click()
    view |> element("button", "Create profile") |> render_click()

    assert_patch(view, ~p"/setup/source")
    assert %MediaProfile{download_nfo: true, name: "TV Shows"} = Repo.one(MediaProfile)
  end

  test "creating the same preset twice gets a distinct name", %{conn: conn} do
    media_profile_fixture(%{name: "Default"})
    {:ok, view, _html} = live(conn, ~p"/setup/profile")

    view |> element("button", "Create profile") |> render_click()

    assert Repo.get_by(MediaProfile, name: "Default 2")
  end

  test "the source step asks for a profile first when there is none", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup/source")
    assert html =~ "You need a media profile first"
  end

  test "the source step shows a readable error when the URL can't be looked up", %{conn: conn} do
    stub(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
      {:error, "ERROR: Unsupported URL", 1}
    end)

    media_profile_fixture()
    {:ok, view, _html} = live(conn, ~p"/setup/source")

    html =
      view
      |> form("form", source: %{url: "https://www.youtube.com/@nobody-here"})
      |> render_submit()

    assert html =~ "role=\"alert\""
    assert Pinchflat.Repo.aggregate(Pinchflat.Sources.Source, :count) == 0
  end

  test "the source step adds the source and moves on", %{conn: conn} do
    stub(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
      {:ok, Pinchflat.SourcesFixtures.source_details_return_fixture()}
    end)

    profile = media_profile_fixture()
    {:ok, view, _html} = live(conn, ~p"/setup/source")

    view
    |> form("form", source: %{url: "https://www.youtube.com/@test", media_profile_id: profile.id, mode: "none"})
    |> render_submit()

    assert_patch(view, ~p"/setup/done")
    assert %{download_media: false} = Pinchflat.Repo.one(Pinchflat.Sources.Source)
  end

  test "the done step finishes setup", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup/done")

    assert html =~ "all set"
    refute Settings.get!(:onboarding)
  end

  test "setup pages send you to sources once setup is finished", %{conn: conn} do
    Settings.set(onboarding: false)
    assert {:error, {:live_redirect, %{to: "/sources"}}} = live(conn, ~p"/setup/storage")
  end
end
