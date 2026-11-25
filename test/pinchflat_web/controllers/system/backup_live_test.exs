defmodule PinchflatWeb.System.BackupLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings
  alias Pinchflat.Backups.Restore

  defmodule FakeRestorer do
    @moduledoc false
    # Walks the steps like a real restore, then returns whatever the test asked for
    def restore(_path, opts) do
      notify = Keyword.fetch!(opts, :notify)
      Enum.each(Keyword.keys(Restore.steps()), notify)

      Application.get_env(
        :pinchflat,
        :fake_restore_result,
        {:ok, %{safety_backup: "pinchfork-backup-safety.sql.gz"}}
      )
    end
  end

  setup do
    Settings.set(onboarding: false)
    dir = Path.join(System.tmp_dir!(), "pf-backup-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:pinchflat, :backup_directory, dir)
    Application.put_env(:pinchflat, :backup_restorer, FakeRestorer)

    on_exit(fn ->
      Application.delete_env(:pinchflat, :backup_directory)
      Application.delete_env(:pinchflat, :backup_restorer)
      Application.delete_env(:pinchflat, :fake_restore_result)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp dump(version) do
    :zlib.gzip("""
    CREATE TABLE public.media_items (
        id bigint NOT NULL
    );
    COPY public.schema_migrations (version, inserted_at) FROM stdin;
    #{version}\t2026-06-05 21:41:52
    \\.
    """)
  end

  defp backup(dir, name, version \\ 20_250_101_000_000) do
    File.write!(Path.join(dir, name), dump(version))
    name
  end

  describe "the Backup page" do
    test "links to restore each backup and to upload one", %{conn: conn, dir: dir} do
      name = backup(dir, "pinchfork-backup-a.sql.gz")
      html = conn |> get(~p"/system/backup") |> html_response(200)

      assert html =~ ~s(href="/system/backup/#{name}/restore")
      assert html =~ ~s(href="/system/backup/upload")
    end
  end

  describe "restore" do
    test "a backup that isn't there goes back to the Backup page", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/system/backup"}}} =
               live(conn, ~p"/system/backup/pinchfork-backup-gone.sql.gz/restore")
    end

    test "checks the backup, and only enables Restore once RESTORE is typed", %{conn: conn, dir: dir} do
      name = backup(dir, "pinchfork-backup-a.sql.gz")
      {:ok, view, _html} = live(conn, ~p"/system/backup/#{name}/restore")

      assert render_async(view) =~ "Made by an older version of Pinchfork"
      assert has_element?(view, "#restore-form button[disabled]")

      view |> form("#restore-form", confirm: "restore") |> render_change()
      assert has_element?(view, "#restore-form button[disabled]")

      view |> form("#restore-form", confirm: "RESTORE") |> render_change()
      refute has_element?(view, "#restore-form button[disabled]")
    end

    test "won't offer to restore a backup from a newer version", %{conn: conn, dir: dir} do
      name = backup(dir, "pinchfork-backup-new.sql.gz", 99_990_101_000_000)
      {:ok, view, _html} = live(conn, ~p"/system/backup/#{name}/restore")

      assert render_async(view) =~ "Made by a newer version of Pinchfork"
      view |> form("#restore-form", confirm: "RESTORE") |> render_change()
      assert has_element?(view, "#restore-form button[disabled]")
    end

    test "restoring shows it worked and names the safety backup", %{conn: conn, dir: dir} do
      name = backup(dir, "pinchfork-backup-a.sql.gz")
      {:ok, view, _html} = live(conn, ~p"/system/backup/#{name}/restore")
      render_async(view)

      view |> form("#restore-form", confirm: "RESTORE") |> render_submit()
      html = render_async(view)

      assert html =~ "Restored from #{name}"
      assert html =~ "pinchfork-backup-safety.sql.gz"
    end

    test "a failed restore says so and why", %{conn: conn, dir: dir} do
      Application.put_env(:pinchflat, :fake_restore_result, {:error, "The restore failed and was rolled back."})
      name = backup(dir, "pinchfork-backup-a.sql.gz")
      {:ok, view, _html} = live(conn, ~p"/system/backup/#{name}/restore")
      render_async(view)

      view |> form("#restore-form", confirm: "RESTORE") |> render_submit()
      html = render_async(view)

      assert html =~ "The restore didn&#39;t happen"
      assert html =~ "The restore failed and was rolled back."
    end

    test "submitting without RESTORE does nothing", %{conn: conn, dir: dir} do
      name = backup(dir, "pinchfork-backup-a.sql.gz")
      {:ok, view, _html} = live(conn, ~p"/system/backup/#{name}/restore")
      render_async(view)

      render_submit(view, "restore", %{"confirm" => "nope"})
      assert has_element?(view, "#restore-confirm")
      refute has_element?(view, "#restore-progress")
    end
  end

  describe "upload" do
    test "a backup is saved and opened for restoring", %{conn: conn, dir: dir} do
      {:ok, view, _html} = live(conn, ~p"/system/backup/upload")

      upload =
        file_input(view, "#upload-form", :backup, [
          %{name: "my-old-server.sql.gz", content: dump(20_250_101_000_000), type: "application/gzip"}
        ])

      render_upload(upload, "my-old-server.sql.gz")

      assert {:error, {:live_redirect, %{to: to}}} = view |> form("#upload-form") |> render_submit()
      assert to == "/system/backup/my-old-server.sql.gz/restore"
      assert File.exists?(Path.join(dir, "my-old-server.sql.gz"))
    end

    test "something that isn't a backup is refused and not kept", %{conn: conn, dir: dir} do
      {:ok, view, _html} = live(conn, ~p"/system/backup/upload")

      upload =
        file_input(view, "#upload-form", :backup, [
          %{name: "holiday.sql.gz", content: :zlib.gzip("hello"), type: "application/gzip"}
        ])

      render_upload(upload, "holiday.sql.gz")
      html = view |> form("#upload-form") |> render_submit()

      assert html =~ "doesn&#39;t look like a Pinchfork backup"
      assert File.ls!(dir) == []
    end
  end
end
