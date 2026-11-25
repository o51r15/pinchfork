defmodule Pinchflat.Backups.Restore do
  @moduledoc """
  Restores the database from a backup made by `Pinchflat.Backups`, while Pinchfork runs.

  In order:

    1. Check the file: a complete gzip of a Pinchfork dump, made by this version of Pinchfork
       or an older one (its newest migration is one this app knows).
    2. Unpack it to a temporary file. psql only ever reads a complete file, because in
       single-transaction mode it commits whatever it has when its input ends.
    3. Make a safety backup of the current database.
    4. Pause background jobs and wait for running ones to finish.
    5. In ONE transaction: drop and recreate the public schema, then load the dump. Postgres
       DDL is transactional, so if anything fails the database is exactly as it was.
    6. Run any migrations newer than the backup.
    7. Restart Pinchfork's runtime (`:init.restart/0`; the container keeps running). Reloading
       recreates tables and types with new internal ids, and Postgrex caches type ids for the
       life of the runtime, so without a restart Oban keeps failing with "cache lookup failed
       for type" (seen on the test stack: once a minute until restarted). Jobs stay paused
       until then, so nothing runs on a stale connection.

  If the load fails nothing changed: jobs resume and there's no restart.
  Only one restore runs at a time.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Backups

  @lock_resource :pinchfork_restore
  @wait_for_jobs_ms 30_000

  @steps [
    checking: "Checking the backup",
    unpacking: "Unpacking it",
    safety_backup: "Backing up the current database",
    pausing: "Pausing background jobs",
    restoring: "Restoring",
    updating: "Updating the database for this version",
    restarting: "Restarting Pinchfork"
  ]

  @restart_delay_ms 3_000

  @doc "The steps of a restore, in order, as [{step, label}]."
  def steps, do: @steps

  @doc """
  Reads a backup without changing anything and says what's in it.

  Returns {:ok, %{latest_migration: integer(), app_migration: integer(), newer_than_app: boolean()}}
          | {:error, String.t()}
  """
  def inspect_backup(path) do
    initial = %{in_migrations: false, versions: [], media_items: false}

    result =
      path
      |> File.stream!([:compressed])
      |> Enum.reduce(initial, &scan_line/2)

    if result.versions == [] or not result.media_items do
      {:error, "This doesn't look like a Pinchfork backup."}
    else
      latest = Enum.max(result.versions)
      app = latest_app_migration()
      {:ok, %{latest_migration: latest, app_migration: app, newer_than_app: latest > app}}
    end
  rescue
    _ -> {:error, "This file can't be read. It may be damaged or not a .sql.gz backup."}
  end

  defp scan_line("COPY public.schema_migrations " <> _, acc), do: %{acc | in_migrations: true}
  defp scan_line("\\." <> _, %{in_migrations: true} = acc), do: %{acc | in_migrations: false}

  defp scan_line(line, %{in_migrations: true} = acc) do
    case Integer.parse(line) do
      {version, _} -> %{acc | versions: [version | acc.versions]}
      :error -> acc
    end
  end

  defp scan_line("CREATE TABLE public.media_items " <> _, acc), do: %{acc | media_items: true}
  defp scan_line(_line, acc), do: acc

  @doc """
  The newest migration this version of Pinchfork ships with.
  """
  def latest_app_migration do
    Application.app_dir(:pinchflat, "priv/repo/migrations")
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      case Integer.parse(name) do
        {version, "_" <> _} -> [version]
        _ -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Restores the backup at `path`. `opts`:

    * `:notify` - called with each step atom as it starts (see `steps/0`)
    * `:jobs` - `{pause_fun, resume_fun, running_count_fun}`, for tests
    * `:runner` - `fn sql_paths, db_config -> {output, exit_status} end` that runs psql, for tests
    * `:safety_backup` - `fn -> {:ok, filename} | {:error, reason} end`, for tests
    * `:finish` - `fn -> :ok | {:error, message} end` run after loading (migrations), for tests
    * `:restart` - `fn -> any end` that restarts Pinchfork after a restore, for tests
    * `:wait_ms` - how long to wait for running jobs (default 30 seconds)

  Returns
    * {:ok, %{safety_backup: filename, warning: nil | message}} - restored; Pinchfork restarts
      in a few seconds. `warning` is set when something after loading failed (migrations).
    * {:error, message} - nothing in the database changed
  """
  def restore(path, opts \\ []) do
    # :global locks only exclude *different* requesters, so the requester must be this process
    lock = {@lock_resource, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        do_restore(path, opts)
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, "Another restore is already running."}
    end
  end

  defp do_restore(path, opts) do
    notify = Keyword.get(opts, :notify, fn _ -> :ok end)
    {pause, resume, running} = Keyword.get(opts, :jobs, {&pause_jobs/0, &resume_jobs/0, &running_jobs/0})
    runner = Keyword.get(opts, :runner, &run_psql/2)
    safety_backup = Keyword.get(opts, :safety_backup, &Backups.create_backup/0)
    finish = Keyword.get(opts, :finish, &migrate/0)
    restart = Keyword.get(opts, :restart, &schedule_restart/0)
    wait_ms = Keyword.get(opts, :wait_ms, @wait_for_jobs_ms)

    tmp_dir = Path.join(System.tmp_dir!(), "pinchfork-restore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    try do
      with :ok <- notify_step(notify, :checking),
           {:ok, info} <- inspect_backup(path),
           :ok <- check_version(info),
           :ok <- notify_step(notify, :unpacking),
           {:ok, sql_paths} <- unpack(path, tmp_dir),
           {:ok, db} <- Backups.parse_database_url(),
           :ok <- notify_step(notify, :safety_backup),
           {:ok, safety} <- safety_backup(safety_backup) do
        notify.(:pausing)
        pause.()

        case wait_and_load(running, wait_ms, notify, runner, sql_paths, db) do
          :ok ->
            # The database is replaced from here on. Jobs stay paused: the restart starts them
            # again on fresh connections.
            notify.(:updating)
            warning = finished(finish, safety)
            notify.(:restarting)
            Logger.info("Restored the database from #{Path.basename(path)} (safety backup: #{safety}). Restarting.")
            restart.()
            {:ok, %{safety_backup: safety, warning: warning}}

          {:error, _} = error ->
            resume.()
            error
        end
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp notify_step(notify, step) do
    notify.(step)
    :ok
  end

  defp check_version(%{newer_than_app: true}),
    do: {:error, "This backup was made by a newer version of Pinchfork. Update Pinchfork first, then restore it."}

  defp check_version(_info), do: :ok

  # The schema reset goes in its own file in front of the dump; psql runs both in one transaction
  defp unpack(path, tmp_dir) do
    reset = Path.join(tmp_dir, "00-reset.sql")
    dump = Path.join(tmp_dir, "01-dump.sql")
    File.write!(reset, "DROP SCHEMA public CASCADE;\nCREATE SCHEMA public;\n")

    case System.cmd("sh", ["-c", ~S(gunzip -c "$1" > "$2"), "sh", path, dump], stderr_to_stdout: true) do
      {_, 0} -> {:ok, [reset, dump]}
      {output, _} -> {:error, "The backup couldn't be unpacked: #{String.trim(output)}"}
    end
  end

  defp safety_backup(fun) do
    case fun.() do
      {:ok, filename} -> {:ok, filename}
      {:error, reason} -> {:error, "The safety backup failed, so nothing was restored: #{reason}"}
    end
  end

  defp wait_for_jobs(running, wait_ms, waited \\ 0) do
    cond do
      running.() == 0 ->
        :ok

      waited >= wait_ms ->
        {:error,
         "Downloads or other jobs are still running. Nothing was changed; try again when they've finished (Activity shows them)."}

      true ->
        Process.sleep(1_000)
        wait_for_jobs(running, wait_ms, waited + 1_000)
    end
  end

  # Anything that raises before the load finishes leaves the database untouched, so jobs resume
  defp wait_and_load(running, wait_ms, notify, runner, sql_paths, db) do
    with :ok <- wait_for_jobs(running, wait_ms),
         :ok <- notify_step(notify, :restoring) do
      load(runner, sql_paths, db)
    end
  rescue
    e -> {:error, "The restore stopped before changing anything: #{Exception.message(e)}"}
  end

  defp finished(finish, safety) do
    case finish.() do
      :ok -> nil
      {:error, message} -> "#{message} The backup was restored. To go back, restore #{safety}."
    end
  end

  defp load(runner, sql_paths, db) do
    case runner.(sql_paths, db) do
      {_output, 0} ->
        :ok

      {output, _} ->
        Logger.error("Restore failed, rolled back: #{output}")

        {:error, "The restore failed and was rolled back, so nothing changed. psql said: #{psql_error(output)}"}
    end
  end

  # The ERROR line and the context psql prints with it, without the "psql:/tmp/...:123:" prefix
  defp psql_error(output) do
    lines = String.split(output, "\n", trim: true)

    case Enum.drop_while(lines, &(not String.contains?(&1, "ERROR:"))) do
      [] ->
        output |> String.trim() |> String.slice(0, 500)

      [first | rest] ->
        detail = Enum.take_while(rest, &String.match?(&1, ~r/^(LINE|DETAIL|HINT|\s)/))

        [String.replace(first, ~r/^psql:[^:]+:\d+:\s*/, "") | detail]
        |> Enum.join("\n")
        |> String.slice(0, 500)
    end
  end

  defp run_psql(sql_paths, db) do
    # Query results (the dump's setval rows) go nowhere; errors still come back on stderr
    args =
      ["-X", "-q", "-o", "/dev/null", "-v", "ON_ERROR_STOP=1", "--single-transaction"] ++
        ["-h", db.host, "-p", to_string(db.port), "-U", db.user, "-d", db.db, "--no-password"] ++
        Enum.flat_map(sql_paths, &["-f", &1])

    # lock_timeout covers the schema drop (the dump sets its own values after that); warning
    # level hides the "drop cascades to ..." notices
    System.cmd("psql", args,
      env: [{"PGPASSWORD", db.pass}, {"PGOPTIONS", "-c lock_timeout=30s -c client_min_messages=warning"}],
      stderr_to_stdout: true
    )
  end

  # Brings an older backup up to this version
  defp migrate do
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    :ok
  rescue
    e -> {:error, "Updating the database for this version failed: #{Exception.message(e)}."}
  end

  # A few seconds' grace so the page can move to the "restarting" screen first. Unlinked, so it
  # outlives whatever asked for it.
  defp schedule_restart do
    spawn(fn ->
      Process.sleep(@restart_delay_ms)
      :init.restart()
    end)
  end

  defp pause_jobs, do: Oban.pause_all_queues(Oban)
  defp resume_jobs, do: Oban.resume_all_queues(Oban)

  # oban_jobs.state is a Postgres enum, so compare it as text
  defp running_jobs do
    Repo.aggregate(from(j in Oban.Job, where: fragment("?::text", j.state) == "executing"), :count)
  end
end
