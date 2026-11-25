defmodule PinchflatWeb.Router do
  use PinchflatWeb, :router
  import PinchflatWeb.Plugs
  import PinchflatWeb.UserAuth
  import Phoenix.LiveDashboard.Router

  # IMPORTANT: `strip_trailing_extension` in endpoint.ex removes
  # the extension from the path
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PinchflatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :allow_iframe_embed
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PinchflatWeb do
    pipe_through [:maybe_basic_auth, :token_protected_route]

    # has to match before /sources/:id
    get "/sources/opml", Podcasts.PodcastController, :opml_feed
  end

  # Routes in here _may not be_ protected by basic auth. This is necessary for
  # media streaming to work for RSS podcast feeds. They are outside the sign-in
  # system on purpose so podcast apps keep working.
  scope "/", PinchflatWeb do
    pipe_through :maybe_basic_auth

    get "/sources/:uuid/feed", Podcasts.PodcastController, :rss_feed
    get "/sources/:uuid/feed_image", Podcasts.PodcastController, :feed_image
    get "/media/:uuid/episode_image", Podcasts.PodcastController, :episode_image

    get "/media/:uuid/stream", MediaItems.MediaItemController, :stream
  end

  # Sign-in and first-run account creation (no sign-in required)
  scope "/", PinchflatWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/login", Auth.UserSessionController, :new
    post "/login", Auth.UserSessionController, :create
  end

  scope "/", PinchflatWeb do
    pipe_through :browser

    get "/setup", Setup.SetupController, :account
    post "/setup", Setup.SetupController, :create_account
    delete "/logout", Auth.UserSessionController, :delete
  end

  # Everything else needs a signed-in user
  scope "/", PinchflatWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", Pages.PageController, :home
    get "/stats", Pages.PageController, :stats
    get "/activity", Pages.PageController, :activity

    live_session :authenticated, on_mount: [{PinchflatWeb.UserAuth, :ensure_authenticated}] do
      live "/setup/:step", Setup.SetupLive, :show
      live "/discovery", Discovery.DiscoveryLive, :index
      live "/sources", Sources.SourceIndexLive, :index
      live "/sources/new", Sources.SourceNewLive, :new
      live "/sources/:id/edit", Sources.SourceEditLive, :edit
      live "/settings/:page", Settings.SettingsLive, :show
      live "/media_profiles/new", MediaProfiles.MediaProfileFormLive, :new
      live "/media_profiles/:id/edit", MediaProfiles.MediaProfileFormLive, :edit
      live "/system/backup/upload", System.BackupLive, :upload
      live "/system/backup/:filename/restore", System.BackupLive, :restore
    end

    resources "/media_profiles", MediaProfiles.MediaProfileController, only: [:index, :show, :delete]
    resources "/search", Searches.SearchController, only: [:show], singleton: true

    get "/settings", Settings.SettingController, :show
    get "/app_info", Settings.SettingController, :app_info
    get "/download_logs", Settings.SettingController, :download_logs

    get "/system/status", System.SystemController, :status
    post "/system/test_po_token", System.SystemController, :test_po_token
    get "/system/logs", Settings.SettingController, :download_logs
    get "/system/backup", System.SystemController, :backup
    post "/system/backup", System.SystemController, :create_backup
    get "/system/backup/:filename/download", System.SystemController, :download_backup
    delete "/system/backup/:filename", System.SystemController, :delete_backup
    get "/system/updates", System.SystemController, :updates

    # Must be declared before resources "/sources" to avoid conflict with nested routes
    get "/sources/:id/poster", Sources.SourceController, :poster
    get "/sources/:id/fanart", Sources.SourceController, :fanart

    resources "/sources", Sources.SourceController, except: [:index, :new, :edit] do
      post "/force_download_pending", Sources.SourceController, :force_download_pending
      post "/force_redownload", Sources.SourceController, :force_redownload
      post "/force_index", Sources.SourceController, :force_index
      post "/force_metadata_refresh", Sources.SourceController, :force_metadata_refresh
      post "/sync_files_on_disk", Sources.SourceController, :sync_files_on_disk
      get "/edit_metadata", Sources.SourceController, :edit_metadata
      post "/edit_metadata", Sources.SourceController, :update_metadata
      post "/custom_poster", Sources.SourceController, :upload_custom_poster
      delete "/custom_poster", Sources.SourceController, :delete_custom_poster

      resources "/media", MediaItems.MediaItemController, only: [:show, :edit, :update, :delete] do
        post "/force_download", MediaItems.MediaItemController, :force_download
      end
    end
  end

  # No auth or CSRF protection for the health check endpoint
  scope "/", PinchflatWeb do
    pipe_through :api

    get "/healthcheck", HealthController, :check, log: false
  end

  scope "/dev" do
    pipe_through [:browser, :require_authenticated_user]

    live_dashboard "/dashboard",
      metrics: PinchflatWeb.Telemetry,
      ecto_repos: [Pinchflat.Repo],
      on_mount: [{PinchflatWeb.UserAuth, :ensure_authenticated}]
  end
end
