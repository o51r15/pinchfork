defmodule PinchflatWeb.Sources.YearGroupLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias PinchflatWeb.Sources.YearGroupLive

  defp open(conn, source), do: live_isolated(conn, YearGroupLive, session: %{"source_id" => source.id})

  test "a year with one video says 1 episode, not 1 episodes", %{conn: conn} do
    source = source_fixture()
    media_item_fixture(source_id: source.id, uploaded_at: ~U[2024-05-01 00:00:00Z])

    {:ok, _view, html} = open(conn, source)

    assert html =~ ~r/>\s*1\s*<\/span>\s*episode\s*</
    refute html =~ "episodes"
  end

  test "counts and the page size are labelled", %{conn: conn} do
    source = source_fixture()

    for day <- 1..3 do
      media_item_fixture(source_id: source.id, uploaded_at: DateTime.new!(~D[2024-05-01], ~T[00:00:00]) |> DateTime.add(day, :day))
    end

    {:ok, view, html} = open(conn, source)

    assert html =~ "episodes"
    assert html =~ "downloaded"
    # The newest year is open, so its page-size picker shows, with a label
    assert has_element?(view, ~s(label[for="page-size-2024"]), "Show")
    assert has_element?(view, "#page-size-2024 option[value=\"all\"]")
  end

  test "an empty source explains itself", %{conn: conn} do
    {:ok, _view, html} = open(conn, source_fixture())
    assert html =~ "No videos yet"
  end

  test "the eye button turns a video off", %{conn: conn} do
    source = source_fixture()
    item = media_item_fixture(source_id: source.id, uploaded_at: ~U[2024-05-01 00:00:00Z])
    {:ok, view, _html} = open(conn, source)

    view |> element(~s(button[phx-value-id="#{item.id}"])) |> render_click()

    item = Repo.reload!(item)
    assert item.prevent_download
    assert item.download_prevented_reason == "manual"
    # The fixture is already downloaded, so it stays "Downloaded"; the button flips.
    assert render(view) =~ "Turn downloading on for this video"
  end
end
