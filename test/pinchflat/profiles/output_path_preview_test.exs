defmodule Pinchflat.Profiles.OutputPathPreviewTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Profiles.Presets
  alias Pinchflat.Profiles.OutputPathPreview

  defp template(key), do: Presets.get(key).attrs.output_path_template

  describe "build/3" do
    test "fills the default template" do
      assert {:ok, path} = OutputPathPreview.build(template("default"), OutputPathPreview.sample(), "mp4")

      assert path ==
               "/Example Channel/2024-03-09 How to Build a Bookshelf/How to Build a Bookshelf [aBcD123xYz0].mp4"
    end

    test "fills the TV seasons template" do
      assert {:ok, path} = OutputPathPreview.build(template("media_center"), OutputPathPreview.sample(), "mkv")
      assert path == "/shows/Example Channel/Season 2024/s2024e030900 - How to Build a Bookshelf.mkv"
    end

    test "uses the uploader for the artist and marks an unknown extension" do
      assert {:ok, path} = OutputPathPreview.build(template("audio"), OutputPathPreview.sample(), nil)
      assert path == "/music/Example Channel/How to Build a Bookshelf.‹ext›"
    end

    test "marks fields only yt-dlp knows, and handles yt-dlp syntax" do
      sample = OutputPathPreview.sample()

      assert {:ok, "/‹view_count›/How to Build a Bookshelf.mp4"} =
               OutputPathPreview.build("/{{ view_count }}/{{ title }}.{{ ext }}", sample, "mp4")

      assert {:ok, "/12:34 - 24.mp4"} =
               OutputPathPreview.build("/%(duration_string)s - %(upload_date>%y)s.%(ext)s", sample, "mp4")
    end

    test "an empty template has no preview" do
      assert :error = OutputPathPreview.build("", OutputPathPreview.sample(), "mp4")
      assert :error = OutputPathPreview.build(nil, OutputPathPreview.sample(), "mp4")
    end
  end

  describe "extension/2" do
    test "defaults per resolution" do
      assert OutputPathPreview.extension("1080p", "") == "mp4"
      assert OutputPathPreview.extension("audio", nil) == nil
      assert OutputPathPreview.extension("audio", "mp3") == "mp3"
    end
  end
end
