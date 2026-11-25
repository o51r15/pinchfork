defmodule PinchflatWeb.System.SystemController do
  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Backups
  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.PoTokenServer

  def status(conn, _params) do
    about = %{
      pinchfork_version: Application.spec(:pinchflat)[:vsn] |> to_string(),
      pinchflat_upstream: "2025.9.26",
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> to_string(),
      yt_dlp_version:
        case Settings.get(:yt_dlp_version) do
          {:ok, v} -> v
          _ -> nil
        end || "—"
    }

    db_size =
      case Repo.query("SELECT pg_size_pretty(pg_database_size(current_database()))") do
        {:ok, %{rows: [[size]]}} -> size
        _ -> "—"
      end

    pg_version =
      case Repo.query("SELECT version()") do
        {:ok, %{rows: [[v]]}} ->
          v |> String.split(" ") |> Enum.take(2) |> Enum.join(" ")

        _ ->
          "—"
      end

    # oban_jobs.state is a Postgres enum — cast to text for grouping
    queue_counts =
      from(j in Oban.Job,
        group_by: fragment("?::text", j.state),
        select: {fragment("?::text", j.state), count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    po_token_status = PoTokenServer.status()

    diagnostic_info =
      """
      Pinchfork v#{about.pinchfork_version}
      Pinchflat upstream: #{about.pinchflat_upstream}
      Elixir: #{about.elixir_version}
      OTP: #{about.otp_version}
      yt-dlp: #{about.yt_dlp_version}
      PostgreSQL: #{pg_version}
      PO Token Server: #{po_token_status}
      """
      |> String.trim()

    render(conn, :status,
      about: about,
      db_size: db_size,
      pg_version: pg_version,
      queue_counts: queue_counts,
      po_token_status: po_token_status,
      diagnostic_info: diagnostic_info,
      library: library_stats(),
      disk: disk_usage(Application.get_env(:pinchflat, :media_directory))
    )
  end

  defp library_stats do
    downloaded = from(m in Pinchflat.Media.MediaItem, where: not is_nil(m.media_filepath))

    %{
      sources: Repo.aggregate(from(s in Pinchflat.Sources.Source, where: is_nil(s.marked_for_deletion_at)), :count),
      profiles:
        Repo.aggregate(from(p in Pinchflat.Profiles.MediaProfile, where: is_nil(p.marked_for_deletion_at)), :count),
      videos: Repo.aggregate(Pinchflat.Media.MediaItem, :count),
      downloaded: Repo.aggregate(downloaded, :count),
      size_bytes: Repo.one(from m in downloaded, select: type(coalesce(sum(m.media_size_bytes), 0), :integer))
    }
  end

  # Free space where downloads go, from `df`. nil when it can't be read.
  defp disk_usage(nil), do: nil

  defp disk_usage(path) do
    with {output, 0} <- System.cmd("df", ["-Pk", path], stderr_to_stdout: true),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, total_kb, used_kb, free_kb | _] <- String.split(line),
         {total, ""} <- Integer.parse(total_kb),
         {used, ""} <- Integer.parse(used_kb),
         {free, ""} <- Integer.parse(free_kb),
         true <- total > 0 do
      %{path: path, total: total * 1024, used: used * 1024, free: free * 1024, used_pct: round(used * 100 / total)}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def test_po_token(conn, _params) do
    {flash_type, flash_msg} =
      case PoTokenServer.fetch_token() do
        {:ok, preview} -> {:info, "Token received: #{preview}"}
        {:error, message} -> {:error, message}
      end

    conn
    |> put_flash(flash_type, flash_msg)
    |> redirect(to: ~p"/system/status")
  end

  def backup(conn, _params) do
    render(conn, :backup,
      backups: Backups.list_backups(),
      backup_dir: Backups.backup_dir(),
      max_backups: Backups.max_backups(),
      dir_status: Backups.directory_status(),
      mounted: Backups.mounted?(),
      page_title: "Backup"
    )
  end

  def create_backup(conn, _params) do
    case Backups.directory_status() do
      :ok ->
        case Backups.create_backup() do
          {:ok, filename} ->
            conn
            |> put_flash(:info, "Backed up to #{filename}.")
            |> redirect(to: ~p"/system/backup")

          {:error, reason} ->
            conn
            |> put_flash(:error, "The backup didn't finish: #{reason}")
            |> redirect(to: ~p"/system/backup")
        end

      _ ->
        conn
        |> put_flash(:error, "Pinchfork can't write to #{Backups.backup_dir()}. See the note on this page.")
        |> redirect(to: ~p"/system/backup")
    end
  end

  def download_backup(conn, %{"filename" => filename}) do
    case Backups.backup_path(filename) do
      nil ->
        conn
        |> put_flash(:error, "Backup file not found.")
        |> redirect(to: ~p"/system/backup")

      filepath ->
        send_download(conn, {:file, filepath}, filename: Path.basename(filepath))
    end
  end

  def delete_backup(conn, %{"filename" => filename}) do
    case Backups.delete_backup(filename) do
      :ok ->
        conn
        |> put_flash(:info, "Backup deleted.")
        |> redirect(to: ~p"/system/backup")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not delete backup.")
        |> redirect(to: ~p"/system/backup")
    end
  end

  def updates(conn, _params) do
    yt_dlp_version =
      case Settings.get(:yt_dlp_version) do
        {:ok, v} when v not in [nil, ""] -> v
        _ -> nil
      end

    render(conn, :updates,
      current_version: Application.spec(:pinchflat)[:vsn] |> to_string(),
      yt_dlp_version: yt_dlp_version,
      yt_dlp_policy: System.get_env("YT_DLP_VERSION", "stable"),
      last_backup: List.first(Backups.list_backups()),
      page_title: "Updates"
    )
  end
end
