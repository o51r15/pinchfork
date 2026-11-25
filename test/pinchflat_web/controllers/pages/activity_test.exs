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
  end

  describe "the tab tables" do
    test "say what an empty tab means", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "failed"})

      assert html =~ "No failed downloads."
    end

    test "list waiting videos with their source", %{conn: conn} do
      media_item = media_item_fixture(media_filepath: nil)
      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "pending"})

      assert html =~ media_item.title
      assert html =~ "Showing"
    end
  end
end
