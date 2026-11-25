defmodule PinchflatWeb.Sources.SourceNewLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source

  @channel_url "https://www.youtube.com/@woodworkingweekly"

  setup do
    Settings.set(onboarding: false)
    %{profile: media_profile_fixture(name: "TV Shows")}
  end

  describe "the form" do
    test "renders with the first profile chosen", %{conn: conn, profile: profile} do
      {:ok, view, html} = live(conn, ~p"/sources/new")

      assert html =~ "Add source"
      assert has_element?(view, ~s(#source_media_profile_id option[value="#{profile.id}"][selected]))
    end

    test "asks for a profile first when there are none", %{conn: conn, profile: profile} do
      Repo.delete!(profile)
      {:ok, _view, html} = live(conn, ~p"/sources/new")

      assert html =~ "You need a media profile first"
    end
  end

  describe "looking up the link" do
    test "fills in the name from YouTube", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_details, _, _, _ -> channel_json() end)
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      view |> form("#source-form", source: %{url: @channel_url}) |> render_change()
      html = render_async(view)

      assert html =~ "Woodworking Weekly"
      assert html =~ "Channel"
      assert has_element?(view, ~s(#source_custom_name[value="Woodworking Weekly"]))
    end

    test "keeps a name the user typed", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn _, :get_source_details, _, _, _ -> channel_json() end)
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      view |> form("#source-form", source: %{custom_name: "My woodworking"}) |> render_change()
      view |> form("#source-form", source: %{url: @channel_url}) |> render_change()
      render_async(view)

      assert has_element?(view, ~s(#source_custom_name[value="My woodworking"]))
    end

    test "spots a single-video link without looking it up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      html = view |> form("#source-form", source: %{url: "https://www.youtube.com/watch?v=abc"}) |> render_change()

      assert html =~ "a link to a single video"
    end

    test "says so when the link can't be found", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn _, :get_source_details, _, _, _ ->
        {:error, "ERROR: This channel does not exist", 1}
      end)

      {:ok, view, _html} = live(conn, ~p"/sources/new")
      view |> form("#source-form", source: %{url: "https://www.youtube.com/@nobody"}) |> render_change()

      html = render_async(view)
      assert html =~ "find a channel or playlist at that link"
      assert html =~ "This channel does not exist"
    end

    test "looks up a link passed in from Discovery", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_details, _, _, _ -> channel_json() end)

      {:ok, view, _html} = live(conn, ~p"/sources/new?prefill_url=#{@channel_url}")

      assert render_async(view) =~ "Woodworking Weekly"
    end
  end

  describe "adding" do
    test "adds the source with one lookup and opens it", %{conn: conn, profile: profile} do
      # Exactly one yt-dlp call: the preview's result is reused when saving
      expect(YtDlpRunnerMock, :run, 1, fn _, :get_source_details, _, _, _ -> channel_json() end)
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      view |> form("#source-form", source: %{url: @channel_url}) |> render_change()
      render_async(view)

      {:error, {:live_redirect, %{to: path}}} =
        view |> form("#source-form", source: %{mode: "all", fast_index: "true"}) |> render_submit()

      source = Repo.one!(Source)
      assert path == "/sources/#{source.id}"
      assert source.custom_name == "Woodworking Weekly"
      assert source.collection_type == :channel
      assert source.media_profile_id == profile.id
      assert source.download_media
      assert source.fast_index
      assert source.index_frequency_minutes == 60 * 24 * 30
    end

    test "New videos only starts from today", %{conn: conn} do
      stub(YtDlpRunnerMock, :run, fn _, :get_source_details, _, _, _ -> channel_json() end)
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      view |> form("#source-form", source: %{url: @channel_url, mode: "new"}) |> render_submit()

      assert Repo.one!(Source).download_cutoff_date == Date.utc_today()
    end

    test "From a date needs a date, then uses it", %{conn: conn} do
      stub(YtDlpRunnerMock, :run, fn _, :get_source_details, _, _, _ -> channel_json() end)
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      view |> form("#source-form", source: %{url: @channel_url, mode: "date"}) |> render_change()
      html = view |> form("#source-form", source: %{cutoff_date: ""}) |> render_submit()
      assert html =~ "Pick a date."

      view |> element("button", "Last year") |> render_click()
      view |> form("#source-form") |> render_submit()

      assert Repo.one!(Source).download_cutoff_date == Date.add(Date.utc_today(), -365)
    end

    test "Nothing yet indexes without downloading", %{conn: conn} do
      stub(YtDlpRunnerMock, :run, fn _, :get_source_details, _, _, _ -> channel_json() end)
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      view |> form("#source-form", source: %{url: @channel_url, mode: "none"}) |> render_submit()

      refute Repo.one!(Source).download_media
    end

    test "explains a duplicate", %{conn: conn, profile: profile} do
      stub(YtDlpRunnerMock, :run, fn _, :get_source_details, _, _, _ -> channel_json() end)
      source_fixture(collection_id: "UCwood", media_profile_id: profile.id)
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      html = view |> form("#source-form", source: %{url: @channel_url}) |> render_submit()

      assert html =~ "already a source with that profile"
    end

    test "needs a link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sources/new")

      assert view |> form("#source-form") |> render_submit() =~ "Paste a channel or playlist link."
    end

    test "copies settings from a template source", %{conn: conn} do
      stub(YtDlpRunnerMock, :run, fn _, :get_source_details, _, _, _ -> channel_json() end)

      template =
        source_fixture(
          custom_name: "Template source",
          title_filter_regex: "woodworking",
          cookie_behaviour: :when_needed,
          download_media: false
        )

      {:ok, view, html} = live(conn, ~p"/sources/new?template_id=#{template.id}")
      assert html =~ "Settings are copied from"

      view |> form("#source-form", source: %{url: @channel_url}) |> render_submit()

      source = Repo.get_by!(Source, collection_id: "UCwood")
      assert source.title_filter_regex == "woodworking"
      assert source.cookie_behaviour == :when_needed
      refute source.download_media
    end
  end

  defp channel_json do
    {:ok,
     Phoenix.json_library().encode!(%{
       channel: "Woodworking Weekly",
       channel_id: "UCwood",
       playlist_id: "UCwood",
       playlist_title: "Woodworking Weekly - Videos"
     })}
  end
end
