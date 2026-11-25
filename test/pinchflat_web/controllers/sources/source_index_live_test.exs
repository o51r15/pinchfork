defmodule PinchflatWeb.Sources.SourceIndexLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  describe "source cards" do
    test "count only the videos the source is meant to download", %{conn: conn} do
      profile = media_profile_fixture(shorts_behaviour: :exclude, livestream_behaviour: :exclude)
      source = source_fixture(media_profile_id: profile.id, custom_name: "Composer")

      media_item_fixture(source_id: source.id, media_filepath: "/tmp/a.mp4")
      media_item_fixture(source_id: source.id, media_filepath: "/tmp/b.mp4")
      # Skipped by the profile: not part of the denominator
      media_item_fixture(source_id: source.id, media_filepath: nil, short_form_content: true)

      {:ok, _view, html} = live(conn, ~p"/sources")

      assert html =~ ~r/>\s*2 \/ 2\s*</
      assert html =~ "3 found on YouTube"
    end

    test "still show a gap for videos that are waiting or failed", %{conn: conn} do
      source = source_fixture()

      media_item_fixture(source_id: source.id, media_filepath: "/tmp/a.mp4")
      media_item_fixture(source_id: source.id, media_filepath: nil)
      media_item_fixture(source_id: source.id, media_filepath: nil, error_type: "permanent", prevent_download: true)

      {:ok, _view, html} = live(conn, ~p"/sources")

      assert html =~ ~r/>\s*1 \/ 3\s*</
    end
  end

  describe "library strip" do
    test "shows videos found and downloaded of wanted", %{conn: conn} do
      profile = media_profile_fixture(livestream_behaviour: :exclude)
      source = source_fixture(media_profile_id: profile.id)

      media_item_fixture(source_id: source.id, media_filepath: "/tmp/a.mp4")
      media_item_fixture(source_id: source.id, media_filepath: nil, livestream: true)

      {:ok, _view, html} = live(conn, ~p"/sources")

      assert html =~ "Videos found"
      assert html =~ "1 of 1"
    end
  end
end
