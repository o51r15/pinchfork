defmodule Pinchflat.Backups.RestoreTest do
  use ExUnit.Case, async: false

  alias Pinchflat.Backups.Restore

  setup do
    dir = Path.join(System.tmp_dir!(), "pf-restore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old_url = System.get_env("DATABASE_URL")
    System.put_env("DATABASE_URL", "ecto://pinchflat:secret@db.example:5433/pinchflat")

    on_exit(fn ->
      File.rm_rf!(dir)
      if old_url, do: System.put_env("DATABASE_URL", old_url), else: System.delete_env("DATABASE_URL")
    end)

    %{dir: dir}
  end

  defp dump(version) do
    """
    SET statement_timeout = 0;
    CREATE TABLE public.media_items (
        id bigint NOT NULL
    );
    COPY public.schema_migrations (version, inserted_at) FROM stdin;
    20240122030944\t2026-06-05 21:41:52
    #{version}\t2026-06-05 21:41:52
    \\.
    """
  end

  defp write_gz(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, :zlib.gzip(contents))
    path
  end

  # Every piece reports to the test process, so the order can be checked
  defp fakes(test_pid, overrides \\ []) do
    [
      notify: fn step -> send(test_pid, {:step, step}) end,
      jobs:
        Keyword.get(
          overrides,
          :jobs,
          {fn -> send(test_pid, :paused) end, fn -> send(test_pid, :resumed) end, fn -> 0 end}
        ),
      runner:
        Keyword.get(overrides, :runner, fn paths, db ->
          send(test_pid, {:ran, Enum.map(paths, &File.read!/1), db})
          {"", 0}
        end),
      safety_backup:
        Keyword.get(overrides, :safety_backup, fn ->
          send(test_pid, :safety_backup)
          {:ok, "pinchfork-backup-safety.sql.gz"}
        end),
      finish:
        Keyword.get(overrides, :finish, fn ->
          send(test_pid, :finished)
          :ok
        end),
      restart: fn -> send(test_pid, :restarted) end,
      wait_ms: 0
    ]
  end

  defp messages(acc \\ []) do
    receive do
      message -> messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "inspect_backup/1" do
    test "reads the newest migration in a backup from this or an older version", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", dump(20_250_101_000_000))

      assert {:ok, %{latest_migration: 20_250_101_000_000, newer_than_app: false, app_migration: app}} =
               Restore.inspect_backup(path)

      assert app >= 20_250_101_000_000
    end

    test "flags a backup from a newer version", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", dump(99_990_101_000_000))
      assert {:ok, %{newer_than_app: true}} = Restore.inspect_backup(path)
    end

    test "refuses something that isn't a Pinchfork dump", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", "CREATE TABLE public.other (id int);\n")
      assert {:error, "This doesn't look like a Pinchfork backup."} = Restore.inspect_backup(path)
    end

    test "refuses a damaged file", %{dir: dir} do
      gz = :zlib.gzip(dump(20_250_101_000_000) <> String.duplicate("filler line\n", 5_000))
      path = Path.join(dir, "cut.sql.gz")
      File.write!(path, binary_part(gz, 0, div(byte_size(gz), 2)))

      assert {:error, _} = Restore.inspect_backup(path)
    end
  end

  describe "restore/2" do
    test "runs the steps in order and loads the reset then the whole dump", %{dir: dir} do
      contents = dump(20_250_101_000_000)
      path = write_gz(dir, "a.sql.gz", contents)

      assert {:ok, %{safety_backup: "pinchfork-backup-safety.sql.gz", warning: nil}} =
               Restore.restore(path, fakes(self()))

      received = messages()
      assert Enum.filter(received, &match?({:step, _}, &1)) == Enum.map(Keyword.keys(Restore.steps()), &{:step, &1})

      [{:ran, [reset, loaded], db}] = Enum.filter(received, &match?({:ran, _, _}, &1))
      assert reset =~ "DROP SCHEMA public CASCADE;"
      assert reset =~ "CREATE SCHEMA public;"
      assert loaded == contents
      assert %{host: "db.example", port: 5433, user: "pinchflat", db: "pinchflat"} = db

      # Safety backup before pausing, pausing before loading, then a restart instead of resuming:
      # jobs must not run on connections that still know the old tables
      order = Enum.reject(received, &match?({:step, _}, &1)) |> Enum.map(&if(is_tuple(&1), do: elem(&1, 0), else: &1))
      assert order == [:safety_backup, :paused, :ran, :finished, :restarted]
    end

    test "a failed load says nothing changed and still resumes jobs", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", dump(20_250_101_000_000))
      opts = fakes(self(), runner: fn _, _ -> {"ERROR: syntax error", 3} end)

      assert {:error, message} = Restore.restore(path, opts)
      assert message =~ "rolled back"
      assert message =~ "syntax error"
      assert_received :resumed
      refute_received :finished
      refute_received :restarted
    end

    test "won't restore a backup from a newer version", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", dump(99_990_101_000_000))

      assert {:error, message} = Restore.restore(path, fakes(self()))
      assert message =~ "newer version"
      refute_received :safety_backup
      refute_received :paused
    end

    test "stops before touching anything when the safety backup fails", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", dump(20_250_101_000_000))
      opts = fakes(self(), safety_backup: fn -> {:error, "disk full"} end)

      assert {:error, message} = Restore.restore(path, opts)
      assert message =~ "safety backup failed"
      refute_received :paused
      refute_received {:ran, _, _}
    end

    test "gives up when jobs keep running, without loading anything", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", dump(20_250_101_000_000))
      test_pid = self()
      jobs = {fn -> send(test_pid, :paused) end, fn -> send(test_pid, :resumed) end, fn -> 2 end}

      assert {:error, message} = Restore.restore(path, fakes(test_pid, jobs: jobs))
      assert message =~ "still running"
      assert_received :resumed
      refute_received {:ran, _, _}
    end

    test "when finishing fails it's still restored, with a warning saying how to go back", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", dump(20_250_101_000_000))
      opts = fakes(self(), finish: fn -> {:error, "Updating the database for this version failed: boom."} end)

      assert {:ok, %{warning: warning}} = Restore.restore(path, opts)
      assert warning =~ "boom."
      assert warning =~ "The backup was restored. To go back, restore pinchfork-backup-safety.sql.gz."
      assert_received :restarted
      refute_received :resumed
    end

    test "only one restore at a time", %{dir: dir} do
      path = write_gz(dir, "a.sql.gz", dump(20_250_101_000_000))
      test_pid = self()
      lock = {:pinchfork_restore, self()}
      true = :global.set_lock(lock, [node()], 0)

      try do
        task = Task.async(fn -> Restore.restore(path, fakes(test_pid)) end)
        assert {:error, "Another restore is already running."} = Task.await(task)
      after
        :global.del_lock(lock, [node()])
      end
    end
  end
end
