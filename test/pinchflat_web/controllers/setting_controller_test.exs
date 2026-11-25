defmodule PinchflatWeb.SettingControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Utils.FilesystemUtils

  describe "old settings addresses" do
    test "/settings goes to General", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/settings")) == ~p"/settings/general"
    end

    test "/app_info goes to General", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/app_info")) == ~p"/settings/general"
    end
  end

  describe "download_logs" do
    test "downloads logs", %{conn: conn} do
      log_path = Path.join([System.tmp_dir!(), "pinchflat", "data", "pinchflat.log"])
      FilesystemUtils.write_p(log_path, "test log data")
      Application.put_env(:pinchflat, :log_path, log_path)

      conn = get(conn, ~p"/download_logs")

      assert response(conn, 200) =~ "test log data"

      Application.put_env(:pinchflat, :log_path, nil)
    end

    test "redirects when log file is not found", %{conn: conn} do
      conn = get(conn, ~p"/download_logs")

      assert redirected_to(conn) == ~p"/settings/general"
      assert conn.assigns[:flash]["error"] == "The log file couldn't be found."
    end
  end
end
