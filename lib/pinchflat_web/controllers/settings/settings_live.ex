defmodule PinchflatWeb.Settings.SettingsLive do
  @moduledoc """
  The redesigned Settings area: one LiveView, one page per `:page` param. Every page shares the
  same layout and save model: edits are checked as you type, a save bar appears once something
  has changed, and saving writes only that page's own fields.

  Pages move here one at a time as they are rebuilt. Until then the old SettingController page
  at /settings ("General" in the sidebar) still holds the rest.
  """

  use PinchflatWeb, :live_view

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.YtDlp.PoTokenServer

  @pages %{
    "youtube" => %{title: "YouTube Access", fields: [:youtube_api_key]}
  }

  @cookie_max_bytes 1_000_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(api_key_test: nil, po_status: :checking, po_test: nil)
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
    {:noreply,
     socket
     |> assign(page: page, page_title: @pages[page].title, current_path: "/settings/#{page}")
     |> reset_form()
     |> load_page(page)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, push_navigate(socket, to: ~p"/settings/youtube")}
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

  # Form and save model

  defp reset_form(socket) do
    setting = Settings.record()

    socket
    |> assign(:setting, setting)
    |> assign_form(Settings.change_setting(setting))
  end

  defp assign_form(socket, changeset) do
    fields = @pages[socket.assigns.page].fields
    dirty = Enum.any?(fields, &Map.has_key?(changeset.changes, &1))

    assign(socket, form: to_form(changeset, as: :setting), dirty: dirty)
  end

  # Only the current page's fields are accepted, so a page can never save another page's values
  defp page_params(socket, params) do
    allowed = Enum.map(@pages[socket.assigns.page].fields, &to_string/1)
    Map.take(params, allowed)
  end

  # Events

  @impl true
  def handle_event("validate", %{"setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Settings.change_setting(page_params(socket, params))
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign_form(changeset) |> assign(api_key_test: nil)}
  end

  def handle_event("save", %{"setting" => params}, socket) do
    case Settings.update_setting(socket.assigns.setting, page_params(socket, params)) do
      {:ok, _setting} ->
        {:noreply, socket |> reset_form() |> put_flash(:info, "Settings saved.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :update))}
    end
  end

  def handle_event("discard", _params, socket) do
    {:noreply, socket |> reset_form() |> assign(api_key_test: nil)}
  end

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

  def handle_async(:po_test, {:exit, _reason}, socket) do
    {:noreply, assign(socket, po_test: {:error, "The test didn't finish. Try again."})}
  end

  def handle_async(:api_key_test, {:ok, :ok}, socket), do: {:noreply, assign(socket, api_key_test: {:ok, "Key works"})}

  def handle_async(:api_key_test, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, api_key_test: {:error, to_string(reason)})}
  end

  def handle_async(:api_key_test, {:exit, _reason}, socket) do
    {:noreply, assign(socket, api_key_test: {:error, "The test didn't finish. Try again."})}
  end

  # Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="settings-page"
      data-dirty={to_string(@dirty)}
      x-data
      x-on:beforeunload.window="if ($el.dataset.dirty === 'true') { $event.preventDefault(); $event.returnValue = '' }"
    >
      {render_page(assigns)}
      <.save_bar form="settings-form" dirty={@dirty} />
    </div>
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
      <.settings_row
        label="cookies.txt"
        help="Export it in Netscape format from a browser that's signed in to YouTube."
      >
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
