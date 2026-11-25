defmodule PinchflatWeb.System.SystemController do
  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
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
      diagnostic_info: diagnostic_info
    )
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
    render(conn, :backup, backups: Pinchflat.Backups.list_backups())
  end

  def create_backup(conn, _params) do
    case Pinchflat.Backups.create_backup() do
      {:ok, filename} ->
        conn
        |> put_flash(:info, "Backup created: #{filename}")
        |> redirect(to: ~p"/system/backup")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Backup failed: #{reason}")
        |> redirect(to: ~p"/system/backup")
    end
  end

  def download_backup(conn, %{"filename" => filename}) do
    case Pinchflat.Backups.backup_path(filename) do
      nil ->
        conn
        |> put_flash(:error, "Backup file not found.")
        |> redirect(to: ~p"/system/backup")

      filepath ->
        send_download(conn, {:file, filepath}, filename: Path.basename(filepath))
    end
  end

  def delete_backup(conn, %{"filename" => filename}) do
    case Pinchflat.Backups.delete_backup(filename) do
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
    render(conn, :updates, current_version: Application.spec(:pinchflat)[:vsn] |> to_string())
  end
end
