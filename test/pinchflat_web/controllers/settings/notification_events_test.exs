defmodule PinchflatWeb.Settings.NotificationEventsTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  test "lists every event with a switch and a test button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/notifications")

    for event <- ~w(new_media download_finished download_failed source_added source_removed problem) do
      assert has_element?(view, "#notify-event-#{event} input[role=switch]")
      assert has_element?(view, "#test-event-#{event}")
    end

    assert has_element?(view, "#setting_notify_new_media[checked]")
    refute has_element?(view, "#setting_notify_download_finished[checked]")
  end

  test "saves the switches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/notifications")

    view
    |> form("#settings-form", setting: %{notify_new_media: "false", notify_download_failed: "true"})
    |> render_submit()

    refute Settings.get!(:notify_new_media)
    assert Settings.get!(:notify_download_failed)
  end

  test "Test sends that event's example to the typed server", %{conn: conn} do
    Settings.set(apprise_server: "ntfys://ntfy.sh/topic")

    expect(AppriseRunnerMock, :run, fn ["ntfys://ntfy.sh/topic"], opts ->
      assert opts[:title] == "[Pinchfork] Source added (test)"
      {:ok, ""}
    end)

    {:ok, view, _html} = live(conn, ~p"/settings/notifications")
    view |> element("#test-event-source_added") |> render_click()

    assert render_async(view) =~ "Sent"
  end

  test "Test without a server says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/notifications")
    view |> element("#test-event-problem") |> render_click()

    assert render_async(view) =~ "Enter a server first."
  end
end
