defmodule PinchflatWeb.Sources.SourceMetadataTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    %{source: source_fixture(custom_name: "Woodworking Weekly", description: "All about wood.")}
  end

  describe "edit_metadata" do
    test "opens on Name and description", %{conn: conn, source: source} do
      html = conn |> get(~p"/sources/#{source}/edit_metadata") |> html_response(200)

      assert html =~ "Artwork and description"
      assert html =~ "All about wood."
      assert html =~ "tab: &#39;general&#39;"
    end

    test "can open straight on the Poster tab", %{conn: conn, source: source} do
      html = conn |> get(~p"/sources/#{source}/edit_metadata?tab=poster") |> html_response(200)

      assert html =~ "tab: &#39;poster&#39;"
      assert html =~ "From YouTube"
    end
  end

  describe "update_metadata" do
    test "saves the name, description and locks", %{conn: conn, source: source} do
      conn =
        post(conn, ~p"/sources/#{source}/edit_metadata", %{
          "source" => %{
            "custom_name" => "Wood Weekly",
            "custom_name_locked" => "true",
            "description" => "New text",
            "description_locked" => "false"
          }
        })

      assert redirected_to(conn) == ~p"/sources/#{source}"
      source = Repo.reload!(source)
      assert source.custom_name == "Wood Weekly"
      assert source.custom_name_locked
      refute source.description_locked
      assert source.description == "New text"
    end
  end

  describe "custom poster" do
    test "removing it returns to the Poster tab", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}/custom_poster")

      assert redirected_to(conn) == ~p"/sources/#{source}/edit_metadata?tab=poster"
    end

    test "a missing image keeps you on the Poster tab with an error", %{conn: conn, source: source} do
      conn = post(conn, ~p"/sources/#{source}/custom_poster", %{"poster" => %{"url" => ""}})

      assert html_response(conn, 200) =~ "tab: &#39;poster&#39;"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "No image provided"
    end
  end
end
