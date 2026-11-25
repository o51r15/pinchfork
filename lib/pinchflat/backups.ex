defmodule Pinchflat.Backups do
  @moduledoc """
  Handles database backup creation, listing, and deletion.

  Backups are stored as gzipped pg_dump files in /backups, which is expected
  to be a mounted host volume. Backup files are named:
    pinchfork-backup-YYYY-MM-DDTHH-MM-SS.sql.gz

  NOTE: backup creation is currently synchronous. For large databases this may
  take 30-60+ seconds. Future: migrate to an Oban job for async execution.
  """

  require Logger

  @max_backups 10

  # Configurable so tests can point it somewhere temporary
  def backup_dir, do: Application.get_env(:pinchflat, :backup_directory, "/backups")
  def max_backups, do: @max_backups

  @doc """
  Whether backups can be written: the folder exists and is writable.

  Returns :ok | :missing | :read_only
  """
  def directory_status(dir \\ backup_dir()) do
    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:read_write, :write] -> :ok
      {:ok, %File.Stat{type: :directory}} -> :read_only
      _ -> :missing
    end
  end

  @doc """
  Whether the folder is its own mount (a volume from the host) rather than part of the
  container's filesystem, where backups would be lost when the container is recreated.
  Reads /proc/self/mountinfo, so it only knows on Linux.

  Returns true | false | nil (can't tell)
  """
  def mounted?(dir \\ backup_dir(), mountinfo_path \\ "/proc/self/mountinfo") do
    case File.read(mountinfo_path) do
      # The 5th field of each line is the mount point
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line -> Enum.at(String.split(line, " "), 4) == dir end)

      _ ->
        nil
    end
  end

  @doc """
  Returns a list of existing backups sorted newest first.
  Each entry: %{filename, filepath, size_bytes, created_at}
  """
  def list_backups do
    case File.ls(backup_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".sql.gz"))
        |> Enum.map(&build_backup_entry/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

      {:error, reason} ->
        Logger.warning("Could not list backups directory: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Creates a new backup of the Postgres database.
  Parses DATABASE_URL from the environment, runs pg_dump, gzips the output.
  Enforces retention by deleting oldest backups over the limit.

  Returns {:ok, filename} | {:error, reason}
  """
  def create_backup do
    with {:ok, db_config} <- parse_database_url(),
         {:ok, filename} <- run_pg_dump(db_config) do
      enforce_retention()
      {:ok, filename}
    end
  end

  @doc """
  Deletes a backup by filename. Sanitizes the filename to prevent path traversal.

  Returns :ok | {:error, reason}
  """
  def delete_backup(filename) do
    safe_name = Path.basename(filename)
    filepath = Path.join(backup_dir(), safe_name)

    if String.ends_with?(safe_name, ".sql.gz") && File.exists?(filepath) do
      File.rm(filepath)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns the full path for a backup filename. Sanitizes to prevent path traversal.
  Returns nil if the file doesn't exist or isn't a valid backup file.
  """
  def backup_path(filename) do
    safe_name = Path.basename(filename)
    filepath = Path.join(backup_dir(), safe_name)

    if String.ends_with?(safe_name, ".sql.gz") && File.exists?(filepath) do
      filepath
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_backup_entry(filename) do
    filepath = Path.join(backup_dir(), filename)

    case File.stat(filepath) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        created_at =
          mtime
          |> NaiveDateTime.from_erl!()
          |> DateTime.from_naive!("Etc/UTC")

        %{filename: filename, filepath: filepath, size_bytes: size, created_at: created_at}

      {:error, _} ->
        nil
    end
  end

  @doc false
  # Also used by Backups.Restore
  def parse_database_url do
    url = System.get_env("DATABASE_URL", "")

    if url == "" do
      {:error, "DATABASE_URL is not set"}
    else
      # Convert ecto:// to a standard URI for parsing
      uri = URI.parse(String.replace(url, ~r/^ecto:\/\//, "postgres://"))
      userinfo = uri.userinfo || ":"
      [user | rest] = String.split(userinfo, ":")
      pass = Enum.join(rest, ":")

      {:ok,
       %{
         host: uri.host || "localhost",
         port: uri.port || 5432,
         user: user,
         pass: pass,
         db: String.trim_leading(uri.path || "/pinchflat", "/")
       }}
    end
  end

  defp run_pg_dump(%{host: host, port: port, user: user, pass: pass, db: db}) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H-%M-%S")
    sql_filename = "pinchfork-backup-#{timestamp}.sql"
    gz_filename = "#{sql_filename}.gz"
    sql_path = Path.join(backup_dir(), sql_filename)
    _gz_path = Path.join(backup_dir(), gz_filename)

    dump_args = [
      "-h",
      host,
      "-p",
      to_string(port),
      "-U",
      user,
      "-d",
      db,
      "--no-password",
      "--format=plain",
      "--file=#{sql_path}"
    ]

    case System.cmd("pg_dump", dump_args,
           env: [{"PGPASSWORD", pass}],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        # Compress the dump
        case System.cmd("gzip", [sql_path], stderr_to_stdout: true) do
          {_out, 0} ->
            Logger.info("Backup created: #{gz_filename}")
            {:ok, gz_filename}

          {output, exit_code} ->
            # Clean up uncompressed file on gzip failure
            File.rm(sql_path)
            Logger.error("gzip failed (exit #{exit_code}): #{output}")
            {:error, "Compression failed: #{output}"}
        end

      {output, exit_code} ->
        File.rm(sql_path)
        Logger.error("pg_dump failed (exit #{exit_code}): #{output}")
        {:error, "pg_dump failed (exit #{exit_code}): #{String.slice(output, 0, 500)}"}
    end
  end

  defp enforce_retention do
    backups = list_backups()

    if length(backups) > @max_backups do
      backups
      |> Enum.drop(@max_backups)
      |> Enum.each(fn backup ->
        Logger.info("Retention: deleting old backup #{backup.filename}")
        File.rm(backup.filepath)
      end)
    end
  end
end
