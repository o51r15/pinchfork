defmodule PinchflatWeb.MediaProfiles.MediaProfileFormLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Profiles.MediaProfile

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  describe "new profile" do
    test "starts from the Default preset with an empty name", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/media_profiles/new")

      assert html =~ "New media profile"
      assert has_element?(view, ~s(#preset-default[aria-pressed="true"]))
      assert has_element?(view, ~s(#media_profile_name[value=""]))
      assert has_element?(view, ~s(#media_profile_preferred_resolution option[value="1080p"][selected]))
      refute html =~ "can&#39;t be blank"
      refute has_element?(view, "#danger-card")
    end

    test "picking a preset fills the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/new")
      view |> element("#preset-audio") |> render_click()

      assert has_element?(view, ~s(#preset-audio[aria-pressed="true"]))
      assert has_element?(view, ~s(#media_profile_name[value="Music"]))
      assert has_element?(view, ~s(#media_profile_preferred_resolution option[value="audio"][selected]))
      assert has_element?(view, ~s(#media_profile_output_path_template[value*="/music/"]))
    end

    test "a typed name survives picking a preset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/new")
      view |> form("#media-profile-form", media_profile: %{name: "My shows"}) |> render_change()
      view |> element("#preset-media_center") |> render_click()

      assert has_element?(view, ~s(#media_profile_name[value="My shows"]))
      assert has_element?(view, ~s(#media_profile_download_nfo[checked]))
    end

    test "creating goes to the new profile", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/new")
      view |> element("#preset-media_center") |> render_click()

      {:ok, show_conn} =
        view
        |> form("#media-profile-form", media_profile: %{name: "Shows 720p", preferred_resolution: "720p"})
        |> render_submit()
        |> follow_redirect(conn)

      profile = Repo.get_by!(MediaProfile, name: "Shows 720p")
      assert show_conn.request_path == ~p"/media_profiles/#{profile}"
      assert html_response(show_conn, 200) =~ "Media profile created."
      assert profile.preferred_resolution == :"720p"
      assert profile.download_nfo
      assert profile.redownload_delay_days == 1
    end

    test "a blank name is reported on save and nothing is created", %{conn: conn} do
      before = Repo.aggregate(MediaProfile, :count)
      {:ok, view, _html} = live(conn, ~p"/media_profiles/new")
      html = view |> form("#media-profile-form", media_profile: %{name: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Repo.aggregate(MediaProfile, :count) == before
    end

    test "a name already in use is reported as you type", %{conn: conn} do
      media_profile_fixture(name: "Archive")
      {:ok, view, _html} = live(conn, ~p"/media_profiles/new")

      html = view |> form("#media-profile-form", media_profile: %{name: "Archive"}) |> render_change()
      assert html =~ "is already used by another profile"
    end

    test "template_id copies another profile's settings but not its name", %{conn: conn} do
      template = media_profile_fixture(name: "My first profile", download_subs: true, sub_langs: "de")
      {:ok, view, html} = live(conn, ~p"/media_profiles/new?template_id=#{template.id}")

      assert html =~ ~s(Copied from &quot;My first profile&quot;)
      assert has_element?(view, ~s(#media_profile_sub_langs[value="de"]))
      assert has_element?(view, ~s(#media_profile_name[value=""]))
      refute has_element?(view, ~s(button[aria-pressed="true"]))
    end
  end

  describe "sponsorblock" do
    test "categories only show once SponsorBlock is on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/new")
      refute has_element?(view, "#sponsorblock-categories")

      view |> form("#media-profile-form", media_profile: %{sponsorblock_behaviour: "mark"}) |> render_change()
      assert has_element?(view, "#sponsorblock-categories")
      assert has_element?(view, "#sponsorblock-none")
    end

    test "ticked categories are saved, and unticking all clears them", %{conn: conn} do
      profile = media_profile_fixture(sponsorblock_behaviour: :remove, sponsorblock_categories: ["sponsor"])
      {:ok, view, _html} = live(conn, ~p"/media_profiles/#{profile}/edit")

      view
      |> form("#media-profile-form", media_profile: %{sponsorblock_categories: ["sponsor", "intro"]})
      |> render_submit()

      assert Repo.reload!(profile).sponsorblock_categories == ["sponsor", "intro"]

      # What the browser sends with every box unticked: only the blank from the hidden input
      render_submit(view, "save", %{"media_profile" => %{"sponsorblock_categories" => [""]}})
      assert Repo.reload!(profile).sponsorblock_categories == []
    end
  end

  describe "file name preview" do
    test "uses the newest video from a source on the profile", %{conn: conn} do
      profile =
        media_profile_fixture(output_path_template: "/{{ source_custom_name }}/{{ upload_year }}/{{ title }}.{{ ext }}")

      source = source_fixture(media_profile_id: profile.id, custom_name: "Woodworking Weekly")
      media_item_fixture(source_id: source.id, title: "Old one", uploaded_at: ~U[2021-01-01 00:00:00Z])
      media_item_fixture(source_id: source.id, title: "Shelf Build", uploaded_at: ~U[2023-05-01 00:00:00Z])

      {:ok, view, html} = live(conn, ~p"/media_profiles/#{profile}/edit")

      assert html =~ "Example, using &quot;Shelf Build&quot;"
      assert view |> element("#path-preview") |> render() =~ "/Woodworking Weekly/2023/Shelf Build.mp4"
    end

    test "follows the template as it's typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/new")

      view
      |> form("#media-profile-form", media_profile: %{output_path_template: "/{{ channel }}/{{ title }}.{{ ext }}"})
      |> render_change()

      assert view |> element("#path-preview") |> render() =~ "/Example Channel/How to Build a Bookshelf.mp4"
    end

    test "a template without the extension is flagged", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/new")

      html =
        view
        |> form("#media-profile-form", media_profile: %{output_path_template: "/{{ title }}"})
        |> render_change()

      assert html =~ "must end with .{{ ext }}"
    end
  end

  describe "edit profile" do
    setup do
      %{profile: media_profile_fixture(name: "Everyday", preferred_resolution: :"1080p")}
    end

    test "shows the saved values with no save bar", %{conn: conn, profile: profile} do
      {:ok, view, html} = live(conn, ~p"/media_profiles/#{profile}/edit")

      assert html =~ "Edit media profile"
      assert has_element?(view, ~s(#media_profile_name[value="Everyday"]))
      refute has_element?(view, "#preset-card")
      refute has_element?(view, "#media-profile-form-save-bar")
    end

    test "a change brings up the save bar and saving keeps you on the page", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/#{profile}/edit")

      view |> form("#media-profile-form", media_profile: %{preferred_resolution: "720p"}) |> render_change()
      assert has_element?(view, "#media-profile-form-save-bar")

      html = view |> form("#media-profile-form", media_profile: %{preferred_resolution: "720p"}) |> render_submit()

      assert html =~ "Media profile saved."
      assert Repo.reload!(profile).preferred_resolution == :"720p"
      refute has_element?(view, "#media-profile-form-save-bar")
    end

    test "discard puts the saved values back", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/#{profile}/edit")

      view |> form("#media-profile-form", media_profile: %{name: "Something else"}) |> render_change()
      view |> element("#media-profile-form-save-bar button", "Discard") |> render_click()

      assert has_element?(view, ~s(#media_profile_name[value="Everyday"]))
      refute has_element?(view, "#media-profile-form-save-bar")
    end

    test "its own name doesn't count as taken", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/#{profile}/edit")

      html = view |> form("#media-profile-form", media_profile: %{name: "Everyday"}) |> render_change()
      refute html =~ "is already used by another profile"
    end

    test "advanced opens when the profile uses it, and hidden values survive a save", %{conn: conn} do
      profile = media_profile_fixture(audio_track: "de", redownload_delay_days: 3)
      {:ok, view, _html} = live(conn, ~p"/media_profiles/#{profile}/edit")
      assert has_element?(view, "#media_profile_audio_track")

      view |> element("#toggle-advanced") |> render_click()
      refute has_element?(view, "#media_profile_audio_track")

      view |> form("#media-profile-form", media_profile: %{name: "Renamed"}) |> render_submit()

      profile = Repo.reload!(profile)
      assert profile.name == "Renamed"
      assert profile.audio_track == "de"
      assert profile.redownload_delay_days == 3
    end

    test "an unused profile can be deleted from here", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/media_profiles/#{profile}/edit")

      assert has_element?(view, ~s(#danger-card a[data-method="delete"]))
    end

    test "a profile in use points to its sources instead", %{conn: conn, profile: profile} do
      source_fixture(media_profile_id: profile.id)
      {:ok, view, html} = live(conn, ~p"/media_profiles/#{profile}/edit")

      assert html =~ "1 source uses this profile"
      refute has_element?(view, ~s(#danger-card a[data-method="delete"]))
    end
  end
end
