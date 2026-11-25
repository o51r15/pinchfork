defmodule PinchflatWeb.SystemControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  describe "status" do
    test "shows each health check", %{conn: conn} do
      html = conn |> get(~p"/system/status") |> html_response(200)

      for check <- ["Database", "yt-dlp", "PO token server", "Background jobs"] do
        assert html =~ check
      end

      # No bgutil-provider in tests
      assert html =~ "Not reachable"
    end

    test "shows free space where downloads go", %{conn: conn} do
      html = conn |> get(~p"/system/status") |> html_response(200)

      assert html =~ "Disk space"
      assert html =~ Application.get_env(:pinchflat, :media_directory)
    end

    test "shows the library numbers that used to be on Stats", %{conn: conn} do
      source = source_fixture()
      media_item_fixture(source_id: source.id, media_filepath: "/tmp/video.mp4", media_size_bytes: 2_500_000_000)
      media_item_fixture(source_id: source.id, media_filepath: nil)

      html = conn |> get(~p"/system/status") |> html_response(200)

      assert html =~ "Library"
      assert html =~ "2.5 GB"
      assert html =~ ~r/Videos downloaded.*1.*of.*2/s
    end
  end

  describe "stats" do
    test "the old Stats page goes to Status", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/stats")) == ~p"/system/status"
    end
  end

  describe "test_po_token" do
    test "reports the result back on Status", %{conn: conn} do
      conn = post(conn, ~p"/system/test_po_token")

      assert redirected_to(conn) == ~p"/system/status"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "token server"
    end
  end
end
