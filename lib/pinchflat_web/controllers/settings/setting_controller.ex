defmodule PinchflatWeb.Settings.SettingController do
  @moduledoc """
  What's left of the old one-page Settings: redirects into the Settings pages
  (PinchflatWeb.Settings.SettingsLive) and the log download.
  """

  use PinchflatWeb, :controller

  # /settings and the old /app_info page both land on General
  def show(conn, _params), do: redirect(conn, to: ~p"/settings/general")
  def app_info(conn, _params), do: redirect(conn, to: ~p"/settings/general")

  def download_logs(conn, _params) do
    log_path = Application.get_env(:pinchflat, :log_path)

    if log_path && File.exists?(log_path) do
      send_download(conn, {:file, log_path}, filename: "pinchfork-logs-#{Date.utc_today()}.txt")
    else
      conn
      |> put_flash(:error, "The log file couldn't be found.")
      |> redirect(to: ~p"/settings/general")
    end
  end
end
