defmodule Pinchflat.SlowIndexing.IndexPlanTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.SlowIndexing.IndexPlan

  defp source(url, attrs \\ []) do
    profile =
      struct(MediaProfile, Keyword.get(attrs, :profile, shorts_behaviour: :include, livestream_behaviour: :include))

    struct(
      Source,
      Keyword.merge(
        [collection_type: :channel, original_url: url, media_profile: profile, download_cutoff_date: nil],
        Keyword.delete(attrs, :profile)
      )
    )
  end

  describe "urls/1" do
    test "reads every tab of a channel when the profile includes everything" do
      assert IndexPlan.urls(source("https://www.youtube.com/@WWE")) == [
               "https://www.youtube.com/@WWE/videos",
               "https://www.youtube.com/@WWE/shorts",
               "https://www.youtube.com/@WWE/streams"
             ]
    end

    test "leaves out the tabs the profile excludes" do
      src =
        source("https://www.youtube.com/@WWE/", profile: [shorts_behaviour: :exclude, livestream_behaviour: :include])

      assert IndexPlan.urls(src) == ["https://www.youtube.com/@WWE/videos", "https://www.youtube.com/@WWE/streams"]

      src = source("https://youtube.com/@WWE", profile: [shorts_behaviour: :exclude, livestream_behaviour: :exclude])
      assert IndexPlan.urls(src) == ["https://www.youtube.com/@WWE/videos"]
    end

    test "only reads the shorts or live tab when the profile wants only those" do
      src = source("https://www.youtube.com/@WWE", profile: [shorts_behaviour: :only, livestream_behaviour: :exclude])
      assert IndexPlan.urls(src) == ["https://www.youtube.com/@WWE/shorts"]

      src = source("https://www.youtube.com/@WWE", profile: [shorts_behaviour: :include, livestream_behaviour: :only])
      assert IndexPlan.urls(src) == ["https://www.youtube.com/@WWE/streams"]

      src = source("https://www.youtube.com/@WWE", profile: [shorts_behaviour: :only, livestream_behaviour: :only])
      assert IndexPlan.urls(src) == ["https://www.youtube.com/@WWE/shorts", "https://www.youtube.com/@WWE/streams"]
    end

    test "works with /channel/, /c/ and /user/ URLs and other channel pages" do
      src =
        source("https://www.youtube.com/channel/UC123/featured",
          profile: [shorts_behaviour: :exclude, livestream_behaviour: :exclude]
        )

      assert IndexPlan.urls(src) == ["https://www.youtube.com/channel/UC123/videos"]

      src =
        source("https://m.youtube.com/user/bob?x=1",
          profile: [shorts_behaviour: :exclude, livestream_behaviour: :exclude]
        )

      assert IndexPlan.urls(src) == ["https://www.youtube.com/user/bob/videos"]
    end

    test "keeps a URL that already points at one tab" do
      assert IndexPlan.urls(source("https://www.youtube.com/@WWE/videos")) == ["https://www.youtube.com/@WWE/videos"]
    end

    test "keeps playlists and URLs it doesn't understand as they are" do
      url = "https://www.youtube.com/playlist?list=PL123"
      assert IndexPlan.urls(source(url, collection_type: :playlist)) == [url]
      assert IndexPlan.urls(source("https://example.com/@WWE")) == ["https://example.com/@WWE"]
    end
  end

  describe "read_options/1" do
    test "reads a channel's tabs lazily and stops each one at the cutoff date" do
      src = source("https://www.youtube.com/@WWE", download_cutoff_date: ~D[2025-09-25])
      assert IndexPlan.read_options(src) == [:lazy_playlist, break_match_filters: "upload_date>=?20250925"]
    end

    test "has no stop without a cutoff" do
      assert IndexPlan.read_options(source("https://www.youtube.com/@WWE")) == [:lazy_playlist]
    end

    test "does nothing for a playlist" do
      src =
        source("https://www.youtube.com/playlist?list=PL1",
          collection_type: :playlist,
          download_cutoff_date: ~D[2025-09-25]
        )

      assert IndexPlan.read_options(src) == []
    end
  end
end
