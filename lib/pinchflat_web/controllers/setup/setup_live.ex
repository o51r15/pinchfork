defmodule PinchflatWeb.Setup.SetupLive do
  @moduledoc """
  Steps 2 to 6 of the setup wizard: storage check, YouTube access, first media profile,
  first source, done. Step 1 (the account) is `PinchflatWeb.Setup.SetupController`.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Profiles
  alias Pinchflat.Profiles.Presets
  alias Pinchflat.Utils.FilesystemUtils
  alias PinchflatWeb.UserAuth

  @steps ~w(storage youtube profile source done)
  @cookie_max_bytes 1_000_000

  @impl true
  def mount(params, _session, socket) do
    # "done" is allowed after setup finishes, because reaching it is what finishes setup
    if UserAuth.setup_in_progress?() or params["step"] == "done" do
      {:ok,
       socket
       |> assign(page_title: "Set up Pinchfork", preset: "default", source_error: nil, saved_key: false)
       |> allow_upload(:cookies, accept: ~w(.txt), max_entries: 1, max_file_size: @cookie_max_bytes),
       layout: {PinchflatWeb.Layouts, :auth}}
    else
      {:ok, push_navigate(socket, to: ~p"/sources"), layout: {PinchflatWeb.Layouts, :auth}}
    end
  end

  @impl true
  def handle_params(%{"step" => step}, _uri, socket) when step in @steps do
    {:noreply, socket |> assign(:step, step) |> load_step(step)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, push_patch(socket, to: ~p"/setup/storage")}
  end

  defp load_step(socket, "storage"), do: assign(socket, :checks, storage_checks())

  defp load_step(socket, "youtube") do
    assign(socket,
      api_key: Settings.get!(:youtube_api_key) || "",
      cookies_present: FilesystemUtils.exists_and_nonempty?(cookies_path())
    )
  end

  defp load_step(socket, "profile") do
    assign(socket, presets: Presets.all(), existing_profiles: Profiles.list_media_profiles())
  end

  defp load_step(socket, "source") do
    profiles = Profiles.list_media_profiles()

    assign(socket,
      profiles: profiles,
      source_form: to_form(%{"url" => "", "media_profile_id" => first_id(profiles), "mode" => "all"}, as: :source)
    )
  end

  defp load_step(socket, "done") do
    Settings.set(onboarding: false)
    assign(socket, source_count: Repo.aggregate(Pinchflat.Sources.Source, :count, :id))
  end

  # Events

  @impl true
  def handle_event("save_youtube", %{"youtube" => %{"api_key" => key}}, socket) do
    Settings.set(youtube_api_key: blank_to_nil(key))

    consume_uploaded_entries(socket, :cookies, fn %{path: path}, _entry ->
      {:ok, FilesystemUtils.cp_p!(path, cookies_path())}
    end)

    {:noreply, push_patch(socket, to: ~p"/setup/profile")}
  end

  def handle_event("validate_youtube", _params, socket), do: {:noreply, socket}

  def handle_event("pick_preset", %{"key" => key}, socket) do
    {:noreply, assign(socket, :preset, key)}
  end

  def handle_event("create_profile", _params, socket) do
    preset = Presets.get(socket.assigns.preset) || Presets.get("default")

    case Profiles.create_media_profile(unique_name(preset.attrs)) do
      {:ok, _profile} ->
        {:noreply, push_patch(socket, to: ~p"/setup/source")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That profile couldn't be created. Try another preset.")}
    end
  end

  def handle_event("create_source", %{"source" => params}, socket) do
    attrs =
      %{
        "original_url" => String.trim(params["url"] || ""),
        "media_profile_id" => params["media_profile_id"]
      }
      |> Map.merge(download_mode_attrs(params["mode"]))

    case Sources.create_source(attrs) do
      {:ok, _source} ->
        {:noreply, push_patch(socket, to: ~p"/setup/done")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           source_error: first_error(changeset),
           source_form: to_form(params, as: :source)
         )}
    end
  end

  # Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <.setup_steps current={step_index(@step)} />
    <section class="pf-card mt-5 flex flex-col p-7">
      {render_step(assigns)}
    </section>
    """
  end

  defp render_step(%{step: "storage"} = assigns) do
    ~H"""
    <h1 class="text-[22px] font-semibold tracking-tight text-fg">Storage check</h1>
    <p class="mt-1.5 text-sm leading-6 text-muted">
      Pinchfork checked the folders it was given in Docker.
    </p>
    <ul class="mt-5 flex flex-col gap-2.5">
      <li :for={check <- @checks} class="flex items-center gap-3 rounded-lg border border-line px-3.5 py-3">
        <span class={[
          "grid h-6 w-6 shrink-0 place-items-center rounded-full",
          if(check.ok, do: "bg-ok/15 text-ok", else: "bg-bad/15 text-bad")
        ]}>
          <.icon name={if check.ok, do: "hero-check-mini", else: "hero-x-mark-mini"} class="h-4 w-4" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="text-sm font-medium text-fg">{check.name}</div>
          <div class="truncate font-mono text-xs text-muted">{check.path}</div>
        </div>
        <span class={["text-right text-[13px]", if(check.ok, do: "text-ok", else: "text-bad")]}>
          {check.result}
        </span>
      </li>
    </ul>
    <p :if={Enum.any?(@checks, &(!&1.ok))} class="mt-4 text-[13px] leading-5 text-muted">
      Fix the folder mapping or permissions in your Docker setup, restart the container, then <.link
        patch={~p"/setup/storage"}
        class="text-accent hover:underline"
      >check again</.link>.
    </p>
    <.step_nav next={~p"/setup/youtube"} />
    """
  end

  defp render_step(%{step: "youtube"} = assigns) do
    ~H"""
    <h1 class="text-[22px] font-semibold tracking-tight text-fg">YouTube access</h1>
    <p class="mt-1.5 text-sm leading-6 text-muted">
      Both are optional. You can add or change them later in Settings.
    </p>
    <.form for={%{}} as={:youtube} phx-change="validate_youtube" phx-submit="save_youtube" class="flex flex-col">
      <.input
        name="youtube[api_key]"
        id="youtube_api_key"
        value={@api_key}
        type="text"
        label="YouTube API key"
        placeholder="Paste a key to turn on Fast Indexing"
        help="Lets Pinchfork check for new videos every few minutes instead of every few hours."
        autocomplete="off"
        inputclass="font-mono"
      />

      <span class="mt-5 mb-1.5 text-sm font-medium text-fg">Cookies</span>
      <div class="flex flex-wrap items-center gap-3 rounded-lg border border-dashed border-line px-3.5 py-3">
        <span class="flex-1 text-[13px] text-muted">
          <%= cond do %>
            <% @uploads.cookies.entries != [] -> %>
              {hd(@uploads.cookies.entries).client_name} is ready to save
            <% @cookies_present -> %>
              A cookies file is already saved
            <% true -> %>
              Only needed for members-only or age-restricted videos.
          <% end %>
        </span>
        <label class="inline-flex h-9 cursor-pointer items-center rounded-lg border border-line px-3 text-sm font-semibold text-fg hover:bg-surface-2">
          Choose cookies.txt <.live_file_input upload={@uploads.cookies} class="sr-only" />
        </label>
      </div>
      <p :for={err <- cookie_upload_errors(@uploads.cookies)} class="mt-2 text-sm text-bad">
        {upload_error_text(err)}
      </p>

      <.step_nav back={~p"/setup/storage"} skip={~p"/setup/profile"} submit_label="Save and continue" />
    </.form>
    """
  end

  defp render_step(%{step: "profile"} = assigns) do
    ~H"""
    <h1 class="text-[22px] font-semibold tracking-tight text-fg">Pick a starting profile</h1>
    <p class="mt-1.5 text-sm leading-6 text-muted">
      A profile decides video quality, subtitles and how files are named. You can fine-tune it later.
    </p>
    <p :if={@existing_profiles != []} class="mt-3 text-[13px] text-muted">
      You already have {length(@existing_profiles)} profile(s). You can add another or skip this step.
    </p>
    <div class="mt-5 grid grid-cols-1 gap-2.5 sm:grid-cols-2" role="radiogroup" aria-label="Profile presets">
      <button
        :for={preset <- @presets}
        type="button"
        role="radio"
        aria-checked={to_string(preset.key == @preset)}
        phx-click="pick_preset"
        phx-value-key={preset.key}
        class={[
          "rounded-xl border p-4 text-left transition-colors",
          if(preset.key == @preset, do: "border-accent bg-accent-soft", else: "border-line hover:bg-surface-2")
        ]}
      >
        <span class="block text-sm font-semibold text-fg">{preset.name}</span>
        <span class="mt-1 block text-xs leading-5 text-muted">{preset.summary}</span>
      </button>
    </div>
    <div class="mt-7 flex items-center gap-2">
      <.link
        patch={~p"/setup/youtube"}
        class="inline-flex h-10 items-center rounded-lg border border-line px-4 text-sm font-semibold text-fg hover:bg-surface-2"
      >
        Back
      </.link>
      <span class="flex-1"></span>
      <.link
        :if={@existing_profiles != []}
        patch={~p"/setup/source"}
        class="px-3 text-sm font-semibold text-muted hover:text-fg"
      >
        Skip
      </.link>
      <.button type="button" phx-click="create_profile" phx-disable-with="Creating…">Create profile</.button>
    </div>
    """
  end

  defp render_step(%{step: "source"} = assigns) do
    ~H"""
    <h1 class="text-[22px] font-semibold tracking-tight text-fg">Add your first source</h1>
    <p class="mt-1.5 text-sm leading-6 text-muted">
      Paste a YouTube channel or playlist link. You can add more any time.
    </p>
    <div :if={@profiles == []} class="mt-5 rounded-lg border border-line bg-surface-2 p-4 text-sm text-muted">
      You need a media profile first. <.link patch={~p"/setup/profile"} class="text-accent hover:underline">Create one</.link>.
    </div>
    <.form :if={@profiles != []} for={@source_form} phx-submit="create_source" class="flex flex-col">
      <.input
        field={@source_form[:url]}
        type="text"
        label="Channel or playlist URL"
        placeholder="https://www.youtube.com/@channel"
        inputclass="font-mono"
        required
      />
      <p :if={@source_error} role="alert" class="mt-2 text-sm text-bad">{@source_error}</p>
      <.input
        field={@source_form[:media_profile_id]}
        type="select"
        label="Media profile"
        options={Enum.map(@profiles, &{&1.name, &1.id})}
      />
      <fieldset class="mt-5">
        <legend class="mb-2 text-sm font-medium text-fg">What to download</legend>
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-3">
          <label
            :for={{value, title, help} <- download_modes()}
            class="flex cursor-pointer gap-2.5 rounded-lg border border-line p-3 has-[:checked]:border-accent has-[:checked]:bg-accent-soft"
          >
            <input
              type="radio"
              name="source[mode]"
              value={value}
              checked={@source_form[:mode].value == value}
              class="mt-0.5 h-4 w-4 border-line bg-surface-2 text-accent focus:ring-0"
            />
            <span>
              <span class="block text-sm font-semibold text-fg">{title}</span>
              <span class="block text-xs text-muted">{help}</span>
            </span>
          </label>
        </div>
      </fieldset>
      <.step_nav back={~p"/setup/profile"} skip={~p"/setup/done"} submit_label="Add source" submit_busy="Looking it up…" />
    </.form>
    """
  end

  defp render_step(%{step: "done"} = assigns) do
    ~H"""
    <div class="flex flex-col items-center py-4 text-center">
      <span class="grid h-14 w-14 place-items-center rounded-full bg-accent-soft">
        <.icon name="hero-check" class="h-7 w-7 text-accent" />
      </span>
      <h1 class="mt-4 text-[22px] font-semibold tracking-tight text-fg">You're all set</h1>
      <p class="mt-1.5 max-w-sm text-sm leading-6 text-muted">
        <%= if @source_count > 0 do %>
          Pinchfork is indexing your sources now. Large channels can take a few hours the first time.
        <% else %>
          Add a channel or playlist from the Sources page whenever you're ready.
        <% end %>
      </p>
      <.link
        navigate={~p"/sources"}
        class="mt-6 inline-flex h-10 items-center rounded-lg bg-accent px-5 text-sm font-semibold text-onaccent hover:opacity-90"
      >
        Go to Sources
      </.link>
    </div>
    """
  end

  attr :back, :string, default: nil
  attr :skip, :string, default: nil
  attr :next, :string, default: nil
  attr :submit_label, :string, default: nil
  attr :submit_busy, :string, default: "Saving…"

  defp step_nav(assigns) do
    ~H"""
    <div class="mt-7 flex items-center gap-2">
      <.link
        :if={@back}
        patch={@back}
        class="inline-flex h-10 items-center rounded-lg border border-line px-4 text-sm font-semibold text-fg hover:bg-surface-2"
      >
        Back
      </.link>
      <span class="flex-1"></span>
      <.link :if={@skip} patch={@skip} class="px-3 text-sm font-semibold text-muted hover:text-fg">Skip</.link>
      <.link
        :if={@next}
        patch={@next}
        class="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-onaccent hover:opacity-90"
      >
        Continue
      </.link>
      <.button :if={@submit_label} phx-disable-with={@submit_busy}>{@submit_label}</.button>
    </div>
    """
  end

  # Helpers

  defp step_index(step), do: Enum.find_index(@steps, &(&1 == step)) + 1

  defp download_modes do
    [
      {"all", "All videos", "Everything on the channel"},
      {"new", "New only", "From today onward"},
      {"none", "Nothing yet", "Index now, choose later"}
    ]
  end

  defp download_mode_attrs("new"), do: %{"download_media" => "true", "download_cutoff_date" => Date.utc_today()}
  defp download_mode_attrs("none"), do: %{"download_media" => "false"}
  defp download_mode_attrs(_), do: %{"download_media" => "true"}

  defp first_id([profile | _]), do: profile.id
  defp first_id(_), do: nil

  # Profile names are free text, but two "Default"s would be confusing in menus
  defp unique_name(%{name: name} = attrs) do
    taken = MapSet.new(Profiles.list_media_profiles(), & &1.name)

    if MapSet.member?(taken, name) do
      suffix = Enum.find(2..99, &(not MapSet.member?(taken, "#{name} #{&1}")))
      %{attrs | name: "#{name} #{suffix}"}
    else
      attrs
    end
  end

  defp first_error(%Ecto.Changeset{errors: errors}) do
    case errors do
      [{:original_url, {msg, _}} | _] -> "Channel or playlist URL #{msg}"
      [{field, {msg, _}} | _] -> "#{Phoenix.Naming.humanize(field)} #{msg}"
      [] -> "That source couldn't be added."
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp cookie_upload_errors(upload) do
    entry_errors = Enum.flat_map(upload.entries, &upload_errors(upload, &1))
    Enum.uniq(upload_errors(upload) ++ entry_errors)
  end

  defp upload_error_text(:too_large), do: "That file is larger than 1 MB."
  defp upload_error_text(:not_accepted), do: "Choose a .txt file exported from your browser."
  defp upload_error_text(:too_many_files), do: "Choose one file."
  defp upload_error_text(other), do: "Upload failed (#{other})."

  defp cookies_path do
    Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")
  end

  defp storage_checks do
    [
      {"Downloads folder", Application.get_env(:pinchflat, :media_directory)},
      {"Metadata folder", Application.get_env(:pinchflat, :metadata_directory)},
      {"Config folder", Application.get_env(:pinchflat, :extras_directory)}
    ]
    |> Enum.reject(fn {_, path} -> is_nil(path) end)
    |> Enum.map(fn {name, path} -> check_dir(name, path) end)
  end

  defp check_dir(name, path) do
    case FilesystemUtils.write_p(Path.join(path, ".pinchfork-write-test"), "") do
      :ok ->
        File.rm(Path.join(path, ".pinchfork-write-test"))
        %{name: name, path: path, ok: true, result: free_space(path) || "Writable"}

      {:error, reason} ->
        %{name: name, path: path, ok: false, result: "Not writable (#{reason})"}
    end
  end

  defp free_space(path) do
    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} ->
        with [_header, line | _] <- String.split(output, "\n", trim: true),
             [_, _, _, avail_kb | _] <- String.split(line),
             {kb, ""} <- Integer.parse(avail_kb) do
          "Writable · #{human_size(kb * 1024)} free"
        else
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp human_size(bytes) when bytes >= 1_000_000_000_000, do: "#{Float.round(bytes / 1_000_000_000_000, 1)} TB"
  defp human_size(bytes) when bytes >= 1_000_000_000, do: "#{Float.round(bytes / 1_000_000_000, 1)} GB"
  defp human_size(bytes), do: "#{div(bytes, 1_000_000)} MB"
end
