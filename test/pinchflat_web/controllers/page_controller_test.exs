defmodule PinchflatWeb.PageControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Settings

  describe "GET /" do
    test "sends you to the rest of setup while setup is in progress", %{conn: conn} do
      Settings.set(onboarding: true)

      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/setup/storage"
    end

    test "sends you to the sources page once setup is done", %{conn: conn} do
      Settings.set(onboarding: false)

      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/sources"
    end
  end
end
