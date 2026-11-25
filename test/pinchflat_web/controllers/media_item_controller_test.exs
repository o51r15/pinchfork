defmodule PinchflatWeb.MediaItemControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Downloading.MediaDownloadWorker

  describe "show media" do
    setup [:create_media_item]

    test "renders the page", %{conn: conn, media_item: media_item} do
      html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}") |> html_response(200)

      assert html =~ media_item.title
      assert html =~ "Watch on YouTube"
      assert html =~ "Download now"
    end

    test "renders the page when the media item has no description", %{conn: conn} do
      media_item = media_item_with_attachments(%{description: nil})
      html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}") |> html_response(200)

      assert html =~ media_item.title
      assert html =~ "No description."
    end

    test "a downloaded video has a player, its files and delete actions", %{conn: conn} do
      media_item = media_item_with_attachments()
      html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}") |> html_response(200)

      assert html =~ "Downloaded"
      assert html =~ ~s(id="media-player")
      assert html =~ ~s(id="media-files")
      assert html =~ Path.basename(media_item.media_filepath)
      assert html =~ "Download again"
      assert html =~ "Delete files and don't download again"
    end

    test "a skipped video says why and links to what decides it", %{conn: conn} do
      profile = media_profile_fixture(name: "No Shorts", shorts_behaviour: :exclude)
      source = source_fixture(media_profile_id: profile.id)
      media_item = media_item_fixture(source_id: source.id, short_form_content: true, media_filepath: nil)

      html = conn |> get(~p"/sources/#{source.id}/media/#{media_item}") |> html_response(200)

      assert html =~ "Skipped"
      assert html =~ "It&#39;s a Short, and the No Shorts profile skips Shorts."
      assert html =~ ~s(href="/media_profiles/#{profile.id}/edit")
      refute html =~ ~s(id="media-player")
    end

    test "a video turned off by hand says so", %{conn: conn} do
      media_item =
        media_item_fixture(media_filepath: nil, prevent_download: true, download_prevented_reason: "manual")

      html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}") |> html_response(200)

      assert html =~ "Turned off"
      doc = Floki.parse_document!(html)
      assert [_] = Floki.find(doc, "#media_item_download_auto")
      assert [] = Floki.find(doc, "#media_item_download_auto[checked]")
    end

    test "a failed video shows the error", %{conn: conn} do
      media_item =
        media_item_fixture(
          media_filepath: nil,
          prevent_download: true,
          download_prevented_reason: "permanent_error",
          error_type: "permanent",
          last_error: "Sign in to confirm your age"
        )

      html = conn |> get(~p"/sources/#{media_item.source_id}/media/#{media_item}") |> html_response(200)

      assert html =~ "Failed"
      assert html =~ "Sign in to confirm your age"
    end
  end

  describe "edit media" do
    setup [:create_media_item]

    test "goes to the video page, where the switches are now", %{conn: conn, media_item: media_item} do
      conn = get(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}/edit")

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}/media/#{media_item}"
    end
  end

  describe "update media" do
    setup [:create_media_item]

    test "turning automatic download off records it as the person's choice", %{conn: conn, media_item: media_item} do
      conn =
        patch(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: %{prevent_download: "true"})

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}/media/#{media_item}"
      media_item = Repo.reload!(media_item)
      assert media_item.prevent_download
      assert media_item.download_prevented_reason == "manual"
    end

    test "turning it back on clears the reason and a permanent failure", %{conn: conn} do
      media_item =
        media_item_fixture(
          prevent_download: true,
          download_prevented_reason: "permanent_error",
          error_type: "permanent"
        )

      patch(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: %{prevent_download: "false"})

      media_item = Repo.reload!(media_item)
      refute media_item.prevent_download
      refute media_item.download_prevented_reason
      refute media_item.error_type
    end

    test "sets keep when cleaning up", %{conn: conn, media_item: media_item} do
      patch(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: %{prevent_culling: "true"})

      assert Repo.reload!(media_item).prevent_culling
    end

    test "only changes the two switches", %{conn: conn, media_item: media_item} do
      patch(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item}", media_item: %{title: "New Title"})

      assert Repo.reload!(media_item).title == media_item.title
    end
  end

  describe "delete media" do
    setup do
      media_item = media_item_with_attachments()
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

      %{media_item: media_item}
    end

    test "the media item not is deleted", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      assert Repo.reload!(media_item)
    end

    test "the files are deleted", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      refute File.exists?(media_item.media_filepath)
    end

    test "comes back to the video page", %{conn: conn, media_item: media_item} do
      conn = delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}/media/#{media_item.id}"
    end

    test "doesn't prevent re-download by default", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}")

      media_item = Repo.reload(media_item)

      refute media_item.prevent_download
    end

    test "can optionally prevent re-download", %{conn: conn, media_item: media_item} do
      delete(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}?prevent_download=true")

      media_item = Repo.reload(media_item)

      assert media_item.prevent_download
    end
  end

  describe "force_download" do
    test "enqueues download task", %{conn: conn} do
      media_item = media_item_fixture()

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "doesn't freak out if the task is a duplicate", %{conn: conn} do
      media_item = media_item_fixture()

      MediaDownloadWorker.kickoff_with_task(media_item, %{force: true})

      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "forces a download even if one wouldn't normally run", %{conn: conn} do
      media_item = media_item_fixture(%{media_filepath: nil})

      post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")
      assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id, "force" => true})
    end

    test "redirects to the show page", %{conn: conn} do
      media_item = media_item_fixture()

      conn = post(conn, ~p"/sources/#{media_item.source_id}/media/#{media_item.id}/force_download")

      assert redirected_to(conn) == ~p"/sources/#{media_item.source_id}/media/#{media_item.id}"
    end
  end

  describe "streaming media" do
    test "returns 404 if the media isn't found", %{conn: conn} do
      media_item = media_item_fixture()
      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 404
    end

    test "automatically sets the content type", %{conn: conn} do
      media_item = media_item_with_attachments()
      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert {"content-type", "video/mp4; charset=utf-8"} in conn.resp_headers
    end

    test "sets the content length", %{conn: conn} do
      media_item = media_item_with_attachments()
      filesize = File.stat!(media_item.media_filepath).size

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert {"content-length", to_string(filesize)} in conn.resp_headers
    end
  end

  describe "streaming media when range is valid" do
    setup do
      media_item = media_item_with_attachments()

      %{media_item: media_item}
    end

    test "sets the correct status and headers", %{conn: conn, media_item: media_item} do
      filesize = File.stat!(media_item.media_filepath).size

      conn =
        conn
        |> put_req_header("range", "bytes=0-100")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 206
      assert {"content-range", "bytes 0-100/#{filesize}"} in conn.resp_headers
      assert {"content-length", "101"} in conn.resp_headers
      assert {"content-disposition", "inline; filename=\"#{media_item.title}\""} in conn.resp_headers
    end

    test "streams the specified range", %{conn: conn, media_item: media_item} do
      conn =
        conn
        |> put_req_header("range", "bytes=0-100")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert byte_size(conn.resp_body) == 101
    end

    test "supports range offsets", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      expected = String.slice(contents, 100..200)

      conn =
        conn
        |> put_req_header("range", "bytes=100-200")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == expected
    end

    test "returns as expected if the requested range is larger than the file", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      filesize = File.stat!(media_item.media_filepath).size

      conn =
        conn
        |> put_req_header("range", "bytes=0-#{filesize * 10}")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
      assert {"content-range", "bytes 0-#{filesize - 1}/#{filesize}"} in conn.resp_headers
      assert {"content-length", to_string(filesize)} in conn.resp_headers
    end

    test "supports endless ranges", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn =
        conn
        |> put_req_header("range", "bytes=0-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
    end

    test "supports endless ranges with offsets", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)
      {_, expected} = String.split_at(contents, 100)

      conn =
        conn
        |> put_req_header("range", "bytes=100-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == expected
    end
  end

  describe "streaming media when range is invalid or not present" do
    setup do
      media_item = media_item_with_attachments()

      %{media_item: media_item}
    end

    test "sets the correct status and headers", %{conn: conn, media_item: media_item} do
      filesize = File.stat!(media_item.media_filepath).size

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 200
      assert {"content-length", to_string(filesize)} in conn.resp_headers
      assert {"content-range", "bytes 0-#{filesize - 1}/#{filesize}"} in conn.resp_headers
      assert {"content-disposition", "inline; filename=\"#{media_item.title}\""} in conn.resp_headers
    end

    test "streams the entire file", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn = get(conn, ~p"/media/#{media_item.uuid}/stream")

      assert conn.resp_body == contents
    end

    test "doesn't blow up if the range header is invalid", %{conn: conn, media_item: media_item} do
      contents = File.read!(media_item.media_filepath)

      conn =
        conn
        |> put_req_header("range", "bytes=-")
        |> get(~p"/media/#{media_item.uuid}/stream")

      assert conn.status == 200
      assert conn.resp_body == contents
    end
  end

  defp create_media_item(_) do
    media_item = media_item_fixture()
    %{media_item: media_item}
  end
end
