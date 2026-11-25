defmodule PinchflatWeb.SourceControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  describe "index" do
    # Most of the tests are in `index_table_list_test.exs`
    test "returns 200", %{conn: conn} do
      conn = get(conn, ~p"/sources")
      assert html_response(conn, 200) =~ "Sources"
    end
  end

  describe "show source" do
    test "explains why videos were skipped", %{conn: conn} do
      profile = media_profile_fixture(name: "TV Shows", shorts_behaviour: :exclude, livestream_behaviour: :exclude)
      source = source_fixture(media_profile_id: profile.id, download_cutoff_date: ~D[2020-01-01])

      media_item_fixture(source_id: source.id, media_filepath: nil, short_form_content: true)
      media_item_fixture(source_id: source.id, media_filepath: nil, livestream: true)
      media_item_fixture(source_id: source.id, media_filepath: nil, livestream: true)
      media_item_fixture(source_id: source.id, media_filepath: nil, uploaded_at: ~U[2019-06-01 00:00:00Z])

      html = conn |> get(~p"/sources/#{source}") |> html_response(200)

      assert html =~ "1 Short, 2 livestreams"
      assert html =~ "TV Shows profile"
      assert html =~ "1 before the cutoff date"
      assert html =~ "source settings"
    end

    test "says nothing about reasons when nothing was skipped", %{conn: conn} do
      source = source_fixture()
      html = conn |> get(~p"/sources/#{source}") |> html_response(200)

      assert html =~ "Left out by download rules"
    end
  end

  describe "delete source in all cases" do
    setup [:create_source]

    test "redirects to the sources page", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}")
      assert redirected_to(conn) == ~p"/sources"
    end

    test "returns to a media profile page when asked", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}?return_to=/media_profiles/#{source.media_profile_id}")
      assert redirected_to(conn) == "/media_profiles/#{source.media_profile_id}"
    end

    test "ignores return_to values that aren't profile pages", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}?return_to=https://evil.example/media_profiles/1")
      assert redirected_to(conn) == ~p"/sources"
    end

    test "sets marked_for_deletion_at", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")
      assert Repo.reload!(source).marked_for_deletion_at
    end
  end

  describe "delete source when just deleting the records" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")

      assert [%{args: %{"delete_files" => false}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "delete source when deleting the records and files" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}?delete_files=true")

      assert [%{args: %{"delete_files" => true}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "force_download_pending" do
    test "enqueues pending download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_redownload" do
    test "enqueues re-download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(source_id: source.id, media_downloaded_at: now())

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_index" do
    test "forces an index", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "forces an index even if one wouldn't normally run", %{conn: conn} do
      source = source_fixture(index_frequency_minutes: 0, last_indexed_at: DateTime.utc_now())

      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [job] = all_enqueued(worker: MediaCollectionIndexingWorker)
      assert job.args == %{"id" => source.id, "force" => true}
    end

    test "deletes pending indexing tasks", %{conn: conn} do
      source = source_fixture()
      {:ok, task} = MediaCollectionIndexingWorker.kickoff_with_task(source)
      job = Repo.preload(task, :job).job

      assert job.state == "available"
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert Repo.reload!(job).state == "cancelled"
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_index")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_metadata_refresh" do
    test "forces a metadata refresh", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: SourceMetadataStorageWorker)
      post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert [_] = all_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "sync_files_on_disk" do
    test "forces a file sync", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: FileSyncingWorker)
      post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert [_] = all_enqueued(worker: FileSyncingWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  defp create_source(_) do
    source = source_fixture()
    media_item = media_item_with_attachments(%{source_id: source.id})

    %{source: source, media_item: media_item}
  end
end
