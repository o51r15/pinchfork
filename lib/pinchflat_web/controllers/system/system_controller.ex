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

    diagnostic_info =
      """
      Pinchfork v#{about.pinchfork_version}
      Pinchflat upstream: #{about.pinchflat_upstream}
      Elixir: #{about.elixir_version}
      OTP: #{about.otp_version}
      yt-dlp: #{about.yt_dlp_version}
      PostgreSQL: #{pg_version}
      """
      |> String.trim()

    render(conn, :status,
      about: about,
      db_size: db_size,
      pg_version: pg_version,
      queue_counts: queue_counts,
      diagnostic_info: diagnostic_info
    )
  end

  def backup(conn, _params) do
    render(conn, :backup)
  end

  def updates(conn, _params) do
    render(conn, :updates,
      current_version: Application.spec(:pinchflat)[:vsn] |> to_string()
    )
  end
end
