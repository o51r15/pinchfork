defmodule PinchflatWeb.Sources.SourceNewLive do
  @moduledoc """
  Add Source, Sonarr style: paste a link, Pinchfork looks it up and fills in the name, pick a
  profile and what to download, add. Everything else gets a default and lives on the Edit page.

  Query params:
    - prefill_url / prefill_name: used by Discovery's Accept button
    - template_id: "Use as template" from another source; copies its settings
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Profiles
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source

  # Settings copied from a template source. Identity fields (URL, name, ids) never are.
  @template_fields ~w(media_profile_id fast_index index_frequency_minutes cookie_behaviour download_media
    download_cutoff_date retention_period_days title_filter_regex output_path_template_override
    min_duration_seconds max_duration_seconds download_public_videos download_members_videos client_override)a

  @impl true
  def mount(params, _session, socket) do
    profiles = Profiles.list_media_profiles() |> Enum.sort_by(& &1.id)
    template = load_template(params["template_id"])

    form_params = %{
      "url" => params["prefill_url"] || "",
      "custom_name" => params["prefill_name"] || "",
      "media_profile_id" => to_string((template && template.media_profile_id) || first_id(profiles)),
      "mode" => template_mode(template),
      "cutoff_date" => to_string((template && template.download_cutoff_date) || ""),
      "fast_index" => to_string((template && template.fast_index) || false)
    }

    socket =
      socket
      |> assign(
        page_title: "Add source",
        current_path: "/sources/new",
        profiles: profiles,
        template: template,
        has_api_key: Settings.get!(:youtube_api_key) not in [nil, ""],
        lookup: :idle,
        looked_up_url: nil,
        auto_name: nil,
        errors: %{}
      )
      |> assign_params(form_params)

    socket = if connected?(socket), do: maybe_lookup(socket, form_params["url"]), else: socket

    {:ok, socket, layout: {PinchflatWeb.Layouts, :app}}
  end

  defp assign_params(socket, params) do
    assign(socket, params: params, form: to_form(params, as: :source))
  end

  # Events

  @impl true
  def handle_event("validate", %{"source" => incoming}, socket) do
    params = Map.merge(socket.assigns.params, incoming)

    {:noreply,
     socket
     |> assign_params(params)
     |> assign(errors: %{})
     |> maybe_lookup(params["url"])}
  end

  def handle_event("set_cutoff", %{"days" => days}, socket) do
    date = Date.add(Date.utc_today(), -String.to_integer(days))
    params = Map.merge(socket.assigns.params, %{"mode" => "date", "cutoff_date" => Date.to_iso8601(date)})

    {:noreply, assign_params(socket, params)}
  end

  def handle_event("save", %{"source" => incoming}, socket) do
    params = Map.merge(socket.assigns.params, incoming)
    socket = assign_params(socket, params)

    with {:ok, attrs} <- build_attrs(params, socket.assigns.template),
         {:ok, source} <- Sources.create_source(attrs, source_details: prefetched(socket, attrs["original_url"])) do
      {:noreply,
       socket
       |> put_flash(:info, "Added #{source.custom_name}. Pinchfork is indexing it now.")
       |> push_navigate(to: ~p"/sources/#{source.id}")}
    else
      {:error, %{} = errors} when not is_struct(errors) ->
        {:noreply, assign(socket, errors: errors)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, errors: changeset_errors(changeset))}
    end
  end

  # Lookup

  defp maybe_lookup(socket, url) do
    url = String.trim(url || "")

    cond do
      url == socket.assigns.looked_up_url ->
        socket

      url == "" ->
        socket |> cancel_lookup() |> assign(lookup: :idle, looked_up_url: url)

      not Regex.match?(Source.youtube_channel_or_playlist_regex(), url) ->
        socket |> cancel_lookup() |> assign(lookup: :video_link, looked_up_url: url)

      not String.match?(url, ~r{^https?://}i) ->
        socket |> cancel_lookup() |> assign(lookup: :idle, looked_up_url: url)

      true ->
        socket
        |> cancel_lookup()
        |> assign(lookup: :loading, looked_up_url: url)
        |> start_async(:lookup, fn -> Sources.lookup_source(url) end)
    end
  end

  defp cancel_lookup(socket) do
    if socket.assigns.lookup == :loading, do: cancel_async(socket, :lookup), else: socket
  end

  @impl true
  def handle_async(:lookup, {:ok, {:ok, info}}, socket) do
    if info.url == socket.assigns.looked_up_url do
      {:noreply, socket |> assign(lookup: {:ok, info}) |> maybe_fill_name(info.name)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:lookup, {:ok, {:error, message}}, socket) do
    {:noreply, assign(socket, lookup: {:error, message})}
  end

  def handle_async(:lookup, {:exit, _reason}, socket) do
    {:noreply, assign(socket, lookup: {:error, "The lookup didn't finish."})}
  end

  # Fills the name from the lookup unless the user has typed their own
  defp maybe_fill_name(socket, name) do
    current = socket.assigns.params["custom_name"] || ""

    if current == "" or current == socket.assigns.auto_name do
      socket
      |> assign(auto_name: name)
      |> assign_params(Map.put(socket.assigns.params, "custom_name", name))
    else
      socket
    end
  end

  defp prefetched(socket, url) do
    case socket.assigns.lookup do
      {:ok, %{url: ^url} = info} -> info
      _ -> nil
    end
  end

  # Building the source

  defp build_attrs(params, template) do
    url = String.trim(params["url"] || "")

    with {:ok, mode_attrs} <- mode_attrs(params["mode"], params["cutoff_date"]),
         :ok <- require_url(url) do
      attrs =
        template_attrs(template)
        |> Map.merge(%{
          "original_url" => url,
          "custom_name" => blank_to_nil(params["custom_name"]),
          "media_profile_id" => params["media_profile_id"],
          "fast_index" => params["fast_index"] == "true"
        })
        |> Map.merge(mode_attrs)

      {:ok, attrs}
    end
  end

  defp require_url(""), do: {:error, %{url: "Paste a channel or playlist link."}}
  defp require_url(_url), do: :ok

  defp mode_attrs("new", _), do: {:ok, %{"download_media" => true, "download_cutoff_date" => Date.utc_today()}}
  defp mode_attrs("none", _), do: {:ok, %{"download_media" => false}}

  defp mode_attrs("date", date) do
    case Date.from_iso8601(date || "") do
      {:ok, date} -> {:ok, %{"download_media" => true, "download_cutoff_date" => date}}
      _ -> {:error, %{cutoff_date: "Pick a date."}}
    end
  end

  defp mode_attrs(_all, _), do: {:ok, %{"download_media" => true, "download_cutoff_date" => nil}}

  defp template_attrs(nil), do: %{}

  defp template_attrs(template) do
    template
    |> Map.take(@template_fields)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp changeset_errors(%Ecto.Changeset{errors: errors}) do
    Enum.reduce(errors, %{}, fn
      {:original_url, {"has already been taken", _}}, acc ->
        Map.put(acc, :url, "This channel or playlist is already a source with that profile.")

      {:original_url, {"could not fetch source details from URL", opts}}, acc ->
        Map.put(acc, :url, "Couldn't look that link up. #{opts[:error]}")

      {:original_url, {"must be a channel or playlist URL", _}}, acc ->
        Map.put(acc, :url, "That's a link to a single video. Paste a channel or playlist link.")

      {:original_url, error}, acc ->
        Map.put(acc, :url, "Link #{translate_error(error)}")

      {:media_profile_id, _}, acc ->
        Map.put(acc, :media_profile_id, "Pick a media profile.")

      {field, error}, acc ->
        Map.put_new(acc, :general, "#{Phoenix.Naming.humanize(field)} #{translate_error(error)}")
    end)
  end

  defp load_template(nil), do: nil
  defp load_template(""), do: nil

  defp load_template(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} -> Repo.get(Source, int_id)
      _ -> nil
    end
  end

  defp template_mode(nil), do: "all"
  defp template_mode(%{download_media: false}), do: "none"
  defp template_mode(%{download_cutoff_date: %Date{}}), do: "date"
  defp template_mode(_), do: "all"

  defp first_id([profile | _]), do: profile.id
  defp first_id(_), do: ""

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl">
      <.link navigate={~p"/sources"} class="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-fg">
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Sources
      </.link>
      <.page_header
        title="Add source"
        description="Paste a YouTube channel or playlist link. Pinchfork looks it up and fills in the rest; you can fine-tune it later from the source's Edit page."
      />

      <div :if={@template} class="mb-4 rounded-lg border border-line bg-surface-2 px-4 py-3 text-sm text-muted">
        Settings are copied from <span class="font-medium text-fg">{@template.custom_name}</span>.
      </div>

      <.card :if={@profiles == []}>
        <.empty_state
          icon="hero-adjustments-horizontal"
          title="You need a media profile first"
          description="A profile decides quality and file naming. Create one, then come back to add a source."
        >
          <:actions>
            <.link href={~p"/media_profiles/new"}><.button color="bg-primary">New profile</.button></.link>
          </:actions>
        </.empty_state>
      </.card>

      <.form :if={@profiles != []} for={@form} id="source-form" phx-change="validate" phx-submit="save" class="flex flex-col gap-6">
        <.card title="Channel or playlist">
          <div class="border-t border-line px-5 py-4">
            <label for="source_url" class="mb-1.5 block text-sm font-medium text-fg">Link</label>
            <input
              type="url"
              id="source_url"
              name="source[url]"
              value={@params["url"]}
              class="pf-input font-mono text-sm"
              placeholder="https://www.youtube.com/@channel"
              autocomplete="off"
              spellcheck="false"
              phx-debounce="400"
              autofocus
            />
            <p :if={@errors[:url]} class="mt-1.5 text-[13px] text-bad" role="alert">{@errors[:url]}</p>
            <.lookup_preview lookup={@lookup} />
          </div>
          <div class="border-t border-line px-5 py-4">
            <label for="source_custom_name" class="mb-1.5 block text-sm font-medium text-fg">Name</label>
            <input
              type="text"
              id="source_custom_name"
              name="source[custom_name]"
              value={@params["custom_name"]}
              class="pf-input"
              placeholder="Filled in from the link"
              autocomplete="off"
              phx-debounce="250"
            />
            <p class="mt-1.5 text-xs text-muted">Used for folder names and in the library. Change it if you like.</p>
          </div>
        </.card>

        <.card title="How to download it">
          <div class="border-t border-line px-5 py-4">
            <label for="source_media_profile_id" class="mb-1.5 block text-sm font-medium text-fg">Media profile</label>
            <div class="relative max-w-md">
              <select id="source_media_profile_id" name="source[media_profile_id]" class="pf-input appearance-none pr-9">
                {Phoenix.HTML.Form.options_for_select(Enum.map(@profiles, &{&1.name, &1.id}), @params["media_profile_id"])}
              </select>
              <.icon
                name="hero-chevron-up-down-mini"
                class="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted"
              />
            </div>
            <p :if={@errors[:media_profile_id]} class="mt-1.5 text-[13px] text-bad">{@errors[:media_profile_id]}</p>
          </div>

          <fieldset class="border-t border-line px-5 py-4">
            <legend class="sr-only">What to download</legend>
            <span class="mb-2 block text-sm font-medium text-fg">What to download</span>
            <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
              <label
                :for={{value, title, help} <- download_modes()}
                class="flex cursor-pointer gap-2.5 rounded-lg border border-line p-3 has-[:checked]:border-accent has-[:checked]:bg-accent-soft"
              >
                <input
                  type="radio"
                  name="source[mode]"
                  value={value}
                  checked={@params["mode"] == value}
                  class="mt-0.5 h-4 w-4 border-line bg-surface-2 text-accent focus:ring-0"
                />
                <span>
                  <span class="block text-sm font-semibold text-fg">{title}</span>
                  <span class="block text-xs text-muted">{help}</span>
                </span>
              </label>
            </div>
            <div :if={@params["mode"] == "date"} class="mt-3 flex flex-wrap items-center gap-2" id="cutoff-picker">
              <input
                type="date"
                id="source_cutoff_date"
                name="source[cutoff_date]"
                value={@params["cutoff_date"]}
                max={Date.to_iso8601(Date.utc_today())}
                class="pf-input w-44"
              />
              <button type="button" phx-click="set_cutoff" phx-value-days="30" class={small_button()}>Last 30 days</button>
              <button type="button" phx-click="set_cutoff" phx-value-days="365" class={small_button()}>Last year</button>
              <p :if={@errors[:cutoff_date]} class="w-full text-[13px] text-bad">{@errors[:cutoff_date]}</p>
            </div>
          </fieldset>

          <div class="flex flex-wrap items-start justify-between gap-4 border-t border-line px-5 py-4">
            <div class="max-w-md">
              <span class="text-sm font-medium text-fg">Fast Indexing</span>
              <p class="mt-1 text-[13px] leading-5 text-muted">
                Checks for new uploads every few minutes instead of waiting for the next full scan, which then runs monthly.
                <%= if @has_api_key do %>
                  Uses your YouTube API key.
                <% else %>
                  Uses YouTube's RSS feeds; an API key in <.link href={~p"/settings/youtube"} class="text-accent hover:underline">YouTube Access</.link> makes it more reliable.
                <% end %>
              </p>
            </div>
            <label class="relative mt-1 inline-flex cursor-pointer items-center">
              <input type="hidden" name="source[fast_index]" value="false" />
              <input
                type="checkbox"
                id="source_fast_index"
                name="source[fast_index]"
                value="true"
                checked={@params["fast_index"] == "true"}
                role="switch"
                class="peer sr-only"
              />
              <span class="h-6 w-11 rounded-full bg-surface-3 transition-colors peer-checked:bg-accent"></span>
              <span class="absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition-transform peer-checked:translate-x-5">
              </span>
            </label>
          </div>
        </.card>

        <p :if={@errors[:general]} class="text-sm text-bad" role="alert">{@errors[:general]}</p>

        <div class="flex items-center justify-end gap-2">
          <.link
            navigate={~p"/sources"}
            class="inline-flex h-10 items-center rounded-lg px-4 text-sm font-semibold text-muted hover:text-fg"
          >
            Cancel
          </.link>
          <button
            type="submit"
            phx-disable-with="Adding…"
            class="inline-flex h-10 items-center gap-1.5 rounded-lg bg-accent px-5 text-sm font-semibold text-onaccent hover:opacity-90"
          >
            <.icon name="hero-plus-mini" class="h-4 w-4" /> Add source
          </button>
        </div>
      </.form>
    </div>
    """
  end

  attr :lookup, :any, required: true

  defp lookup_preview(assigns) do
    ~H"""
    <div id="lookup-preview" class="mt-3" aria-live="polite">
      <div :if={@lookup == :loading} class="flex items-center gap-2.5 rounded-lg border border-line px-3.5 py-3 text-sm text-muted">
        <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" /> Looking it up on YouTube…
      </div>
      <div
        :if={@lookup == :video_link}
        class="flex items-center gap-2.5 rounded-lg border border-warn/40 bg-warn/10 px-3.5 py-3 text-sm text-fg"
      >
        <.icon name="hero-exclamation-triangle" class="h-4 w-4 shrink-0 text-warn" />
        That's a link to a single video. Paste the link of its channel or playlist instead.
      </div>
      <div
        :if={match?({:error, _}, @lookup)}
        class="rounded-lg border border-bad/40 bg-bad/10 px-3.5 py-3 text-sm text-fg"
      >
        <div class="flex items-center gap-2.5">
          <.icon name="hero-x-circle" class="h-4 w-4 shrink-0 text-bad" /> Couldn't find a channel or playlist at that link.
        </div>
        <p class="mt-1.5 break-words font-mono text-xs text-muted">{elem(@lookup, 1)}</p>
      </div>
      <div
        :if={match?({:ok, _}, @lookup)}
        class="flex items-center gap-3 rounded-lg border border-accent/40 bg-accent-soft px-3.5 py-3"
      >
        <span class="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-accent text-onaccent">
          <.icon name={if elem(@lookup, 1).type == :channel, do: "hero-user", else: "hero-queue-list"} class="h-5 w-5" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="truncate text-sm font-semibold text-fg">{elem(@lookup, 1).name}</div>
          <div class="truncate font-mono text-xs text-muted">{elem(@lookup, 1).id}</div>
        </div>
        <.status_chip kind={:accent}>{if elem(@lookup, 1).type == :channel, do: "Channel", else: "Playlist"}</.status_chip>
      </div>
    </div>
    """
  end

  defp download_modes do
    [
      {"all", "All videos", "Everything on the channel or playlist"},
      {"new", "New videos only", "Uploaded from today onward"},
      {"date", "From a date", "Uploaded on or after a date you pick"},
      {"none", "Nothing yet", "Index it now, choose later"}
    ]
  end

  defp small_button do
    "inline-flex h-8 items-center gap-1.5 rounded-lg border border-line px-3 text-[13px] font-semibold text-fg hover:bg-surface-2"
  end
end
