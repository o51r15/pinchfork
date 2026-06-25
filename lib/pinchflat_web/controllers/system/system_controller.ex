defmodule PinchflatWeb.System.SystemController do
  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Settings

  def status(conn, _params) do
    about = %{
      pinchfork_version: Application.spec(:pinchflat)[:vsn] |> to_string(),
      pinchflat_upstream: "2025.9.26",
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> to_string(),
      yt_dlp_version: Settings.get!(:yt_dlp_version) || "—"
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
        _ -> "—"
      end

    # oban_jobs.state is a Postgres enum — cast to text for grouping
    queue_counts =
      from(j in Oban.Job,
        group_by: fragment("?::text", j.state),
        select: {fragment("?::text", j.state), count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    # bgutil-provider is on the same Docker network at port 4416.
    # Use curl rather than :httpc — Erlang's DNS resolver doesn't pick up
    # Docker's embedded DNS, but system processes (including curl) do.
    po_token_status =
      case System.cmd("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "http://bgutil-provider:4416"], stderr_to_stdout: true) do
        {code, 0} when code != "" -> :up
        _ -> :down
      end

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
    # Use curl — same reason as the health check above (:httpc can't resolve Docker DNS).
    # Empty JSON body {} tells bgutil to generate its own visitor_data and return a real token.
    {flash_type, flash_msg} =
      case System.cmd(
        "curl",
        ["-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", "{}", "--max-time", "30", "http://bgutil-provider:4416/get_pot"],
        stderr_to_stdout: true
      ) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, %{"poToken" => token}} when is_binary(token) and byte_size(token) > 0 ->
              {:info, "Token received: #{String.slice(token, 0, 40)}…"}

            {:ok, resp} ->
              {:error, "Server responded but no token found. Response: #{inspect(resp)}"}

            {:error, _} ->
              {:error, "Server responded but output was not valid JSON: #{String.slice(output, 0, 200)}"}
          end

        {output, exit_code} ->
          {:error, "curl failed (exit #{exit_code}): #{String.slice(output, 0, 200)}"}
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
    render(conn, :updates,
      current_version: Application.spec(:pinchflat)[:vsn] |> to_string()
    )
  end
end
