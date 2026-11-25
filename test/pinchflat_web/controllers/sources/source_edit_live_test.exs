defmodule PinchflatWeb.Sources.SourceEditLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    %{source: source_fixture(custom_name: "Woodworking Weekly")}
  end

  describe "the page" do
    test "shows the everyday settings and hides the advanced ones", %{conn: conn, source: source} do
      {:ok, view, html} = live(conn, ~p"/sources/#{source}/edit")

      assert html =~ "Edit source"
      assert has_element?(view, ~s(#source_custom_name[value="Woodworking Weekly"]))
      refute has_element?(view, "#filters-card")
      refute has_element?(view, "#source-form-save-bar")
    end

    test "opens advanced when the source already uses it", %{conn: conn} do
      source = source_fixture(title_filter_regex: "tutorial")
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      assert has_element?(view, "#filters-card")
    end

    test "Show advanced reveals filters, files and access", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")
      view |> element("#toggle-advanced") |> render_click()

      assert has_element?(view, "#filters-card")
      assert has_element?(view, "#files-card")
      assert has_element?(view, "#access-card")
    end
  end

  describe "save model" do
    test "a change brings up the save bar and saving keeps you on the page", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      view |> form("#source-form", source: %{custom_name: "Woodworking"}) |> render_change()
      assert has_element?(view, "#source-form-save-bar")

      html = view |> form("#source-form", source: %{custom_name: "Woodworking"}) |> render_submit()

      assert html =~ "Source saved."
      assert Repo.reload!(source).custom_name == "Woodworking"
      refute has_element?(view, "#source-form-save-bar")
    end

    test "discard puts the saved values back", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      view |> form("#source-form", source: %{custom_name: "Something else"}) |> render_change()
      view |> element("#source-form-save-bar button", "Discard") |> render_click()

      assert has_element?(view, ~s(#source_custom_name[value="Woodworking Weekly"]))
      refute has_element?(view, "#source-form-save-bar")
    end

    test "saving with hidden advanced fields leaves them alone", %{conn: conn} do
      source = source_fixture(title_filter_regex: "tutorial", min_duration_seconds: 90)
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")
      view |> element("#toggle-advanced") |> render_click()

      view |> form("#source-form", source: %{custom_name: "Renamed"}) |> render_submit()

      source = Repo.reload!(source)
      assert source.custom_name == "Renamed"
      assert source.title_filter_regex == "tutorial"
      assert source.min_duration_seconds == 90
    end
  end

  describe "fields" do
    test "durations are typed as minutes and seconds", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")
      view |> element("#toggle-advanced") |> render_click()

      view |> form("#source-form", source: %{min_duration: "1:30", max_duration: "1:02:00"}) |> render_submit()

      source = Repo.reload!(source)
      assert source.min_duration_seconds == 90
      assert source.max_duration_seconds == 3720
    end

    test "shows saved durations as minutes and seconds", %{conn: conn} do
      source = source_fixture(min_duration_seconds: 125)
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      assert has_element?(view, ~s(#source_min_duration[value="2:05"]))
    end

    test "explains a duration it can't read", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")
      view |> element("#toggle-advanced") |> render_click()

      html = view |> form("#source-form", source: %{min_duration: "a while"}) |> render_submit()

      assert html =~ "Use minutes and seconds"
      assert Repo.reload!(source).min_duration_seconds == nil
    end

    test "counts which indexed videos the title filter matches", %{conn: conn, source: source} do
      media_item_fixture(source_id: source.id, title: "Dovetail tutorial")
      media_item_fixture(source_id: source.id, title: "Shop tour")
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")
      view |> element("#toggle-advanced") |> render_click()

      view |> form("#source-form", source: %{title_filter_regex: "tutorial"}) |> render_change()

      assert view |> element("#regex-matches") |> render() =~ ~r/Matches.*1.*of 2 indexed videos/s
    end

    test "Any date clears the cutoff date", %{conn: conn} do
      source = source_fixture(download_cutoff_date: ~D[2024-01-01])
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      view |> form("#source-form", source: %{cutoff_mode: "all"}) |> render_submit()

      assert Repo.reload!(source).download_cutoff_date == nil
    end

    test "Last 30 days sets the cutoff date", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      view |> form("#source-form", source: %{cutoff_mode: "date"}) |> render_change()
      view |> element("button", "Last 30 days") |> render_click()
      view |> form("#source-form") |> render_submit()

      assert Repo.reload!(source).download_cutoff_date == Date.add(Date.utc_today(), -30)
    end

    test "turning on Fast Indexing makes the full scan monthly", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      html = view |> form("#source-form", source: %{fast_index: "true"}) |> render_change()
      assert html =~ "Monthly while Fast Indexing is on"

      view |> form("#source-form", source: %{fast_index: "true"}) |> render_submit()
      assert Repo.reload!(source).index_frequency_minutes == 60 * 24 * 30
    end

    test "blocks a cookie-less client on a source that uses cookies", %{conn: conn} do
      source = source_fixture(cookie_behaviour: :when_needed)
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      html = view |> form("#source-form", source: %{client_override: "android_vr"}) |> render_change()

      assert html =~ "doesn&#39;t support cookies"
    end

    test "can switch profile", %{conn: conn, source: source} do
      other = media_profile_fixture(name: "Archive")
      {:ok, view, _html} = live(conn, ~p"/sources/#{source}/edit")

      view |> form("#source-form", source: %{media_profile_id: other.id}) |> render_submit()

      assert Repo.reload!(source).media_profile_id == other.id
    end
  end
end
