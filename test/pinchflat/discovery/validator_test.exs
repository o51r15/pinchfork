defmodule Pinchflat.Discovery.ValidatorTest do
  use Pinchflat.DataCase

  alias Pinchflat.Discovery.Validator

  @thumbs [
    %{"url" => "https://yt3.googleusercontent.com/a=s900-c-k-c0x00ffffff-no-rj", "width" => 900, "height" => 900},
    %{"url" => "https://yt3.googleusercontent.com/a=s0", "id" => "avatar_uncropped"}
  ]

  defp validate(output) do
    expect(YtDlpRunnerMock, :run, fn _url, :discovery_enrich, _opts, template, _addl ->
      assert template =~ "playlist:"
      {:ok, output}
    end)

    Validator.validate_and_enrich([%{identifier: "@someone", identifier_type: :handle}])
  end

  test "a plain channel: picture and the newest upload date" do
    line = Jason.encode!(%{channel_id: "UC1", channel: "One", "entries.0.upload_date": "20240301", thumbnails: @thumbs})

    assert [found] = validate(line)
    assert found.channel_id == "UC1"
    assert found.thumbnail_url == "https://yt3.googleusercontent.com/a=s176-c-k-c0x00ffffff-no-rj"
    assert found.last_upload_at == ~U[2024-03-01 00:00:00Z]
    assert found.video_count == nil
  end

  test "a channel with tabs prints two lines; they're merged" do
    videos_tab = Jason.encode!(%{channel_id: "UC2", channel: "Two", "entries.0.upload_date": "20261125"})
    channel = Jason.encode!(%{channel_id: "UC2", channel: "Two", channel_follower_count: 5, thumbnails: @thumbs})

    assert [found] = validate(videos_tab <> "\n" <> channel <> "\n")
    assert found.last_upload_at == ~U[2026-11-25 00:00:00Z]
    assert found.thumbnail_url =~ "=s176-"
    assert found.subscriber_count == 5
  end

  test "keeps the channel's description, trimmed; blank becomes nil" do
    line = Jason.encode!(%{channel_id: "UC4", channel: "Four", description: "  Lifting and coaching.\n"})
    assert [found] = validate(line)
    assert found.description == "Lifting and coaching."

    assert [found] = validate(Jason.encode!(%{channel_id: "UC5", channel: "Five", description: "  "}))
    assert found.description == nil
  end

  test "no picture is fine" do
    assert [found] = validate(Jason.encode!(%{channel_id: "UC3", channel: "Three"}))
    assert found.thumbnail_url == nil
  end

  test "output that isn't JSON is skipped" do
    assert [] = validate("WARNING: something")
  end
end
