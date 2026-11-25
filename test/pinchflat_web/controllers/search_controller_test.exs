defmodule PinchflatWeb.SearchControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  describe "show search" do
    test "explains search when there's no term", %{conn: conn} do
      html = conn |> get(~p"/search") |> html_response(200)

      assert html =~ "Search your library"
      refute html =~ ~s(id="search-results")
    end

    test "a blank term is treated as no term", %{conn: conn} do
      media_item_fixture(title: "Anything at all")
      html = conn |> get(~p"/search?q=%20%20") |> html_response(200)

      assert html =~ "Search your library"
      refute html =~ "Anything at all"
    end

    test "lists matching videos with the match marked, source and status", %{conn: conn} do
      source = source_fixture(custom_name: "Woodworking Weekly")

      item =
        media_item_fixture(
          source_id: source.id,
          title: "Building a walnut bookshelf",
          description: "Today we glue up the walnut panels and cut the dados.",
          media_filepath: nil
        )

      html = conn |> get(~p"/search?q=walnut") |> html_response(200)

      assert html =~ "1 video for “walnut”."
      assert html =~ ~s(href="/sources/#{source.id}/media/#{item.id}")
      assert html =~ ~s(<mark class="rounded-sm bg-accent-soft text-fg">walnut</mark>)
      assert html =~ "Woodworking Weekly"
      assert html =~ "Not downloaded"
    end

    test "escapes text around the marks", %{conn: conn} do
      media_item_fixture(title: "<script>alert(1)</script> walnut")
      html = conn |> get(~p"/search?q=walnut") |> html_response(200)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "also finds sources by name", %{conn: conn} do
      source = source_fixture(custom_name: "Woodworking Weekly")
      html = conn |> get(~p"/search?q=woodwork") |> html_response(200)

      assert html =~ ~s(id="search-sources")
      assert html =~ ~s(href="/sources/#{source.id}")
    end

    test "says so when nothing matches", %{conn: conn} do
      html = conn |> get(~p"/search?q=zzzznothing") |> html_response(200)

      assert html =~ "Nothing matches “zzzznothing”"
    end

    test "a % in the term doesn't match every source", %{conn: conn} do
      source_fixture(custom_name: "Woodworking Weekly")
      html = conn |> get(~p"/search?q=%25") |> html_response(200)

      refute html =~ ~s(id="search-sources")
    end
  end
end
