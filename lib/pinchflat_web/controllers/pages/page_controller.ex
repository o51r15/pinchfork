defmodule PinchflatWeb.Pages.PageController do
  use PinchflatWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: PinchflatWeb.UserAuth.after_sign_in_path())
  end

  # Stats is now the Library card on System > Status
  def stats(conn, _params) do
    redirect(conn, to: ~p"/system/status")
  end

  def activity(conn, _params) do
    counts = %{
      running: Pinchflat.Pages.JobTableLive.running_count(),
      pending: Pinchflat.Pages.HistoryTableLive.count_for("pending"),
      retry: Pinchflat.Pages.HistoryTableLive.count_for("retry"),
      failed: Pinchflat.Pages.HistoryTableLive.count_for("failed")
    }

    render(conn, :activity, counts: counts)
  end
end
