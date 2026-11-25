defmodule PinchflatWeb.Discovery.DiscoveryLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.ScanWorker

  setup do
    Settings.set(onboarding: false)
    Settings.set(discovery_enabled: true)
    :ok
  end

  defp suggestion(attrs) do
    n = System.unique_integer([:positive])

    {:ok, suggestion} =
      Discovery.upsert_suggestion(
        Map.merge(
          %{
            channel_id: "UC#{n}",
            url: "https://www.youtube.com/channel/UC#{n}",
            name: "Channel #{n}",
            scanned_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )

    suggestion
  end

  test "says how to turn Discovery on when it's off", %{conn: conn} do
    Settings.set(discovery_enabled: false)
    {:ok, view, html} = live(conn, ~p"/discovery")

    assert html =~ "Discovery is off"
    assert has_element?(view, ~s(#discovery-off a[href="/settings/discovery"]))
    refute has_element?(view, "#scan")
  end

  test "invites a first scan when there's nothing yet", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/discovery")

    assert html =~ "No suggestions yet"
    assert has_element?(view, "#scan")
  end

  test "shows each suggestion with its facts, reason and match strength", %{conn: conn} do
    suggestion(%{
      name: "Woodworking Weekly",
      subscriber_count: 1_200_000,
      video_count: 340,
      reason: "Featured by 2 of your channels",
      cluster: "Woodworking",
      score: 60.0
    })

    {:ok, _view, html} = live(conn, ~p"/discovery")

    assert html =~ "Woodworking Weekly"
    assert html =~ "1.2M subscribers · 340 videos"
    assert html =~ "Featured by 2 of your channels."
    assert html =~ "Strong match"
    assert html =~ "Showing 1 of 1"
    refute html =~ "Score:"
  end

  test "Add source opens Add Source prefilled", %{conn: conn} do
    s = suggestion(%{name: "Shelf Talk"})
    {:ok, view, _html} = live(conn, ~p"/discovery")

    assert {:error, {:redirect, %{to: to}}} =
             view |> element("#suggestion-#{s.id} button", "Add source") |> render_click()

    assert to =~ "/sources/new?"
    assert to =~ "prefill_name=Shelf+Talk"
    # Stays pending until a source for the channel actually exists
    assert Repo.reload!(s).status == "pending"
  end

  test "Dismiss hides a suggestion and Undo brings it back", %{conn: conn} do
    s = suggestion(%{name: "Not For Me"})
    {:ok, view, _html} = live(conn, ~p"/discovery")

    view |> element("#suggestion-#{s.id} button", "Dismiss") |> render_click()
    refute has_element?(view, "#suggestion-#{s.id}")
    assert has_element?(view, "#dismissed-banner", "Not For Me")
    assert Repo.reload!(s).status == "dismissed"

    view |> element("#dismissed-banner button", "Undo") |> render_click()
    assert has_element?(view, "#suggestion-#{s.id}")
    assert Repo.reload!(s).status == "pending"
  end

  test "channels that are already sources aren't suggested", %{conn: conn} do
    s = suggestion(%{name: "Already Have It"})
    source_fixture(collection_id: s.channel_id)

    {:ok, _view, html} = live(conn, ~p"/discovery")
    refute html =~ "Already Have It"
  end

  test "Show others appears only when there are more than fit", %{conn: conn} do
    for _ <- 1..12, do: suggestion(%{})
    {:ok, view, _html} = live(conn, ~p"/discovery")
    refute has_element?(view, "#shuffle")

    suggestion(%{})
    {:ok, view, _html} = live(conn, ~p"/discovery")
    assert has_element?(view, "#shuffle")
    assert render(view) =~ "Showing 12 of 13"
  end

  test "Scan now starts a scan and the page updates when it finishes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discovery")

    view |> element("#scan") |> render_click()
    assert_enqueued(worker: ScanWorker)
    assert has_element?(view, "#scan-banner")

    suggestion(%{name: "Fresh Find"})
    send(view.pid, {:scan_complete, %{persisted: 1}})

    html = render(view)
    assert html =~ "Scan finished with 1 suggestion."
    assert html =~ "Fresh Find"
    refute has_element?(view, "#scan-banner")
  end
end
