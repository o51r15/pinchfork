defmodule PinchflatWeb.SystemBackupUpdatesTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    dir = Path.join(System.tmp_dir!(), "pf-backups-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:pinchflat, :backup_directory, dir)

    on_exit(fn ->
      Application.delete_env(:pinchflat, :backup_directory)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "backup page" do
    test "with no backups yet", %{conn: conn} do
      html = conn |> get(~p"/system/backup") |> html_response(200)

      assert html =~ "No backups yet"
      assert html =~ "Restoring a backup"
      refute html =~ ~s(id="backup-summary")
    end

    test "lists backups with a summary and download/delete", %{conn: conn, dir: dir} do
      File.write!(Path.join(dir, "pinchfork-backup-2026-11-25T10-00-00.sql.gz"), String.duplicate("x", 2048))
      html = conn |> get(~p"/system/backup") |> html_response(200)

      assert html =~ ~s(id="backup-summary")
      assert html =~ "1 of 10"
      assert html =~ ~s(href="/system/backup/pinchfork-backup-2026-11-25T10-00-00.sql.gz/download")
      # The restore steps use the newest backup's real name
      assert html =~ "gunzip -c pinchfork-backup-2026-11-25T10-00-00.sql.gz"
    end

    test "warns and disables Back up now when the folder is missing", %{conn: conn, dir: dir} do
      Application.put_env(:pinchflat, :backup_directory, Path.join(dir, "gone"))
      html = conn |> get(~p"/system/backup") |> html_response(200)

      assert html =~ ~s(id="backup-dir-warning")
      assert html =~ "backups can't be made"
      assert html =~ "- /path/to/backups:"
    end

    test "Back up now refuses cleanly when the folder is missing", %{conn: conn, dir: dir} do
      Application.put_env(:pinchflat, :backup_directory, Path.join(dir, "gone"))
      conn = post(conn, ~p"/system/backup")

      assert redirected_to(conn) == ~p"/system/backup"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can't write to"
    end
  end

  describe "updates page" do
    test "shows the versions, how yt-dlp updates, and the steps", %{conn: conn} do
      Settings.set(yt_dlp_version: "2026.11.01")
      html = conn |> get(~p"/system/updates") |> html_response(200)

      assert html =~ "v#{Application.spec(:pinchflat)[:vsn]}"
      assert html =~ "2026.11.01"
      assert html =~ "Updates itself daily"
      assert html =~ "docker compose pull"
      assert html =~ "You don't have a backup yet."
    end

    test "mentions the last backup when there is one", %{conn: conn, dir: dir} do
      File.write!(Path.join(dir, "pinchfork-backup-x.sql.gz"), "x")
      html = conn |> get(~p"/system/updates") |> html_response(200)

      assert html =~ "Your last backup was"
    end
  end
end
