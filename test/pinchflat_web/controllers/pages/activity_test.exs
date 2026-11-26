defmodule PinchflatWeb.Pages.ActivityTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures

  alias Pinchflat.Settings
  alias Pinchflat.Pages.HistoryTableLive

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  describe "the Activity page" do
    test "shows every tab", %{conn: conn} do
      html = conn |> get(~p"/activity") |> html_response(200)

      for tab <- ["Running", "Queued", "Retrying", "Failed", "Downloaded"] do
        assert html =~ tab
      end
    end

    test "counts waiting videos on the Queued tab", %{conn: conn} do
      media_item_fixture(media_filepath: nil)
      media_item_fixture(media_filepath: nil)

      assert HistoryTableLive.count_for("pending") == 2
      assert conn |> get(~p"/activity") |> html_response(200) =~ ~r/Queued\s*<span[^>]*>\s*2\s*</
    end

    test "Queued leaves out videos from unmonitored or switched-off sources" do
      unmonitored = Pinchflat.SourcesFixtures.source_fixture(download_media: false)
      switched_off = Pinchflat.SourcesFixtures.source_fixture(enabled: false)
      media_item_fixture(media_filepath: nil, source_id: unmonitored.id)
      media_item_fixture(media_filepath: nil, source_id: switched_off.id)
      media_item_fixture(media_filepath: nil)

      assert HistoryTableLive.count_for("pending") == 1
    end

    test "Retrying leaves out videos from unmonitored sources" do
      unmonitored = Pinchflat.SourcesFixtures.source_fixture(download_media: false)
      media_item_fixture(media_filepath: nil, error_type: "transient", source_id: unmonitored.id)
      media_item_fixture(media_filepath: nil, error_type: "transient")

      assert HistoryTableLive.count_for("retry") == 1
    end
  end

  describe "the tab tables" do
    test "say what an empty tab means", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "failed"})

      assert html =~ "No failed downloads."
    end

    test "Dismiss turns a failed video off and takes it off the list", %{conn: conn} do
      item =
        media_item_fixture(
          media_filepath: nil,
          error_type: "permanent",
          prevent_download: true,
          last_error: "ERROR: Video unavailable"
        )

      {:ok, view, _html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "failed"})

      refute view |> element("#dismiss-#{item.id}") |> render_click() =~ item.title

      item = Pinchflat.Repo.reload(item)
      assert item.prevent_download
      assert item.download_prevented_reason == "manual"
      assert item.error_type == nil
      assert item.last_error =~ "Video unavailable"
      assert HistoryTableLive.count_for("failed") == 0
    end

    test "list waiting videos with their source", %{conn: conn} do
      media_item = media_item_fixture(media_filepath: nil)
      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "pending"})

      assert html =~ media_item.title
      assert html =~ "Showing"
    end
  end
end
