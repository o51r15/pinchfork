defmodule Pinchflat.Lifecycle.Notifications.Notifier do
  @moduledoc """
  Sends Apprise notifications for the events chosen in Settings › Notifications.

  Every event has its own switch (a `notify_*` setting). Nothing is sent when there's no
  Apprise server, or when that event is switched off. Sending never raises: a failure is
  logged and the caller carries on.
  """

  require Logger

  alias Pinchflat.Settings

  # {event, setting, label, help, sample title, sample body}
  @events [
    {:new_media, :notify_new_media, "New videos found", "When a check finds new videos to download.",
     "New videos found", "Found 3 new videos for Example Channel. Downloading them now."},
    {:download_finished, :notify_download_finished, "Download finished", "Every video that finishes downloading.",
     "Downloaded", "An example video (Example Channel)"},
    {:download_failed, :notify_download_failed, "Download failed",
     "When a video can't be downloaded and won't be retried, for example because it was removed.", "Download failed",
     "An example video (Example Channel): Video unavailable"},
    {:source_added, :notify_source_added, "Source added", "When a channel or playlist is added.", "Source added",
     "Example Channel"},
    {:source_removed, :notify_source_removed, "Source removed", "When a channel or playlist is deleted.",
     "Source removed", "Example Channel"},
    {:problem, :notify_problems, "Problems",
     "Checked every 30 minutes: the token server stops answering or the download disk is nearly full. Sent once when it starts and once when it's fixed.",
     "Problem", "The download disk is nearly full: 12 GB free."}
  ]

  @doc """
  The events, in display order: [%{event, setting, label, help}].
  """
  def events do
    Enum.map(@events, fn {event, setting, label, help, _title, _body} ->
      %{event: event, setting: setting, label: label, help: help}
    end)
  end

  @doc """
  The notify_* setting names.
  """
  def settings, do: Enum.map(@events, &elem(&1, 1))

  @doc """
  Sends a notification for `event` if a server is set and that event is switched on.

  Returns :ok | :skipped | {:error, binary()}
  """
  def notify(event, title, body) do
    setting = Settings.record()

    if enabled?(setting, event) do
      send_now(setting.apprise_server, title, body)
    else
      :skipped
    end
  end

  @doc """
  Whether `event` would be sent with the given settings.
  """
  def enabled?(setting, event) do
    setting.apprise_server not in [nil, ""] and event_on?(setting, event)
  end

  @doc """
  Whether event's switch is on, regardless of the server.
  """
  def event_on?(setting, event) do
    {_, key, _, _, _, _} = List.keyfind(@events, event, 0)
    Map.get(setting, key) == true
  end

  @doc """
  Sends the example message for `event` to `server`, whether or not the event is switched on.
  Used by the test buttons.

  Returns :ok | {:error, binary()}
  """
  def send_sample(event, server) do
    {_, _, _, _, title, body} = List.keyfind(@events, event, 0)

    case send_now(server, title <> " (test)", body) do
      :ok -> :ok
      :skipped -> {:error, "Enter a server first."}
      error -> error
    end
  end

  defp send_now(server, _title, _body) when server in [nil, ""], do: :skipped

  defp send_now(server, title, body) do
    servers = String.split(server, ~r/\s+/, trim: true)

    case runner().run(servers, title: "[Pinchfork] #{title}", body: body) do
      {:ok, _} ->
        :ok

      {:error, :no_servers} ->
        :skipped

      {:error, message} ->
        Logger.error("Couldn't send the #{title} notification: #{message}")
        {:error, to_string(message)}
    end
  rescue
    e ->
      Logger.error("Couldn't send the #{title} notification: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp runner, do: Application.get_env(:pinchflat, :apprise_runner)
end
