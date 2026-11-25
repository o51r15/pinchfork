defmodule PinchflatWeb.Settings.SettingsLive do
  @moduledoc """
  The Settings area: one LiveView, one page per `:page` param. Every page shares the same layout
  and save model: edits are checked as you type, a save bar appears once something has changed,
  and saving writes only that page's own fields. Media Profiles is the one Settings page that
  lives elsewhere (MediaProfileController), because profiles are records, not settings.
  """

  use PinchflatWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Pinchflat.Repo
  alias Pinchflat.Accounts
  alias Pinchflat.Settings
  alias Pinchflat.Discovery
  alias Pinchflat.Sources.Source
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.YtDlp.PoTokenServer

  # page => {title, fields that page may save}
  @pages %{
    "downloads" =>
      {"Downloads",
       [
         :extractor_sleep_interval_seconds,
         :download_throughput_limit,
         :restrict_filenames,
         :video_codec_preference,
         :audio_codec_preference
       ]},
    "youtube" => {"YouTube Access", [:youtube_api_key]},
    "notifications" => {"Notifications", [:apprise_server]},
    "feeds" => {"Feeds & Sharing", []},
    "discovery" => {"Discovery", [:discovery_enabled, :discovery_g1_enabled, :discovery_g2_enabled]},
    "general" => {"General", []}
  }

  @cookie_max_bytes 1_000_000
  @pushover_prefix "pover://"

  @video_codecs [
    {"H.264 (avc), plays on almost everything", "avc"},
    {"VP9", "vp9"},
    {"AV1 (av01), smallest files, needs a newer device", "av01"},
    {"H.265 (hevc)", "hevc"}
  ]

  @audio_codecs [
    {"AAC (m4a), plays on almost everything", "m4a"},
    {"Opus", "opus"},
    {"MP3", "mp3"},
    {"FLAC", "flac"}
  ]

  # Docker variables shown read-only on General: {name, what it controls, value when unset}
  @env_vars [
    {"TZ", "Time zone", "UTC"},
    {"LOCALTEMP", "Stage downloads on local disk before moving them", "off"},
    {"YT_DLP_WORKER_CONCURRENCY", "yt-dlp jobs at once, per queue", "2"},
    {"YT_DLP_VERSION", "yt-dlp update channel", "stable"},
    {"LOG_LEVEL", "Log detail", "info"},
    {"EXPOSE_FEED_ENDPOINTS", "Feeds open without a password", "off"},
    {"BASIC_AUTH_USERNAME", "Password for feeds (basic auth)", "not set"},
    {"BASE_ROUTE_PATH", "Path when behind a reverse proxy", "/"},
    {"ENABLE_PROMETHEUS", "Prometheus metrics", "off"},
    {"ENABLE_IPV6", "Listen on IPv6", "off"}
  ]

  def page_names, do: Map.keys(@pages)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       api_key_test: nil,
       po_status: :checking,
       po_test: nil,
       notify_test: nil,
       show_advanced: false,
       password_errors: %{}
     )
     |> allow_upload(:cookies,
       accept: ~w(.txt),
       max_entries: 1,
       max_file_size: @cookie_max_bytes,
       auto_upload: true,
       progress: &handle_cookie_progress/3
     ), layout: {PinchflatWeb.Layouts, :app}}
  end

  @impl true
  def handle_params(%{"page" => page}, _uri, socket) when is_map_key(@pages, page) do
    {title, _fields} = @pages[page]

    {:noreply,
     socket
     |> assign(page: page, page_title: title, current_path: "/settings/#{page}")
     |> reset_form()
     |> load_page(page)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, push_navigate(socket, to: ~p"/settings/general")}
  end

  defp load_page(socket, "youtube") do
    socket
    |> assign(
      fast_index_count: count_sources(:fast_index),
      cookie_source_count: count_sources(:cookies),
      cookies: cookie_status()
    )
    |> check_po_server()
  end

  defp load_page(socket, "notifications") do
    {mode, user_key, api_token} = parse_apprise(socket.assigns.setting.apprise_server)
    assign(socket, notify_mode: mode, pushover: %{"user_key" => user_key, "api_token" => api_token})
  end

  defp load_page(socket, "feeds") do
    assign(socket, opml_path: opml_path())
  end

  defp load_page(socket, "discovery") do
    assign(socket, dismissed: Discovery.list_suggestions("dismissed"))
  end

  defp load_page(socket, "general") do
    assign(socket, env_rows: env_rows(), diagnostics: diagnostic_info())
  end

  defp load_page(socket, _page), do: socket

  # Form and save model

  defp reset_form(socket) do
    setting = Settings.record()

    socket
    |> assign(:setting, setting)
    |> assign_form(Settings.change_setting(setting))
  end

  defp assign_form(socket, changeset) do
    {_title, fields} = @pages[socket.assigns.page]
    dirty = Enum.any?(fields, &Map.has_key?(changeset.changes, &1))

    assign(socket, form: to_form(changeset, as: :setting), dirty: dirty)
  end

  # Only the current page's fields are accepted, so a page can never save another page's values
  defp page_params(socket, params) do
    {_title, fields} = @pages[socket.assigns.page]
    params = prepare_params(socket.assigns.page, socket, params)

    Map.take(params, Enum.map(fields, &to_string/1))
  end

  # Pushover is entered as two fields but stored as one Apprise URL
  defp prepare_params("notifications", %{assigns: %{notify_mode: :pushover}}, params) do
    pushover = Map.get(params, "pushover", %{})
    user_key = String.trim(pushover["user_key"] || "")
    api_token = String.trim(pushover["api_token"] || "")

    value = if user_key != "" and api_token != "", do: "#{@pushover_prefix}#{user_key}@#{api_token}", else: ""
    Map.put(params, "apprise_server", value)
  end

  defp prepare_params(_page, _socket, params), do: params

  # Events

  @impl true
  def handle_event("validate", %{"setting" => params} = all_params, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change_setting(page_params(socket, params_with_extras(params, all_params)))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign_form(changeset)
     |> maybe_keep_pushover(all_params)
     |> assign(api_key_test: nil, notify_test: nil)}
  end

  def handle_event("save", %{"setting" => params} = all_params, socket) do
    attrs = page_params(socket, params_with_extras(params, all_params))

    case Settings.update_setting(socket.assigns.setting, attrs) do
      {:ok, _setting} ->
        {:noreply, socket |> reset_form() |> load_page(socket.assigns.page) |> put_flash(:info, "Settings saved.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :update))}
    end
  end

  def handle_event("discard", _params, socket) do
    {:noreply,
     socket
     |> reset_form()
     |> load_page(socket.assigns.page)
     |> assign(api_key_test: nil, notify_test: nil)}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, update(socket, :show_advanced, &(!&1))}
  end

  # YouTube Access

  def handle_event("test_api_key", _params, socket) do
    case first_api_key(Phoenix.HTML.Form.input_value(socket.assigns.form, :youtube_api_key)) do
      nil ->
        {:noreply, assign(socket, api_key_test: {:error, "Enter a key first."})}

      key ->
        {:noreply,
         socket
         |> assign(api_key_test: :testing)
         |> start_async(:api_key_test, fn -> youtube_api().test_api_key(key) end)}
    end
  end

  def handle_event("cookies_selected", _params, socket), do: {:noreply, socket}

  def handle_event("remove_cookies", _params, socket) do
    # Left as an empty file rather than deleted: the app recreates a blank one on boot anyway
    File.write(cookies_path(), "")

    {:noreply, socket |> assign(cookies: cookie_status()) |> put_flash(:info, "Cookies file removed.")}
  end

  def handle_event("test_po_server", _params, socket) do
    {:noreply,
     socket
     |> assign(po_test: :testing)
     |> start_async(:po_test, fn -> PoTokenServer.fetch_token() end)}
  end

  # Notifications

  def handle_event("notify_mode", %{"mode" => mode}, socket) when mode in ["pushover", "custom"] do
    {:noreply, assign(socket, notify_mode: String.to_existing_atom(mode), notify_test: nil)}
  end

  def handle_event("test_notification", _params, socket) do
    case Phoenix.HTML.Form.input_value(socket.assigns.form, :apprise_server) do
      blank when blank in [nil, ""] ->
        {:noreply, assign(socket, notify_test: {:error, "Enter a server first."})}

      server ->
        {:noreply,
         socket
         |> assign(notify_test: :testing)
         |> start_async(:notify_test, fn ->
           apprise_runner().run([server], title: "Pinchfork test", body: "Notifications from Pinchfork are working.")
         end)}
    end
  end

  # Feeds & Sharing

  def handle_event("new_route_token", _params, socket) do
    {:ok, _} =
      socket.assigns.setting
      |> Ecto.Changeset.change(route_token: Ecto.UUID.generate())
      |> Repo.update()

    {:noreply,
     socket
     |> reset_form()
     |> load_page("feeds")
     |> put_flash(:info, "New OPML link made. The old link no longer works.")}
  end

  # Discovery

  def handle_event("restore_suggestion", %{"id" => id}, socket) do
    with %{} = suggestion <- Discovery.get_suggestion(id) do
      Discovery.restore_suggestion(suggestion)
    end

    {:noreply, load_page(socket, "discovery")}
  end

  # General

  def handle_event("change_password", %{"password" => params}, socket) do
    attrs = Map.take(params, ["password", "password_confirmation"])

    case Accounts.update_user_password(socket.assigns.current_user, params["current_password"], attrs) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password changed. Sign in with your new password.")
         |> redirect(to: ~p"/login")}

      {:error, changeset} ->
        {:noreply, assign(socket, password_errors: errors_by_field(changeset))}
    end
  end

  def handle_event("rerun_setup", _params, socket) do
    Settings.set(onboarding: true)
    {:noreply, push_navigate(socket, to: ~p"/setup/storage")}
  end

  # The Pushover fields live outside the `setting` params, so they're merged in here
  defp params_with_extras(params, all_params) do
    case all_params do
      %{"pushover" => pushover} -> Map.put(params, "pushover", pushover)
      _ -> params
    end
  end

  defp maybe_keep_pushover(socket, %{"pushover" => pushover}), do: assign(socket, pushover: pushover)
  defp maybe_keep_pushover(socket, _params), do: socket

  defp handle_cookie_progress(:cookies, entry, socket) do
    if entry.done? do
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, FilesystemUtils.cp_p!(path, cookies_path())}
      end)

      status = cookie_status()

      socket =
        if status.youtube?,
          do: put_flash(socket, :info, "Cookies file saved."),
          else:
            put_flash(
              socket,
              :error,
              "Saved, but the file has no youtube.com cookies. Export it while signed in to YouTube."
            )

      {:noreply, assign(socket, cookies: status)}
    else
      {:noreply, socket}
    end
  end

  # Background checks

  defp check_po_server(socket) do
    if connected?(socket) do
      start_async(socket, :po_status, fn -> PoTokenServer.status() end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:po_status, {:ok, status}, socket), do: {:noreply, assign(socket, po_status: status)}
  def handle_async(:po_status, {:exit, _reason}, socket), do: {:noreply, assign(socket, po_status: :down)}

  def handle_async(:po_test, {:ok, {:ok, _preview} = result}, socket) do
    {:noreply, assign(socket, po_test: result, po_status: :up)}
  end

  def handle_async(:po_test, {:ok, result}, socket), do: {:noreply, assign(socket, po_test: result)}

  def handle_async(:api_key_test, {:ok, :ok}, socket), do: {:noreply, assign(socket, api_key_test: {:ok, "Key works"})}

  def handle_async(:api_key_test, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, api_key_test: {:error, to_string(reason)})}
  end

  def handle_async(:notify_test, {:ok, {:ok, _output}}, socket) do
    {:noreply, assign(socket, notify_test: {:ok, "Sent. Check your device."})}
  end

  def handle_async(:notify_test, {:ok, :ok}, socket) do
    {:noreply, assign(socket, notify_test: {:ok, "Sent. Check your device."})}
  end

  def handle_async(:notify_test, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, notify_test: {:error, "Apprise couldn't send it: #{inspect_reason(reason)}"})}
  end

  def handle_async(name, {:exit, _reason}, socket) when name in [:po_test, :api_key_test, :notify_test] do
    {:noreply, assign(socket, [{test_assign(name), {:error, "The test didn't finish. Try again."}}])}
  end

  defp test_assign(:po_test), do: :po_test
  defp test_assign(:api_key_test), do: :api_key_test
  defp test_assign(:notify_test), do: :notify_test

  defp inspect_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 300)
  defp inspect_reason(reason), do: inspect(reason)

  # Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="settings-page"
      class="mx-auto max-w-5xl"
      data-dirty={to_string(@dirty)}
      x-data
      x-on:beforeunload.window="if ($el.dataset.dirty === 'true') { $event.preventDefault(); $event.returnValue = '' }"
    >
      {render_page(assigns)}
      <.save_bar form="settings-form" dirty={@dirty} />
    </div>
    """
  end

  defp render_page(%{page: "downloads"} = assigns) do
    ~H"""
    <.page_header
      title="Downloads"
      description="How fast Pinchfork downloads, how files are named, and which formats it prefers. Changes apply to new downloads."
    >
      <:actions>
        <button type="button" phx-click="toggle_advanced" class={small_button()} id="toggle-advanced">
          <.icon
            name={if @show_advanced, do: "hero-eye-slash-mini", else: "hero-adjustments-horizontal-mini"}
            class="h-4 w-4"
          />
          {if @show_advanced, do: "Hide advanced", else: "Show advanced"}
        </button>
      </:actions>
    </.page_header>

    <.form for={@form} id="settings-form" phx-change="validate" phx-submit="save" class="flex flex-col gap-6">
      <.card title="Speed and pacing" description="Slow down if YouTube starts refusing requests.">
        <.settings_row
          label="Pause between requests"
          for="setting_extractor_sleep_interval_seconds"
          help="Seconds to wait between requests to YouTube. Raise it if you see rate-limit or bot errors. Default: 0."
        >
          <div class="flex items-center gap-2">
            <input
              type="number"
              min="0"
              step="1"
              id="setting_extractor_sleep_interval_seconds"
              name={@form[:extractor_sleep_interval_seconds].name}
              value={@form[:extractor_sleep_interval_seconds].value}
              class="pf-input tabular w-32"
              phx-debounce="250"
            />
            <span class="text-sm text-muted">seconds</span>
          </div>
          <.field_errors field={@form[:extractor_sleep_interval_seconds]} />
        </.settings_row>
        <.settings_row
          label="Speed limit"
          for="setting_download_throughput_limit"
          help="Per download. A number with K, M or G, like 500K or 4.2M. Leave empty for no limit. Default: no limit."
        >
          <input
            type="text"
            id="setting_download_throughput_limit"
            name={@form[:download_throughput_limit].name}
            value={@form[:download_throughput_limit].value}
            class="pf-input w-40 font-mono"
            placeholder="No limit"
            autocomplete="off"
            phx-debounce="250"
          />
          <.field_errors field={@form[:download_throughput_limit]} />
        </.settings_row>
      </.card>

      <.card
        :if={@show_advanced}
        title="Preferred formats"
        description="A soft preference: when YouTube doesn't offer a format, the next best one is used."
        id="advanced-formats"
      >
        <:actions>
          <.docs_link href="https://github.com/yt-dlp/yt-dlp#sorting-formats" />
        </:actions>
        <.settings_row label="Video codec" for="setting_video_codec_preference" help="Default: H.264 (avc).">
          <.select_control
            field={@form[:video_codec_preference]}
            options={codec_options(:video, @form[:video_codec_preference].value)}
          />
        </.settings_row>
        <.settings_row label="Audio codec" for="setting_audio_codec_preference" help="Default: AAC (m4a).">
          <.select_control
            field={@form[:audio_codec_preference]}
            options={codec_options(:audio, @form[:audio_codec_preference].value)}
          />
        </.settings_row>
        <.settings_row
          label="Plain file names"
          for="setting_restrict_filenames"
          help="Only plain letters, numbers, dashes and underscores in file names: no spaces, accents or symbols. Turn on if another app has trouble with your file names. Default: off."
        >
          <.switch field={@form[:restrict_filenames]} />
        </.settings_row>
      </.card>
      <%!-- Keeps hidden advanced values in the form, so validation and saving still see them --%>
      <div :if={!@show_advanced} class="hidden">
        <input type="hidden" name={@form[:video_codec_preference].name} value={@form[:video_codec_preference].value} />
        <input type="hidden" name={@form[:audio_codec_preference].name} value={@form[:audio_codec_preference].value} />
        <input type="hidden" name={@form[:restrict_filenames].name} value={to_string(@form[:restrict_filenames].value)} />
      </div>
    </.form>

    <.card
      title="Set by Docker"
      description="These come from the container's environment and can't be changed here."
      class="mt-6"
    >
      <.settings_row
        label="Local staging"
        env="LOCALTEMP"
        help="Downloads are built on local disk, then moved to the media folder in one step."
      >
        <.status_chip :if={env_on?("LOCALTEMP")} kind={:ok}>On</.status_chip>
        <.status_chip :if={!env_on?("LOCALTEMP")}>Off</.status_chip>
      </.settings_row>
      <.settings_row
        label="Download jobs at once"
        env="YT_DLP_WORKER_CONCURRENCY"
        help="Per queue. Lower it if YouTube blocks you, raise it on a fast connection."
      >
        <span class="tabular text-sm text-fg">{System.get_env("YT_DLP_WORKER_CONCURRENCY") || "2"}</span>
      </.settings_row>
      <.settings_row label="yt-dlp" env="YT_DLP_VERSION" help="Updated automatically every day from the chosen channel.">
        <div class="flex flex-wrap items-center gap-3 text-sm">
          <span class="font-mono text-fg">{@setting.yt_dlp_version || "unknown"}</span>
          <span class="text-muted">channel: {System.get_env("YT_DLP_VERSION") || "stable"}</span>
          <.link href={~p"/system/updates"} class="font-medium text-accent hover:underline">Updates</.link>
        </div>
      </.settings_row>
    </.card>
    """
  end

  defp render_page(%{page: "youtube"} = assigns) do
    ~H"""
    <.page_header
      title="YouTube Access"
      description="How Pinchfork gets past YouTube's limits: an API key for quick checks, a cookies file for restricted videos, and the token server some downloads need."
    />

    <.form for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <.card
        title="YouTube Data API"
        description="Optional. Lets Fast Indexing check for new uploads every few minutes instead of waiting for the next full index."
      >
        <:actions>
          <.docs_link href="https://github.com/kieraneglin/pinchflat/wiki/Generating-a-YouTube-API-key" />
        </:actions>
        <.settings_row
          label="API key"
          for="setting_youtube_api_key"
          help="Separate several keys with commas to spread the daily quota. Default: none."
        >
          <input
            type="text"
            id="setting_youtube_api_key"
            name={@form[:youtube_api_key].name}
            value={@form[:youtube_api_key].value}
            class="pf-input font-mono text-sm"
            placeholder="AIza…"
            autocomplete="off"
            spellcheck="false"
            phx-debounce="250"
          />
          <div class="mt-2.5 flex flex-wrap items-center gap-2">
            <button type="button" phx-click="test_api_key" class={small_button()}>
              <.icon name="hero-play-mini" class="h-4 w-4" /> Test key
            </button>
            <.test_result result={@api_key_test} />
            <span class="ml-auto text-xs text-muted">
              Used by Fast Indexing on {@fast_index_count} {pluralize(@fast_index_count, "source")}
            </span>
          </div>
        </.settings_row>
      </.card>
    </.form>

    <.card
      title="Cookies"
      description="Needed for members-only, age-restricted and private videos. Each source chooses whether to use them."
      class="mt-6"
      id="cookies-card"
    >
      <:actions>
        <.docs_link href="https://github.com/o51r15/pinchfork/wiki/YouTube-Cookies" />
      </:actions>
      <.settings_row label="cookies.txt" help="Export it in Netscape format from a browser that's signed in to YouTube.">
        <div class="flex flex-wrap items-center gap-2">
          <.status_chip :if={@cookies.present? and @cookies.youtube?} kind={:ok}>Saved</.status_chip>
          <.status_chip :if={@cookies.present? and not @cookies.youtube?} kind={:warn}>
            No YouTube cookies in file
          </.status_chip>
          <.status_chip :if={not @cookies.present?}>No file</.status_chip>
          <span :if={@cookies.present?} class="text-xs text-muted">
            Updated {ago(@cookies.updated_at)} · {div(@cookies.size, 1024) + 1} KB
          </span>
        </div>
        <form id="cookies-form" phx-change="cookies_selected" class="mt-2.5 flex flex-wrap items-center gap-2">
          <label class={[small_button(), "cursor-pointer"]}>
            <.icon name="hero-arrow-up-tray-mini" class="h-4 w-4" />
            {if @cookies.present?, do: "Replace file", else: "Upload file"}
            <.live_file_input upload={@uploads.cookies} class="sr-only" />
          </label>
          <button
            :if={@cookies.present?}
            type="button"
            phx-click="remove_cookies"
            data-confirm="Remove the cookies file? Sources that use cookies will download without them."
            class="inline-flex h-8 items-center rounded-lg px-3 text-[13px] font-semibold text-bad hover:bg-bad/10"
          >
            Remove
          </button>
          <span class="ml-auto text-xs text-muted">
            Used by {@cookie_source_count} {pluralize(@cookie_source_count, "source")}
          </span>
        </form>
        <p :for={err <- upload_problems(@uploads.cookies)} class="mt-2 text-sm text-bad">{err}</p>
      </.settings_row>
    </.card>

    <.card
      title="PO token server"
      description="A helper container that hands yt-dlp the proof-of-origin tokens some YouTube download clients need."
      class="mt-6"
      id="po-token-card"
    >
      <.settings_row
        label="bgutil-provider"
        help="Runs as its own container next to Pinchfork. Pinchfork reaches it at bgutil-provider:4416 on the Docker network."
      >
        <div class="flex flex-wrap items-center gap-2">
          <.status_chip :if={@po_status == :checking}>Checking…</.status_chip>
          <.status_chip :if={@po_status == :up} kind={:ok}>Reachable</.status_chip>
          <.status_chip :if={@po_status == :down} kind={:bad}>Not reachable</.status_chip>
          <button type="button" phx-click="test_po_server" class={[small_button(), "ml-1"]}>
            <.icon name="hero-play-mini" class="h-4 w-4" /> Get a test token
          </button>
          <.test_result result={@po_test} />
        </div>
        <p :if={@po_status == :down} class="mt-2 text-[13px] leading-5 text-muted">
          Downloads that need a token will fail. Check that the container is running and on the same Docker network as Pinchfork.
        </p>
      </.settings_row>
    </.card>
    """
  end

  defp render_page(%{page: "notifications"} = assigns) do
    ~H"""
    <.page_header
      title="Notifications"
      description="Pinchfork can tell you when new videos have been downloaded. It sends notifications through Apprise, which supports Pushover, Discord, Telegram, ntfy, email and many more."
    />

    <.form for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <.card title="Where to send them">
        <:actions>
          <.docs_link href="https://github.com/caronc/apprise/wiki/URLBasics" />
        </:actions>
        <div class="border-t border-line px-5 pt-4">
          <div class="inline-flex rounded-lg border border-line p-0.5" role="tablist" aria-label="Notification service">
            <button
              :for={{mode, label} <- [pushover: "Pushover", custom: "Other service (Apprise URL)"]}
              type="button"
              role="tab"
              aria-selected={to_string(@notify_mode == mode)}
              phx-click="notify_mode"
              phx-value-mode={mode}
              class={[
                "rounded-md px-3 py-1.5 text-[13px] font-semibold transition-colors",
                if(@notify_mode == mode, do: "bg-surface-3 text-fg", else: "text-muted hover:text-fg")
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <div :if={@notify_mode == :pushover}>
          <input type="hidden" name={@form[:apprise_server].name} value={@form[:apprise_server].value} />
          <.settings_row label="User key" for="pushover_user_key" help="Shown on your dashboard at pushover.net.">
            <input
              type="text"
              id="pushover_user_key"
              name="pushover[user_key]"
              value={@pushover["user_key"]}
              class="pf-input font-mono text-sm"
              autocomplete="off"
              spellcheck="false"
              phx-debounce="250"
            />
          </.settings_row>
          <.settings_row label="API token" for="pushover_api_token" help="Create an application on pushover.net to get one.">
            <input
              type="text"
              id="pushover_api_token"
              name="pushover[api_token]"
              value={@pushover["api_token"]}
              class="pf-input font-mono text-sm"
              autocomplete="off"
              spellcheck="false"
              phx-debounce="250"
            />
          </.settings_row>
        </div>

        <.settings_row
          :if={@notify_mode == :custom}
          label="Apprise URL"
          for="setting_apprise_server"
          help="One URL for the service you use, for example discord://webhook_id/webhook_token. Separate several with spaces."
        >
          <input
            type="text"
            id="setting_apprise_server"
            name={@form[:apprise_server].name}
            value={@form[:apprise_server].value}
            class="pf-input font-mono text-sm"
            placeholder="service://…"
            autocomplete="off"
            spellcheck="false"
            phx-debounce="250"
          />
        </.settings_row>

        <div class="flex flex-wrap items-center gap-2 border-t border-line px-5 py-4">
          <button type="button" phx-click="test_notification" class={small_button()}>
            <.icon name="hero-paper-airplane-mini" class="h-4 w-4" /> Send a test
          </button>
          <.test_result result={@notify_test} />
          <span :if={@dirty} class="ml-auto text-xs text-muted">The test uses what's typed, even before you save.</span>
        </div>
      </.card>
    </.form>
    """
  end

  defp render_page(%{page: "feeds"} = assigns) do
    ~H"""
    <.page_header
      title="Feeds & Sharing"
      description="Every source has a podcast (RSS) feed, so you can follow your channels in a podcast app. Feed links use the address you opened Pinchfork with, so open it the way your podcast app will reach it."
    />

    <.card title="Who can open feeds" id="feed-access">
      <.settings_row
        label="Feed access"
        help="Feeds can't use your Pinchfork sign-in, because podcast apps can't sign in. They are protected by the Docker settings shown here instead."
      >
        <div class="flex flex-col items-start gap-2">
          <.status_chip :if={feed_access() == :open} kind={:warn}>Open to anyone who has the link</.status_chip>
          <.status_chip :if={feed_access() == :password} kind={:ok}>Protected by a password (basic auth)</.status_chip>
          <.status_chip :if={feed_access() == :network} kind={:info}>Open to anyone on your network</.status_chip>
          <div class="flex flex-wrap gap-1.5">
            <span class="pf-chip border border-line font-medium text-muted">
              EXPOSE_FEED_ENDPOINTS · {if env_on?("EXPOSE_FEED_ENDPOINTS"), do: "on", else: "off"}
            </span>
            <span class="pf-chip border border-line font-medium text-muted">
              BASIC_AUTH_USERNAME · {if env_on?("BASIC_AUTH_USERNAME"), do: "set", else: "not set"}
            </span>
          </div>
        </div>
      </.settings_row>
      <.settings_row
        label="Base path"
        env="BASE_ROUTE_PATH"
        help="Only needed when Pinchfork sits under a sub-path of a reverse proxy."
      >
        <span class="font-mono text-sm text-fg">{System.get_env("BASE_ROUTE_PATH") || "/"}</span>
      </.settings_row>
    </.card>

    <.card
      title="All sources at once (OPML)"
      description="Podcast apps that import OPML can add every source in one step. The link includes a private token; anyone with it can see your list of sources."
      class="mt-6"
      id="opml-card"
    >
      <.settings_row
        label="OPML link"
        for="opml-url"
        help="Make a new link if this one was shared by mistake. The old one stops working."
      >
        <div x-data={"{ url: new URL(#{Jason.encode!(@opml_path)}, window.location.href).href, copied: false }"}>
          <input
            id="opml-url"
            type="text"
            readonly
            value={@opml_path}
            x-bind:value="url"
            class="pf-input font-mono text-xs"
            x-on:focus="$el.select()"
          />
          <div class="mt-2.5 flex flex-wrap items-center gap-2">
            <button
              type="button"
              class={small_button()}
              x-on:click="navigator.clipboard.writeText(url).then(() => { copied = true; setTimeout(() => copied = false, 2000) })"
            >
              <.icon name="hero-clipboard-document-mini" class="h-4 w-4" />
              <span x-text="copied ? 'Copied' : 'Copy link'">Copy link</span>
            </button>
            <button
              type="button"
              phx-click="new_route_token"
              data-confirm="Make a new OPML link? The current link will stop working in every app that uses it."
              class="inline-flex h-8 items-center rounded-lg px-3 text-[13px] font-semibold text-muted hover:bg-surface-2 hover:text-fg"
            >
              Make a new link
            </button>
          </div>
        </div>
      </.settings_row>
    </.card>
    """
  end

  defp render_page(%{page: "discovery"} = assigns) do
    ~H"""
    <.page_header
      title="Discovery"
      description="Suggests new channels based on the ones you already have. Scans run when you press Scan Now on the Discovery page."
    />

    <.form for={@form} id="settings-form" phx-change="validate" phx-submit="save">
      <.card title="Discovery">
        <.settings_row
          label="Turn on Discovery"
          for="setting_discovery_enabled"
          help="Adds Discovery to the menu. Default: off."
        >
          <.switch field={@form[:discovery_enabled]} />
        </.settings_row>
        <.settings_row
          label="Channels mentioned in your videos"
          for="setting_discovery_g1_enabled"
          help="Looks for channels linked or named in your videos' descriptions. Uses only data already on disk."
        >
          <.switch field={@form[:discovery_g1_enabled]} />
        </.settings_row>
        <.settings_row
          label="Channels your sources feature"
          for="setting_discovery_g2_enabled"
          help="Reads the Channels tab of each source on YouTube. Uses yt-dlp, not your API quota."
        >
          <.switch field={@form[:discovery_g2_enabled]} />
        </.settings_row>
      </.card>
    </.form>

    <.card
      title="Dismissed channels"
      description="Suggestions you've dismissed won't come back unless you restore them."
      class="mt-6"
      id="dismissed-card"
    >
      <p :if={@dismissed == []} class="border-t border-line px-5 py-4 text-sm text-muted">No dismissed channels.</p>
      <ul :if={@dismissed != []}>
        <li :for={s <- @dismissed} class="flex items-center gap-3 border-t border-line px-5 py-3" id={"dismissed-#{s.id}"}>
          <a href={s.url} target="_blank" class="min-w-0 flex-1 truncate text-sm font-medium text-fg hover:text-accent">
            {s.name || s.channel_id}
          </a>
          <span :if={s.subscriber_count} class="tabular text-xs text-muted">
            {format_count(s.subscriber_count)} subscribers
          </span>
          <button type="button" phx-click="restore_suggestion" phx-value-id={s.id} class={small_button()}>Restore</button>
        </li>
      </ul>
    </.card>
    """
  end

  defp render_page(%{page: "general"} = assigns) do
    ~H"""
    <.page_header title="General" description="Appearance, your account, and how this Pinchfork is set up." />

    <.card title="Appearance" id="appearance-card">
      <.settings_row label="Theme" help="Saved in this browser. System follows your device's light or dark setting.">
        <div
          x-data="{ theme: (() => { try { return localStorage.getItem('pf-theme') || 'system' } catch (e) { return 'system' } })() }"
          class="inline-flex rounded-lg border border-line p-0.5"
          role="radiogroup"
          aria-label="Theme"
        >
          <button
            :for={{value, label} <- [{"dark", "Dark"}, {"light", "Light"}, {"system", "System"}]}
            type="button"
            role="radio"
            x-bind:aria-checked={"theme === '#{value}'"}
            x-on:click={"theme = '#{value}'; #{set_theme_js(value)}"}
            x-bind:class={"theme === '#{value}' ? 'bg-surface-3 text-fg' : 'text-muted hover:text-fg'"}
            class="rounded-md px-3 py-1.5 text-[13px] font-semibold transition-colors"
          >
            {label}
          </button>
        </div>
      </.settings_row>
    </.card>

    <.card title="Account" class="mt-6" id="account-card">
      <.settings_row label="Signed in as" help="Lost your password? Run reset_password inside the container.">
        <span class="text-sm font-medium text-fg">{@current_user.username}</span>
      </.settings_row>
      <.settings_row label="Change password" help="You'll be signed out everywhere and asked to sign in again.">
        <form id="password-form" phx-submit="change_password" class="flex flex-col gap-3">
          <.password_field name="current_password" label="Current password" errors={@password_errors[:current_password]} />
          <.password_field
            name="password"
            label="New password"
            errors={@password_errors[:password]}
            hint="At least 12 characters."
          />
          <.password_field
            name="password_confirmation"
            label="Confirm new password"
            errors={@password_errors[:password_confirmation]}
          />
          <div>
            <button type="submit" class={small_button()} phx-disable-with="Changing…">Change password</button>
          </div>
        </form>
      </.settings_row>
    </.card>

    <.card
      title="Set by Docker"
      description="Settings that come from the container's environment. Change them in your compose file and restart."
      class="mt-6"
      id="env-card"
    >
      <dl>
        <div :for={row <- @env_rows} class="flex flex-wrap items-center gap-x-6 gap-y-1 border-t border-line px-5 py-3">
          <dt class="min-w-[220px] flex-1">
            <span class="text-sm text-fg">{row.label}</span>
            <code class="ml-2 font-mono text-xs text-muted">{row.name}</code>
          </dt>
          <dd class={["font-mono text-sm", if(row.set?, do: "text-fg", else: "text-muted")]}>{row.value}</dd>
        </div>
      </dl>
    </.card>

    <.card title="Help and diagnostics" class="mt-6" id="diagnostics-card">
      <.settings_row label="Diagnostic info" help="Versions and platform details, for bug reports.">
        <div x-data="{ copied: false }" class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            class={small_button()}
            x-on:click={"navigator.clipboard.writeText(#{Jason.encode!(@diagnostics)}).then(() => { copied = true; setTimeout(() => copied = false, 2000) })"}
          >
            <.icon name="hero-clipboard-document-mini" class="h-4 w-4" />
            <span x-text="copied ? 'Copied' : 'Copy diagnostic info'">Copy diagnostic info</span>
          </button>
          <.link href={~p"/download_logs"} class={small_button()}>
            <.icon name="hero-arrow-down-tray-mini" class="h-4 w-4" /> Download logs
          </.link>
        </div>
      </.settings_row>
      <.settings_row
        label="Setup wizard"
        help="Walk through storage, YouTube access, profiles and sources again. Nothing is deleted."
      >
        <button type="button" phx-click="rerun_setup" class={small_button()}>Run setup again</button>
      </.settings_row>
    </.card>
    """
  end

  # Page components

  attr :href, :string, required: true

  defp docs_link(assigns) do
    ~H"""
    <.link
      href={@href}
      target="_blank"
      class="inline-flex items-center gap-1 text-[13px] font-medium text-muted hover:text-fg"
    >
      Docs <.icon name="hero-arrow-top-right-on-square-mini" class="h-3.5 w-3.5" />
    </.link>
    """
  end

  attr :result, :any, required: true

  defp test_result(assigns) do
    ~H"""
    <span :if={@result == :testing} class="text-[13px] text-muted">Testing…</span>
    <span :if={match?({:ok, _}, @result)} class="inline-flex items-center gap-1 text-[13px] text-ok" role="status">
      <.icon name="hero-check-circle-mini" class="h-4 w-4" /> {elem(@result, 1)}
    </span>
    <span :if={match?({:error, _}, @result)} class="inline-flex items-center gap-1 text-[13px] text-bad" role="alert">
      <.icon name="hero-exclamation-circle-mini" class="h-4 w-4 shrink-0" /> {elem(@result, 1)}
    </span>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_errors(assigns) do
    ~H"""
    <p :for={msg <- Enum.map(@field.errors, &translate_error/1)} class="mt-1.5 text-[13px] text-bad" role="alert">
      {msg}
    </p>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true

  defp select_control(assigns) do
    ~H"""
    <div class="relative max-w-md">
      <select id={@field.id} name={@field.name} class="pf-input appearance-none pr-9">
        {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
      </select>
      <.icon
        name="hero-chevron-up-down-mini"
        class="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted"
      />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp switch(assigns) do
    assigns = assign(assigns, :checked, Phoenix.HTML.Form.normalize_value("checkbox", assigns.field.value))

    ~H"""
    <label class="relative inline-flex cursor-pointer items-center">
      <input type="hidden" name={@field.name} value="false" />
      <input
        type="checkbox"
        id={@field.id}
        name={@field.name}
        value="true"
        checked={@checked}
        role="switch"
        class="peer sr-only"
      />
      <span class="h-6 w-11 rounded-full bg-surface-3 transition-colors peer-checked:bg-accent peer-focus-visible:ring-2 peer-focus-visible:ring-accent/50">
      </span>
      <span class="absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition-transform peer-checked:translate-x-5">
      </span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :errors, :list, default: nil
  attr :hint, :string, default: nil

  defp password_field(assigns) do
    ~H"""
    <div class="max-w-sm">
      <label for={"password_#{@name}"} class="mb-1 block text-[13px] font-medium text-fg">{@label}</label>
      <input
        type="password"
        id={"password_#{@name}"}
        name={"password[#{@name}]"}
        class="pf-input"
        autocomplete={if @name == "current_password", do: "current-password", else: "new-password"}
        required
      />
      <p :if={@hint && !@errors} class="mt-1 text-xs text-muted">{@hint}</p>
      <p :for={msg <- @errors || []} class="mt-1 text-[13px] text-bad" role="alert">{msg}</p>
    </div>
    """
  end

  defp small_button do
    "inline-flex h-8 items-center gap-1.5 rounded-lg border border-line px-3 text-[13px] font-semibold text-fg hover:bg-surface-2"
  end

  # Helpers

  defp count_sources(:fast_index) do
    Repo.aggregate(from(s in Source, where: s.fast_index and is_nil(s.marked_for_deletion_at)), :count)
  end

  defp count_sources(:cookies) do
    Repo.aggregate(
      from(s in Source, where: s.cookie_behaviour != ^:disabled and is_nil(s.marked_for_deletion_at)),
      :count
    )
  end

  defp cookie_status do
    path = cookies_path()

    case File.stat(path, time: :posix) do
      {:ok, %{size: size, mtime: mtime}} when size > 0 ->
        %{
          present?: true,
          size: size,
          updated_at: DateTime.from_unix!(mtime),
          youtube?: path |> File.read!() |> String.contains?("youtube.com")
        }

      _ ->
        %{present?: false, youtube?: false}
    end
  end

  defp cookies_path do
    Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")
  end

  defp first_api_key(nil), do: nil

  defp first_api_key(keys) do
    keys
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
  end

  defp youtube_api do
    Application.get_env(:pinchflat, :youtube_api, Pinchflat.FastIndexing.YoutubeApi)
  end

  defp apprise_runner do
    Application.get_env(:pinchflat, :apprise_runner)
  end

  # pover://user_key@api_token is how Apprise spells a Pushover target
  defp parse_apprise(@pushover_prefix <> rest) do
    case String.split(rest, "@", parts: 2) do
      [user_key, api_token] -> {:pushover, user_key, api_token}
      _ -> {:pushover, "", ""}
    end
  end

  defp parse_apprise(value) when value in [nil, ""], do: {:pushover, "", ""}
  defp parse_apprise(_value), do: {:custom, "", ""}

  defp codec_options(kind, current) do
    options = if kind == :video, do: @video_codecs, else: @audio_codecs

    if current in [nil, ""] or Enum.any?(options, fn {_, value} -> value == current end) do
      options
    else
      options ++ [{"#{current} (custom value)", current}]
    end
  end

  defp opml_path do
    ~p"/sources/opml.xml?#{[route_token: Settings.get!(:route_token)]}"
  end

  # Mirrors PinchflatWeb.Plugs.maybe_basic_auth/2
  defp feed_access do
    cond do
      Application.get_env(:pinchflat, :expose_feed_endpoints) -> :open
      env_on?("BASIC_AUTH_USERNAME") and env_on?("BASIC_AUTH_PASSWORD") -> :password
      true -> :network
    end
  end

  # LOCALTEMP is only on when exactly "true" (see StagingCleaner); the rest are on when set at all
  defp env_on?("LOCALTEMP"), do: System.get_env("LOCALTEMP") == "true"
  defp env_on?(name), do: System.get_env(name, "") != ""

  defp env_rows do
    Enum.map(@env_vars, fn {name, label, default} ->
      value = System.get_env(name)

      shown =
        cond do
          value in [nil, ""] -> "#{default} (default)"
          name == "BASIC_AUTH_USERNAME" -> "set"
          true -> value
        end

      %{name: name, label: label, value: shown, set?: value not in [nil, ""]}
    end)
  end

  defp diagnostic_info do
    """
    Pinchfork #{Application.spec(:pinchflat)[:vsn]} (based on Pinchflat)
    yt-dlp: #{Settings.get!(:yt_dlp_version) || "unknown"}
    Apprise: #{Settings.get!(:apprise_version) || "unknown"}
    Elixir: #{System.version()} / OTP #{:erlang.system_info(:otp_release)}
    Architecture: #{:erlang.system_info(:system_architecture)}
    Time zone: #{Application.get_env(:pinchflat, :timezone)}
    """
    |> String.trim()
  end

  defp errors_by_field(%Ecto.Changeset{errors: errors}) do
    Enum.reduce(errors, %{}, fn {field, error}, acc ->
      Map.update(acc, field, [translate_error(error)], &(&1 ++ [translate_error(error)]))
    end)
  end

  defp set_theme_js("system") do
    "try { localStorage.removeItem('pf-theme') } catch (e) {}; " <>
      "document.documentElement.setAttribute('data-theme', " <>
      "window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')"
  end

  defp set_theme_js(theme) do
    "try { localStorage.setItem('pf-theme', '#{theme}') } catch (e) {}; " <>
      "document.documentElement.setAttribute('data-theme', '#{theme}')"
  end

  defp upload_problems(upload) do
    entry_errors = Enum.flat_map(upload.entries, &upload_errors(upload, &1))

    (upload_errors(upload) ++ entry_errors)
    |> Enum.uniq()
    |> Enum.map(fn
      :too_large -> "That file is larger than 1 MB."
      :not_accepted -> "Choose a .txt file exported from your browser."
      :too_many_files -> "Choose one file."
      other -> "Upload failed (#{other})."
    end)
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)

  defp ago(%DateTime{} = time) do
    seconds = DateTime.diff(DateTime.utc_now(), time)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      seconds < 2 * 86_400 -> "yesterday"
      seconds < 30 * 86_400 -> "#{div(seconds, 86_400)} days ago"
      true -> Calendar.strftime(time, "%-d %b %Y")
    end
  end
end
