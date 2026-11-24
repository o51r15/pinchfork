defmodule PinchflatWeb.Pages.PageController do
  use PinchflatWeb, :controller
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile

  def home(conn, _params) do
    redirect(conn, to: PinchflatWeb.UserAuth.after_sign_in_path())
  end

  def stats(conn, _params) do
    downloaded_media_items = where(MediaQuery.new(), ^MediaQuery.downloaded())

    render(conn, :stats,
      media_profile_count: Repo.aggregate(MediaProfile, :count, :id),
      source_count: Repo.aggregate(Source, :count, :id),
      media_item_size: Repo.aggregate(downloaded_media_items, :sum, :media_size_bytes),
      media_item_count: Repo.aggregate(downloaded_media_items, :count, :id)
    )
  end

  def activity(conn, _params) do
    render(conn, :activity)
  end
end
