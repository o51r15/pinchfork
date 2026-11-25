defmodule PinchflatWeb.Sources.SourceEditLive do
  @moduledoc """
  Edit Source as cards, on the same save model as Settings: checked as you type, a save bar
  once something changed, Discard to go back. The everyday settings are always shown; filters,
  files and YouTube access sit behind "Show advanced" (open by default when the source already
  uses any of them).
  """

  use PinchflatWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Profiles
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias PinchflatWeb.Sources.SourceHTML

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    source = Sources.get_source!(id)

    {:ok,
     socket
     |> assign(
       page_title: "Edit #{source.custom_name}",
       current_path: "/sources",
       profiles: Profiles.list_media_profiles() |> Enum.sort_by(& &1.id),
       has_api_key: Settings.get!(:youtube_api_key) not in [nil, ""],
       show_advanced: uses_advanced?(source)
     )
     |> reset(source), layout: {PinchflatWeb.Layouts, :app}}
  end

  defp reset(socket, source) do
    params = %{
      "cutoff_mode" => if(source.download_cutoff_date, do: "date", else: "all"),
      "min_duration" => format_duration(source.min_duration_seconds),
      "max_duration" => format_duration(source.max_duration_seconds)
    }

    socket
    |> assign(source: source, params: params, duration_errors: %{}, regex_matches: nil)
    |> assign_changeset(Sources.change_source(source, %{}))
    |> count_regex_matches(source.title_filter_regex)
  end

  defp assign_changeset(socket, changeset) do
    # Durations become *_seconds changes, so a typed duration shows up here too; a duration that
    # can't be read yet counts as a change so the bar stays up while it's being fixed
    dirty = changeset.changes != %{} or socket.assigns.duration_errors != %{}

    assign(socket, changeset: changeset, form: to_form(changeset, as: :source), dirty: dirty)
  end

  # Events

  @impl true
  def handle_event("validate", %{"source" => incoming}, socket) do
    {:noreply, apply_params(socket, Map.merge(socket.assigns.params, incoming))}
  end

  def handle_event("set_cutoff", %{"days" => days}, socket) do
    date = Date.add(Date.utc_today(), -String.to_integer(days))

    params =
      Map.merge(socket.assigns.params, %{"cutoff_mode" => "date", "download_cutoff_date" => Date.to_iso8601(date)})

    {:noreply, apply_params(socket, params)}
  end

  def handle_event("use_profile_template", _params, socket) do
    profile_id = Phoenix.HTML.Form.input_value(socket.assigns.form, :media_profile_id)

    template =
      Enum.find_value(
        socket.assigns.profiles,
        "",
        &(to_string(&1.id) == to_string(profile_id) && &1.output_path_template)
      )

    {:noreply, apply_params(socket, Map.put(socket.assigns.params, "output_path_template_override", template))}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, update(socket, :show_advanced, &(!&1))}
  end

  def handle_event("discard", _params, socket) do
    {:noreply, reset(socket, socket.assigns.source)}
  end

  def handle_event("save", %{"source" => incoming}, socket) do
    params = Map.merge(socket.assigns.params, incoming)
    {attrs, duration_errors} = to_attrs(params)

    if duration_errors != %{} do
      {:noreply, apply_params(socket, params)}
    else
      case Sources.update_source(socket.assigns.source, attrs) do
        {:ok, source} ->
          source = Sources.get_source!(source.id)

          {:noreply,
           socket
           |> assign(page_title: "Edit #{source.custom_name}")
           |> reset(source)
           |> put_flash(:info, "Source saved.")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> assign(params: params, duration_errors: %{})
           |> assign_changeset(Map.put(changeset, :action, :update))}
      end
    end
  end

  defp apply_params(socket, params) do
    {attrs, duration_errors} = to_attrs(params)

    changeset =
      socket.assigns.source
      |> Sources.change_source(attrs)
      |> Map.put(:action, :validate)

    socket
    |> assign(params: params, duration_errors: duration_errors)
    |> assign_changeset(changeset)
    |> count_regex_matches(if(changeset.errors[:title_filter_regex], do: nil, else: attrs["title_filter_regex"]))
  end

  # Form params -> source attrs. Durations are typed as m:ss and stored as seconds.
  defp to_attrs(params) do
    {min, min_error} = parse_duration(params["min_duration"])
    {max, max_error} = parse_duration(params["max_duration"])

    attrs =
      params
      |> Map.drop(["cutoff_mode", "min_duration", "max_duration"])
      |> Map.put("min_duration_seconds", min)
      |> Map.put("max_duration_seconds", max)
      |> then(fn attrs ->
        if params["cutoff_mode"] == "all", do: Map.put(attrs, "download_cutoff_date", nil), else: attrs
      end)

    errors =
      %{}
      |> then(&if(min_error, do: Map.put(&1, :min_duration, min_error), else: &1))
      |> then(&if(max_error, do: Map.put(&1, :max_duration, max_error), else: &1))

    {attrs, errors}
  end

  defp count_regex_matches(socket, regex) when regex in [nil, ""], do: assign(socket, regex_matches: nil)

  defp count_regex_matches(socket, regex) do
    source_id = socket.assigns.source.id

    {total, matching} =
      Repo.one(
        from m in MediaItem,
          where: m.source_id == ^source_id,
          select: {count(m.id), count(fragment("CASE WHEN ? ~ ? THEN 1 END", m.title, ^regex))}
      )

    assign(socket, regex_matches: {matching, total})
  rescue
    _ -> assign(socket, regex_matches: nil)
  end

  # Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="source-edit-page"
      class="mx-auto max-w-4xl"
      data-dirty={to_string(@dirty)}
      x-data
      x-on:beforeunload.window="if ($el.dataset.dirty === 'true') { $event.preventDefault(); $event.returnValue = '' }"
    >
      <.link
        href={~p"/sources/#{@source.id}"}
        class="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-fg"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> {@source.custom_name}
      </.link>
      <.page_header
        title="Edit source"
        description="Changes to what's downloaded apply to new downloads and the next index."
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

      <.form for={@form} id="source-form" phx-change="validate" phx-submit="save" class="flex flex-col gap-6">
        <.card title="Basics">
          <.settings_row label="Name" for="source_custom_name" help="Used for folder names and in the library.">
            <input
              type="text"
              id="source_custom_name"
              name={@form[:custom_name].name}
              value={@form[:custom_name].value}
              class="pf-input"
              phx-debounce="250"
            />
            <.field_errors field={@form[:custom_name]} />
          </.settings_row>
          <.settings_row
            label="Link"
            for="source_original_url"
            help={"#{type_label(@source.collection_type)}. Changing the link looks it up again when you save."}
          >
            <input
              type="url"
              id="source_original_url"
              name={@form[:original_url].name}
              value={@form[:original_url].value}
              class="pf-input font-mono text-sm"
              spellcheck="false"
              phx-debounce="400"
            />
            <.field_errors field={@form[:original_url]} />
          </.settings_row>
          <.settings_row label="Media profile" for="source_media_profile_id" help="Quality, subtitles and file naming.">
            <.select_control field={@form[:media_profile_id]} options={Enum.map(@profiles, &{&1.name, &1.id})} />
          </.settings_row>
          <.settings_row
            label="Monitored"
            for="source_download_media"
            help="When off, Pinchfork keeps indexing but downloads nothing new."
          >
            <.switch field={@form[:download_media]} />
          </.settings_row>
        </.card>

        <.card title="What to download">
          <.settings_row label="Videos from" help="Older videos are indexed but not downloaded.">
            <div class="flex flex-wrap gap-2" role="radiogroup">
              <label
                :for={{value, label} <- [{"all", "Any date"}, {"date", "On or after a date"}]}
                class="flex cursor-pointer items-center gap-2 rounded-lg border border-line px-3 py-2 text-sm has-[:checked]:border-accent has-[:checked]:bg-accent-soft"
              >
                <input
                  type="radio"
                  name="source[cutoff_mode]"
                  value={value}
                  checked={@params["cutoff_mode"] == value}
                  class="h-4 w-4 border-line bg-surface-2 text-accent focus:ring-0"
                />
                <span class="font-medium text-fg">{label}</span>
              </label>
            </div>
            <div :if={@params["cutoff_mode"] == "date"} class="mt-3 flex flex-wrap items-center gap-2">
              <input
                type="date"
                id="source_download_cutoff_date"
                name={@form[:download_cutoff_date].name}
                value={@form[:download_cutoff_date].value}
                max={Date.to_iso8601(Date.utc_today())}
                class="pf-input w-44"
              />
              <button type="button" phx-click="set_cutoff" phx-value-days="30" class={small_button()}>Last 30 days</button>
              <button type="button" phx-click="set_cutoff" phx-value-days="365" class={small_button()}>Last year</button>
            </div>
            <.field_errors field={@form[:download_cutoff_date]} />
          </.settings_row>
          <.settings_row label="Public videos" for="source_download_public_videos" help="Normal videos anyone can watch.">
            <.switch field={@form[:download_public_videos]} />
          </.settings_row>
          <.settings_row
            label="Members-only videos"
            for="source_download_members_videos"
            help="Needs a cookies file from an account that's a member (Settings › YouTube Access)."
          >
            <.switch field={@form[:download_members_videos]} />
          </.settings_row>
        </.card>

        <.card title="Checking for new videos">
          <.settings_row label="Fast Indexing" for="source_fast_index" help={fast_index_help(@has_api_key)}>
            <.switch field={@form[:fast_index]} />
          </.settings_row>
          <.settings_row
            label="Full scan"
            for="source_index_frequency_minutes"
            help={
              if fast_index_on?(@form),
                do: "Monthly while Fast Indexing is on: Fast Indexing finds new uploads in between.",
                else: "How often Pinchfork reads the whole channel or playlist. Default: daily."
            }
          >
            <.select_control
              :if={!fast_index_on?(@form)}
              field={@form[:index_frequency_minutes]}
              options={SourceHTML.friendly_index_frequencies()}
            />
            <span :if={fast_index_on?(@form)} class="text-sm text-muted">Monthly</span>
          </.settings_row>
        </.card>

        <.card
          :if={@show_advanced}
          title="Filters"
          description="Only videos that pass every filter are downloaded."
          id="filters-card"
        >
          <.settings_row
            label="Shortest video"
            for="source_min_duration"
            help="Skip anything shorter. Minutes and seconds, like 1:30. Empty for no limit."
          >
            <input
              type="text"
              id="source_min_duration"
              name="source[min_duration]"
              value={@params["min_duration"]}
              class="pf-input tabular w-32"
              placeholder="m:ss"
              phx-debounce="300"
            />
            <p :if={@duration_errors[:min_duration]} class="mt-1.5 text-[13px] text-bad">
              {@duration_errors[:min_duration]}
            </p>
          </.settings_row>
          <.settings_row
            label="Longest video"
            for="source_max_duration"
            help="Skip anything longer. Like 45:00 or 1:30:00. Empty for no limit."
          >
            <input
              type="text"
              id="source_max_duration"
              name="source[max_duration]"
              value={@params["max_duration"]}
              class="pf-input tabular w-32"
              placeholder="m:ss"
              phx-debounce="300"
            />
            <p :if={@duration_errors[:max_duration]} class="mt-1.5 text-[13px] text-bad">
              {@duration_errors[:max_duration]}
            </p>
            <.field_errors field={@form[:max_duration_seconds]} />
          </.settings_row>
          <.settings_row
            label="Title must match"
            for="source_title_filter_regex"
            help="A regular expression. Case-sensitive unless it starts with (?i)."
          >
            <input
              type="text"
              id="source_title_filter_regex"
              name={@form[:title_filter_regex].name}
              value={@form[:title_filter_regex].value}
              class="pf-input font-mono text-sm"
              placeholder="(?i)tutorial"
              spellcheck="false"
              phx-debounce="400"
            />
            <.field_errors field={@form[:title_filter_regex]} />
            <p :if={@regex_matches} class="mt-1.5 text-[13px] text-muted" id="regex-matches">
              Matches <span class="tabular font-medium text-fg">{elem(@regex_matches, 0)}</span>
              of {elem(@regex_matches, 1)} indexed videos.
            </p>
          </.settings_row>
        </.card>

        <.card :if={@show_advanced} title="Files" id="files-card">
          <.settings_row
            label="Keep downloads for"
            for="source_retention_period_days"
            help="Delete downloaded files after this many days. Empty to keep them forever."
          >
            <div class="flex items-center gap-2">
              <input
                type="number"
                min="0"
                id="source_retention_period_days"
                name={@form[:retention_period_days].name}
                value={@form[:retention_period_days].value}
                class="pf-input tabular w-32"
                placeholder="Forever"
                phx-debounce="300"
              />
              <span class="text-sm text-muted">days</span>
            </div>
            <.field_errors field={@form[:retention_period_days]} />
          </.settings_row>
          <.settings_row
            label="File name template"
            for="source_output_path_template_override"
            help="Overrides the profile's template for this source only. Must end with .{{ ext }}. Empty to use the profile's."
          >
            <input
              type="text"
              id="source_output_path_template_override"
              name={@form[:output_path_template_override].name}
              value={@form[:output_path_template_override].value}
              class="pf-input font-mono text-xs"
              placeholder={profile_template(@profiles, @form)}
              spellcheck="false"
              phx-debounce="400"
            />
            <.field_errors field={@form[:output_path_template_override]} />
            <button type="button" phx-click="use_profile_template" class={[small_button(), "mt-2"]}>
              Start from the profile's template
            </button>
          </.settings_row>
        </.card>

        <.card :if={@show_advanced} title="YouTube access" id="access-card">
          <:actions>
            <.link
              href="https://github.com/o51r15/pinchfork/wiki/SABR-Bypass-and-PO-Tokens"
              target="_blank"
              class="inline-flex items-center gap-1 text-[13px] font-medium text-muted hover:text-fg"
            >
              Docs <.icon name="hero-arrow-top-right-on-square-mini" class="h-3.5 w-3.5" />
            </.link>
          </:actions>
          <.settings_row
            label="Use cookies"
            for="source_cookie_behaviour"
            help="The cookies file is in Settings › YouTube Access."
          >
            <.select_control field={@form[:cookie_behaviour]} options={cookie_options()} />
          </.settings_row>
          <.settings_row
            label="Video client"
            for="source_client_override"
            help="Change it only when downloads fail. Automatic works for most sources."
          >
            <.select_control field={@form[:client_override]} options={client_options(@form[:client_override].value)} />
            <.field_errors field={@form[:client_override]} />
          </.settings_row>
        </.card>

        <%!-- Hidden advanced values ride along so validation and saving still see them --%>
        <div :if={!@show_advanced} class="hidden">
          <input type="hidden" name="source[min_duration]" value={@params["min_duration"]} />
          <input type="hidden" name="source[max_duration]" value={@params["max_duration"]} />
          <input
            :for={field <- advanced_fields()}
            type="hidden"
            name={@form[field].name}
            value={hidden_value(@form[field].value)}
          />
        </div>
      </.form>

      <.card title="Delete source" class="mt-6" id="danger-card">
        <div class="flex flex-wrap items-center justify-between gap-4 border-t border-line px-5 py-4">
          <p class="max-w-lg text-sm text-muted">Removes the source and its index. Downloaded files stay on disk.</p>
          <.link
            href={~p"/sources/#{@source.id}"}
            method="delete"
            data-confirm="Delete this source? Downloaded files stay on disk. This cannot be undone."
            class="inline-flex h-9 items-center rounded-lg border border-bad/40 px-4 text-sm font-semibold text-bad hover:bg-bad/10"
          >
            Delete source
          </.link>
        </div>
        <div class="flex flex-wrap items-center justify-between gap-4 border-t border-line px-5 py-4">
          <p class="max-w-lg text-sm text-muted">Removes the source and permanently deletes its downloaded files.</p>
          <.link
            href={~p"/sources/#{@source.id}?delete_files=true"}
            method="delete"
            data-confirm="Delete this source AND its downloaded files? This cannot be undone."
            class="inline-flex h-9 items-center rounded-lg bg-bad px-4 text-sm font-semibold text-[#ffffff] hover:bg-bad/90"
          >
            Delete source and files
          </.link>
        </div>
      </.card>

      <.save_bar form="source-form" dirty={@dirty} />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_errors(assigns) do
    ~H"""
    <p :for={msg <- Enum.map(@field.errors, &translate_error/1)} class="mt-1.5 text-[13px] text-bad" role="alert">{msg}</p>
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
      <span class="absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-[#ffffff] shadow transition-transform peer-checked:translate-x-5">
      </span>
    </label>
    """
  end

  # Helpers

  defp small_button do
    "inline-flex h-8 items-center gap-1.5 rounded-lg border border-line px-3 text-[13px] font-semibold text-fg hover:bg-surface-2"
  end

  defp advanced_fields,
    do: ~w(title_filter_regex retention_period_days output_path_template_override cookie_behaviour client_override)a

  defp hidden_value(nil), do: ""
  defp hidden_value(value), do: to_string(value)

  defp uses_advanced?(%Source{} = s) do
    Enum.any?([
      s.min_duration_seconds,
      s.max_duration_seconds,
      s.title_filter_regex,
      s.retention_period_days,
      s.output_path_template_override,
      s.client_override
    ]) or
      s.cookie_behaviour != :disabled
  end

  defp fast_index_on?(form), do: Phoenix.HTML.Form.normalize_value("checkbox", form[:fast_index].value)

  defp fast_index_help(true), do: "Checks for new uploads every few minutes using your YouTube API key."

  defp fast_index_help(false),
    do:
      "Checks for new uploads every few minutes using YouTube's RSS feeds. An API key in Settings › YouTube Access makes it more reliable."

  defp type_label(:playlist), do: "A playlist"
  defp type_label(_), do: "A channel"

  defp profile_template(profiles, form) do
    id = to_string(form[:media_profile_id].value)
    Enum.find_value(profiles, "", &(to_string(&1.id) == id && &1.output_path_template))
  end

  defp cookie_options do
    [
      {"Never", :disabled},
      {"Only when a video needs them", :when_needed},
      {"For everything, including indexing", :all_operations}
    ]
  end

  defp client_options(current) do
    known = [
      {"Automatic (recommended)", ""},
      {"Compatible with cookies (web_creator, tv)", "web_creator,tv"},
      {"No cookies, no token (android_vr)", "android_vr"},
      {"Other clients",
       [
         {"tv: works with cookies", "tv"},
         {"web_safari: works with cookies, needs the token server", "web_safari"},
         {"mweb: works with cookies, needs the token server", "mweb"},
         {"web: works with cookies, needs the token server", "web"},
         {"android: no cookies, needs the token server", "android"},
         {"ios: no cookies", "ios"},
         {"tv_simply: no cookies, needs the token server", "tv_simply"}
       ]}
    ]

    values = ["", "web_creator,tv", "android_vr", "tv", "web_safari", "mweb", "web", "android", "ios", "tv_simply"]

    if current in [nil | values], do: known, else: known ++ [{"#{current} (custom)", current}]
  end

  defp format_duration(nil), do: ""

  defp format_duration(seconds) do
    {h, rest} = {div(seconds, 3600), rem(seconds, 3600)}
    {m, s} = {div(rest, 60), rem(rest, 60)}
    pad = &String.pad_leading(to_string(&1), 2, "0")

    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end

  # Accepts "90" (seconds), "1:30", "1:02:03". Returns {seconds | nil, error | nil}
  defp parse_duration(value) do
    trimmed = String.trim(value || "")

    parts =
      trimmed
      |> String.split(":")
      |> Enum.map(&Integer.parse/1)

    cond do
      trimmed == "" -> {nil, nil}
      Enum.all?(parts, &match?({_, ""}, &1)) and length(parts) <= 3 -> {to_seconds(Enum.map(parts, &elem(&1, 0))), nil}
      true -> {nil, "Use minutes and seconds, like 1:30."}
    end
  end

  defp to_seconds(parts), do: Enum.reduce(parts, 0, fn part, acc -> acc * 60 + part end)
end
