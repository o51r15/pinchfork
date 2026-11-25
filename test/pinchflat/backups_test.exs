defmodule Pinchflat.BackupsTest do
  use ExUnit.Case, async: false

  alias Pinchflat.Backups

  setup do
    dir = Path.join(System.tmp_dir!(), "pf-backups-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:pinchflat, :backup_directory, dir)

    on_exit(fn ->
      Application.delete_env(:pinchflat, :backup_directory)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "directory_status/1" do
    test "is :ok for a folder that exists", %{dir: dir} do
      assert Backups.directory_status(dir) == :ok
    end

    test "is :missing when there's no folder", %{dir: dir} do
      assert Backups.directory_status(Path.join(dir, "nope")) == :missing
    end

    test "is :missing for a file rather than a folder", %{dir: dir} do
      file = Path.join(dir, "file")
      File.write!(file, "")

      assert Backups.directory_status(file) == :missing
    end
  end

  describe "mounted?/2" do
    test "finds the folder as a mount point", %{dir: dir} do
      mountinfo = Path.join(dir, "mountinfo")

      File.write!(mountinfo, """
      22 1 0:21 / / rw,relatime - overlay overlay rw
      310 22 8:1 /srv/backups /backups rw,relatime - ext4 /dev/sda1 rw
      """)

      assert Backups.mounted?("/backups", mountinfo)
      refute Backups.mounted?("/downloads", mountinfo)
    end

    test "can't tell without mountinfo", %{dir: dir} do
      assert Backups.mounted?("/backups", Path.join(dir, "missing")) == nil
    end
  end

  describe "list_backups/0" do
    test "lists .sql.gz files newest first and ignores everything else", %{dir: dir} do
      File.write!(Path.join(dir, "pinchfork-backup-old.sql.gz"), "a")
      File.touch!(Path.join(dir, "pinchfork-backup-old.sql.gz"), {{2024, 1, 1}, {0, 0, 0}})
      File.write!(Path.join(dir, "pinchfork-backup-new.sql.gz"), "bb")
      File.write!(Path.join(dir, "notes.txt"), "x")

      assert [%{filename: "pinchfork-backup-new.sql.gz", size_bytes: 2}, %{filename: "pinchfork-backup-old.sql.gz"}] =
               Backups.list_backups()
    end
  end

  describe "backup_path/1 and delete_backup/1" do
    test "refuse paths outside the folder", %{dir: dir} do
      File.write!(Path.join(dir, "pinchfork-backup-a.sql.gz"), "a")

      assert Backups.backup_path("../../etc/passwd") == nil
      assert Backups.backup_path("pinchfork-backup-a.sql.gz") == Path.join(dir, "pinchfork-backup-a.sql.gz")
      assert {:error, :not_found} = Backups.delete_backup("../pinchfork-backup-a.sql.gz.txt")
      assert :ok = Backups.delete_backup("pinchfork-backup-a.sql.gz")
      assert Backups.list_backups() == []
    end
  end
end
