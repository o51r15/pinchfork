defmodule PinchflatWeb.MediaProfiles.MediaProfileFormLive do
  @moduledoc """
  New and Edit media profile as cards. New starts from a preset (picked server-side from
  `Presets`); Edit uses the same save model as Settings and Edit Source: checked as you type,
  a save bar once something changed, Discard to go back. The file name template shows a live
  example path built from a real video in the library.
  """

  use PinchflatWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Pinchflat.Repo
  alias Pinchflat.Profiles
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles.Presets
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Profiles.OutputPathPreview
  alias PinchflatWeb.MediaProfiles.MediaProfileHTML

  @fields ~w(name output_path_template preferred_resolution media_container shorts_behaviour
    livestream_behaviour download_subs embed_subs download_auto_subs sub_langs audio_track
    download_thumbnail embed_thumbnail download_metadata embed_metadata download_nfo
    download_source_images sponsorblock_behaviour sponsorblock_categories redownload_delay_days)a

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(current_path: "/media_profiles", submitted: false, name_touched: false)
      |> init(socket.assigns.live_action, params)

    {:ok, socket, layout: {PinchflatWeb.Layouts, :app}}
  end

  defp init(socket, :new, params) do
    {params_map, preset, copied_from} =
      case params["template_id"] && Repo.get(MediaProfile, params["template_id"]) do
        %MediaProfile{} = template -> {Map.put(params_from(template), "name", ""), nil, template.name}
        _ -> {Map.put(preset_params("default"), "name", ""), "default", nil}
      end

    socket
    |> assign(
      page_title: "New media profile",
      profile: %MediaProfile{},
      preset: preset,
      copied_from: copied_from,
      onboarding: Settings.get!(:onboarding),
      source_count: 0,
      show_advanced: uses_advanced?(params_map),
      taken_names: taken_names(nil),
      preview_video: preview_video(nil)
    )
    |> apply_params(params_map)
  end

  defp init(socket, :edit, %{"id" => id}) do
    profile = Profiles.get_media_profile!(id)

    socket
    |> assign(
      page_title: "Edit #{profile.name}",
      preset: nil,
      copied_from: nil,
      onboarding: false,
      source_count: source_count(profile),
      taken_names: taken_names(profile.id),
      preview_video: preview_video(profile.id)
    )
    |> reset(profile)
  end

  defp reset(socket, profile) do
    params_map = params_from(profile)

    socket
    |> assign(profile: profile, submitted: false, show_advanced: uses_advanced?(params_map))
    |> apply_params(params_map)
  end

  # Events

  @impl true
  def handle_event("validate", %{"media_profile" => incoming}, socket) do
    name_touched = socket.assigns.name_touched or Map.get(incoming, "name", "") != socket.assigns.params["name"]

    {:noreply,
     socket
     |> assign(name_touched: name_touched)
     |> apply_params(Map.merge(socket.assigns.params, incoming))}
  end

  def handle_event("apply_preset", %{"key" => key}, socket) do
    current_name = socket.assigns.params["name"]
    params_map = preset_params(key)

    # Keep a name the person typed; otherwise take the preset's
    params_map =
      if socket.assigns.name_touched and current_name != "",
        do: Map.put(params_map, "name", current_name),
        else: params_map

    {:noreply,
     socket
     |> assign(preset: key, copied_from: nil, show_advanced: socket.assigns.show_advanced or uses_advanced?(params_map))
     |> apply_params(params_map)}
  end

  def handle_event("use_template", %{"key" => key}, socket) do
    template = Presets.get(key).attrs.output_path_template

    {:noreply, apply_params(socket, Map.put(socket.assigns.params, "output_path_template", template))}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, update(socket, :show_advanced, &(!&1))}
  end

  def handle_event("discard", _params, socket) do
    {:noreply, reset(socket, socket.assigns.profile)}
  end

  def handle_event("save", %{"media_profile" => incoming}, socket) do
    params_map = Map.merge(socket.assigns.params, incoming)
    socket = assign(socket, submitted: true) |> apply_params(params_map)

    cond do
      not socket.assigns.changeset.valid? ->
        {:noreply, socket}

      socket.assigns.live_action == :new ->
        create(socket, params_map)

      true ->
        update_profile(socket, params_map)
    end
  end

  defp create(socket, params_map) do
    case Profiles.create_media_profile(to_attrs(params_map)) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Media profile created.")
         |> redirect(to: ~p"/media_profiles/#{profile}")}

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp update_profile(socket, params_map) do
    case Profiles.update_media_profile(socket.assigns.profile, to_attrs(params_map)) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(page_title: "Edit #{profile.name}", taken_names: taken_names(profile.id))
         |> reset(profile)
         |> put_flash(:info, "Media profile saved.")}

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, Map.put(changeset, :action, :update))}
    end
  end

  defp apply_params(socket, params_map) do
    changeset =
      socket.assigns.profile
      |> Profiles.change_media_profile(to_attrs(params_map))
      |> check_name(socket.assigns.taken_names)
      |> Map.put(:action, :validate)

    socket
    |> assign(params: params_map)
    |> assign_changeset(changeset)
    |> assign_preview(params_map)
  end

  # Errors show for what the person has changed, and for everything once they try to save,
  # so a fresh form doesn't open covered in "can't be blank"
  defp assign_changeset(socket, changeset) do
    shown = shown_errors(changeset, socket.assigns)

    assign(socket,
      changeset: changeset,
      form: to_form(%{changeset | errors: shown}, as: :media_profile),
      dirty: changeset.changes != %{}
    )
  end

  defp shown_errors(changeset, %{submitted: true}), do: changeset.errors

  defp shown_errors(changeset, assigns) do
    Enum.filter(changeset.errors, fn {field, _} ->
      Map.has_key?(changeset.changes, field) or (field == :name and assigns.name_touched)
    end)
  end

  defp check_name(changeset, taken_names) do
    name = Ecto.Changeset.get_field(changeset, :name)

    if name && String.trim(name) in taken_names,
      do: Ecto.Changeset.add_error(changeset, :name, "is already used by another profile"),
      else: changeset
  end

  defp assign_preview(socket, params_map) do
    ext = OutputPathPreview.extension(params_map["preferred_resolution"], params_map["media_container"])

    preview =
      case OutputPathPreview.build(params_map["output_path_template"], socket.assigns.preview_video, ext) do
        {:ok, path} -> Path.join(Application.get_env(:pinchflat, :media_directory), path)
        :error -> nil
      end

    assign(socket, preview: preview)
  end

  # Data

  # Profile struct -> string form params, one entry per editable field
  defp params_from(%MediaProfile{} = profile) do
    Map.new(@fields, fn field ->
      value =
        case Map.get(profile, field) do
          nil -> ""
          list when is_list(list) -> list
          other -> to_string(other)
        end

      {to_string(field), value}
    end)
  end

  defp preset_params(key), do: params_from(struct(MediaProfile, Presets.get(key).attrs))

  # The category checkboxes send a blank so that unticking all of them still reaches us
  defp to_attrs(params_map) do
    Map.update(params_map, "sponsorblock_categories", [], fn
      list when is_list(list) -> Enum.reject(list, &(&1 == ""))
      _ -> []
    end)
  end

  defp uses_advanced?(params_map) do
    params_map["redownload_delay_days"] not in [nil, ""] or params_map["audio_track"] not in [nil, ""] or
      params_map["download_auto_subs"] == "true"
  end

  defp taken_names(except_id) do
    Repo.all(
      from mp in MediaProfile,
        where: is_nil(mp.marked_for_deletion_at),
        select: {mp.id, mp.name}
    )
    |> Enum.reject(fn {id, _} -> id == except_id end)
    |> Enum.map(&elem(&1, 1))
  end

  defp source_count(profile) do
    Repo.aggregate(
      from(s in Source, where: s.media_profile_id == ^profile.id and is_nil(s.marked_for_deletion_at)),
      :count
    )
  end

  # The newest video from a source on this profile, else the newest video anywhere, else a made-up one
  defp preview_video(profile_id) do
    newest =
      from m in MediaItem,
        join: s in assoc(m, :source),
        where: is_nil(s.marked_for_deletion_at),
        order_by: [desc_nulls_last: m.uploaded_at, desc: m.id],
        limit: 1,
        preload: [source: s]

    on_profile = if profile_id, do: Repo.one(from([m, s] in newest, where: s.media_profile_id == ^profile_id))

    on_profile || Repo.one(newest) || OutputPathPreview.sample()
  end

  # Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="media-profile-form-page"
      class="mx-auto max-w-4xl"
      data-dirty={to_string(@live_action == :edit and @dirty)}
      x-data
      x-on:beforeunload.window="if ($el.dataset.dirty === 'true') { $event.preventDefault(); $event.returnValue = '' }"
    >
      <.link
        :if={@live_action == :edit}
        href={~p"/media_profiles/#{@profile}"}
        class="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-fg"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> {@profile.name}
      </.link>
      <.link
        :if={@live_action == :new and !@onboarding}
        href={~p"/media_profiles"}
        class="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-fg"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Media profiles
      </.link>
      <.page_header
        title={if @live_action == :new, do: "New media profile", else: "Edit media profile"}
        description={header_description(@live_action, @source_count)}
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

      <.card
        :if={@live_action == :new}
        title="Start from"
        description={
          if @copied_from,
            do: "Copied from \"#{@copied_from}\". Or pick a preset to start over.",
            else: "Pick the closest fit. Everything below can still be changed."
        }
        class="mb-6"
        id="preset-card"
      >
        <div class="grid grid-cols-1 gap-2 border-t border-line px-5 py-4 sm:grid-cols-2">
          <button
            :for={preset <- Presets.all()}
            type="button"
            phx-click="apply_preset"
            phx-value-key={preset.key}
            id={"preset-#{preset.key}"}
            aria-pressed={to_string(@preset == preset.key)}
            class={[
              "flex gap-3 rounded-lg border p-3 text-left transition-colors",
              if(@preset == preset.key,
                do: "border-accent bg-accent-soft",
                else: "border-line hover:bg-surface-2"
              )
            ]}
          >
            <span class={[
              "flex h-9 w-9 shrink-0 items-center justify-center rounded-lg",
              if(@preset == preset.key, do: "bg-accent text-onaccent", else: "bg-surface-2 text-muted")
            ]}>
              <.icon name={preset_icon(preset.key)} class="h-5 w-5" />
            </span>
            <span>
              <span class="block text-sm font-semibold text-fg">{preset.name}</span>
              <span class="block text-xs text-muted">{preset.summary}</span>
            </span>
          </button>
        </div>
      </.card>

      <.form for={@form} id="media-profile-form" phx-change="validate" phx-submit="save" class="flex flex-col gap-6">
        <.card title="Profile">
          <.settings_row label="Name" for="media_profile_name" help="Shown when you pick a profile for a source.">
            <input
              type="text"
              id="media_profile_name"
              name={@form[:name].name}
              value={@form[:name].value}
              class="pf-input"
              placeholder="1080p with subtitles"
              phx-debounce="250"
            />
            <.field_errors field={@form[:name]} />
          </.settings_row>
        </.card>

        <.card title="Quality">
          <.settings_row
            label="Resolution"
            for="media_profile_preferred_resolution"
            help="The best available up to this. Audio only keeps just the sound."
          >
            <.select_control field={@form[:preferred_resolution]} options={resolution_options()} />
          </.settings_row>
          <.settings_row label="File type" for="media_profile_media_container" help={container_help(@params)}>
            <.select_control field={@form[:media_container]} options={container_options(@params)} />
          </.settings_row>
          <.settings_row
            :if={@show_advanced}
            label="Audio language"
            for="media_profile_audio_track"
            help="When a video has several audio tracks, prefer this language, like de. Empty for the original."
          >
            <input
              type="text"
              id="media_profile_audio_track"
              name={@form[:audio_track].name}
              value={@form[:audio_track].value}
              class="pf-input w-32"
              placeholder="Original"
              spellcheck="false"
              phx-debounce="300"
            />
          </.settings_row>
          <.settings_row
            :if={@show_advanced}
            label="Download again after"
            for="media_profile_redownload_delay_days"
            help="Fetch each video a second time this many days after upload, to pick up better quality and newer SponsorBlock segments. Empty to download once."
          >
            <div class="flex items-center gap-2">
              <input
                type="number"
                min="0"
                id="media_profile_redownload_delay_days"
                name={@form[:redownload_delay_days].name}
                value={@form[:redownload_delay_days].value}
                class="pf-input tabular w-32"
                placeholder="Never"
                phx-debounce="300"
              />
              <span class="text-sm text-muted">days</span>
            </div>
            <.field_errors field={@form[:redownload_delay_days]} />
          </.settings_row>
        </.card>

        <.card title="What to include">
          <.settings_row
            label="Shorts"
            for="media_profile_shorts_behaviour"
            help="Found while indexing, so skipping them doesn't make indexing faster."
          >
            <.select_control field={@form[:shorts_behaviour]} options={include_options("shorts")} />
          </.settings_row>
          <.settings_row label="Livestreams" for="media_profile_livestream_behaviour" help="Past livestreams and premieres.">
            <.select_control field={@form[:livestream_behaviour]} options={include_options("livestreams")} />
          </.settings_row>
        </.card>

        <.card title="Subtitles">
          <.settings_row label="Save subtitles" for="media_profile_download_subs" help="As .srt files next to the video.">
            <.switch field={@form[:download_subs]} />
          </.settings_row>
          <.settings_row
            label="Embed subtitles"
            for="media_profile_embed_subs"
            help="Built into the video file. Ignored for audio only."
          >
            <.switch field={@form[:embed_subs]} />
          </.settings_row>
          <.settings_row
            label="Languages"
            for="media_profile_sub_langs"
            help="Comma-separated codes like en,de, or all for every language."
          >
            <input
              type="text"
              id="media_profile_sub_langs"
              name={@form[:sub_langs].name}
              value={@form[:sub_langs].value}
              class="pf-input w-48 font-mono text-sm"
              placeholder="en"
              spellcheck="false"
              phx-debounce="300"
            />
          </.settings_row>
          <.settings_row
            :if={@show_advanced}
            label="Automatic captions"
            for="media_profile_download_auto_subs"
            help="Use YouTube's auto-generated captions when a video has no real subtitles."
          >
            <.switch field={@form[:download_auto_subs]} />
          </.settings_row>
        </.card>

        <.card title="Artwork and metadata">
          <.settings_row label="Save thumbnail" for="media_profile_download_thumbnail" help="As an image next to the video.">
            <.switch field={@form[:download_thumbnail]} />
          </.settings_row>
          <.settings_row label="Embed thumbnail" for="media_profile_embed_thumbnail" help="Used as the file's cover art.">
            <.switch field={@form[:embed_thumbnail]} />
          </.settings_row>
          <.settings_row
            label="Embed metadata"
            for="media_profile_embed_metadata"
            help="Title, date and description inside the file."
          >
            <.switch field={@form[:embed_metadata]} />
          </.settings_row>
          <.settings_row
            label="Save metadata file"
            for="media_profile_download_metadata"
            help="An .info.json with everything YouTube knows about the video."
          >
            <.switch field={@form[:download_metadata]} />
          </.settings_row>
          <.settings_row
            label="NFO files"
            for="media_profile_download_nfo"
            help="Episode details for Jellyfin, Plex and Kodi."
          >
            <.switch field={@form[:download_nfo]} />
          </.settings_row>
          <.settings_row
            label="Series artwork"
            for="media_profile_download_source_images"
            help="The channel's poster and banner in the show folder."
          >
            <.switch field={@form[:download_source_images]} />
          </.settings_row>
        </.card>

        <.card title="SponsorBlock" description="Community-submitted segments like sponsor reads and intros.">
          <:actions>
            <.link
              href="https://sponsor.ajay.app/"
              target="_blank"
              class="inline-flex items-center gap-1 text-[13px] font-medium text-muted hover:text-fg"
            >
              About <.icon name="hero-arrow-top-right-on-square-mini" class="h-3.5 w-3.5" />
            </.link>
          </:actions>
          <.settings_row label="Segments" for="media_profile_sponsorblock_behaviour">
            <.select_control field={@form[:sponsorblock_behaviour]} options={sponsorblock_options()} />
          </.settings_row>
          <.settings_row
            :if={@params["sponsorblock_behaviour"] != "disabled"}
            label="Categories"
            help={
              if @params["sponsorblock_behaviour"] == "remove",
                do: "These are cut out of the file.",
                else: "These become chapters you can skip."
            }
          >
            <input type="hidden" name="media_profile[sponsorblock_categories][]" value="" />
            <div class="flex flex-wrap gap-2" id="sponsorblock-categories">
              <label
                :for={{label, value} <- MediaProfileHTML.frieldly_sponsorblock_categories()}
                class="flex cursor-pointer items-center gap-2 rounded-lg border border-line px-3 py-1.5 text-sm has-[:checked]:border-accent has-[:checked]:bg-accent-soft"
              >
                <input
                  type="checkbox"
                  name="media_profile[sponsorblock_categories][]"
                  value={value}
                  checked={value in List.wrap(@params["sponsorblock_categories"])}
                  class="h-4 w-4 rounded border-line bg-surface-2 text-accent focus:ring-0"
                />
                <span class="font-medium text-fg">{label}</span>
              </label>
            </div>
            <p
              :if={to_attrs(@params)["sponsorblock_categories"] == []}
              class="mt-1.5 text-[13px] text-warn"
              id="sponsorblock-none"
            >
              No categories picked, so SponsorBlock does nothing yet.
            </p>
          </.settings_row>
        </.card>

        <.card title="File naming" description="Where each download goes, inside your downloads folder." id="naming-card">
          <div class="flex flex-col gap-3 border-t border-line px-5 py-4">
            <label for="media_profile_output_path_template" class="text-sm font-medium text-fg">Template</label>
            <input
              type="text"
              id="media_profile_output_path_template"
              name={@form[:output_path_template].name}
              value={@form[:output_path_template].value}
              class="pf-input font-mono text-xs"
              spellcheck="false"
              phx-debounce="300"
            />
            <.field_errors field={@form[:output_path_template]} />
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-[13px] text-muted">Start from:</span>
              <button
                :for={
                  {key, label} <- [
                    {"default", "Folder per video"},
                    {"media_center", "TV seasons"},
                    {"audio", "Music by artist"}
                  ]
                }
                type="button"
                phx-click="use_template"
                phx-value-key={key}
                class={small_button()}
              >
                {label}
              </button>
            </div>
            <div class="rounded-lg bg-surface-2 px-4 py-3" id="path-preview">
              <p class="text-xs font-medium text-muted">{preview_label(@preview_video)}</p>
              <p :if={@preview} class="mt-1 break-all font-mono text-[13px] text-fg">{@preview}</p>
              <p :if={!@preview} class="mt-1 text-[13px] text-muted">Can't read this template yet.</p>
              <p class="mt-1.5 text-xs text-muted">
                Fields shown as ‹name› are filled in by yt-dlp when the video downloads.
              </p>
            </div>
            <details class="group text-sm">
              <summary class="cursor-pointer select-none font-medium text-muted hover:text-fg">
                Template fields and syntax
              </summary>
              <div class="mt-3 text-fg">
                <MediaProfileHTML.output_template_help />
              </div>
            </details>
          </div>
        </.card>

        <div :if={@live_action == :new} class="flex items-center justify-end gap-2">
          <.link
            navigate={~p"/media_profiles"}
            class="inline-flex h-10 items-center rounded-lg px-4 text-sm font-semibold text-muted hover:text-fg"
          >
            Cancel
          </.link>
          <button
            type="submit"
            phx-disable-with="Creating…"
            class="inline-flex h-10 items-center gap-1.5 rounded-lg bg-accent px-5 text-sm font-semibold text-onaccent hover:bg-accent/90"
          >
            <.icon name="hero-plus-mini" class="h-4 w-4" /> Create profile
          </button>
        </div>
      </.form>

      <.card :if={@live_action == :edit} title="Delete profile" class="mt-6" id="danger-card">
        <div
          :if={@source_count > 0}
          class="flex flex-wrap items-center justify-between gap-4 border-t border-line px-5 py-4"
        >
          <p class="max-w-lg text-sm text-muted">{in_use_text(@source_count)}</p>
          <.link href={~p"/media_profiles/#{@profile}"} class={small_button()}>See sources</.link>
        </div>
        <div
          :if={@source_count == 0}
          class="flex flex-wrap items-center justify-between gap-4 border-t border-line px-5 py-4"
        >
          <p class="max-w-lg text-sm text-muted">No sources use this profile, so it can be deleted.</p>
          <.link
            href={~p"/media_profiles/#{@profile}"}
            method="delete"
            data-confirm="Delete this media profile? This cannot be undone."
            class="inline-flex h-9 items-center rounded-lg bg-bad px-4 text-sm font-semibold text-[#ffffff] hover:bg-bad/90"
          >
            Delete profile
          </.link>
        </div>
      </.card>

      <.save_bar :if={@live_action == :edit} form="media-profile-form" dirty={@dirty} />
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

  defp header_description(:new, _count), do: "A set of download settings you can give to any number of sources."
  defp header_description(:edit, 0), do: "No sources use this profile yet."
  defp header_description(:edit, 1), do: "Changes apply to new downloads for the 1 source using this profile."

  defp header_description(:edit, count),
    do: "Changes apply to new downloads for the #{count} sources using this profile."

  defp in_use_text(1), do: "1 source uses this profile. Move it to another profile or delete it first."
  defp in_use_text(count), do: "#{count} sources use this profile. Move them to another profile or delete them first."

  defp preset_icon("default"), do: "hero-play-circle"
  defp preset_icon("media_center"), do: "hero-tv"
  defp preset_icon("audio"), do: "hero-musical-note"
  defp preset_icon("archiving"), do: "hero-archive-box"
  defp preset_icon(_), do: "hero-adjustments-horizontal"

  defp preview_label(%MediaItem{title: title}), do: "Example, using \"#{title}\""
  defp preview_label(_), do: "Example, using a made-up video"

  defp resolution_options do
    [
      {"8K (4320p)", "4320p"},
      {"4K (2160p)", "2160p"},
      {"1440p", "1440p"},
      {"1080p", "1080p"},
      {"720p", "720p"},
      {"480p", "480p"},
      {"360p", "360p"},
      {"Audio only", "audio"}
    ]
  end

  defp container_options(params) do
    known =
      if params["preferred_resolution"] == "audio",
        do: [{"Best available (default)", ""}, {"m4a", "m4a"}, {"mp3", "mp3"}, {"opus", "opus"}, {"flac", "flac"}],
        else: [{"mp4 (default)", ""}, {"mp4", "mp4"}, {"mkv", "mkv"}, {"webm", "webm"}]

    current = params["media_container"]

    if current in [nil, "" | Enum.map(known, &elem(&1, 1))],
      do: known,
      else: known ++ [{"#{current} (custom)", current}]
  end

  defp container_help(%{"preferred_resolution" => "audio"}),
    do: "Converted to this after downloading. Best available keeps YouTube's original audio."

  defp container_help(_params), do: "mp4 plays almost everywhere. mkv holds more kinds of subtitles and audio."

  defp include_options(kind) do
    [{"Include", "include"}, {"Skip", "exclude"}, {"Only #{kind}", "only"}]
  end

  defp sponsorblock_options do
    [{"Leave as is", "disabled"}, {"Mark as chapters", "mark"}, {"Cut out of the file", "remove"}]
  end
end
