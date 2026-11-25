defmodule PinchflatWeb.System.BackupLive do
  @moduledoc """
  Upload a backup (/system/backup/upload) and restore one (/system/backup/:filename/restore).

  Uploads come in over the LiveView socket in chunks, only for signed-in users, so the plain
  request size limit (which applies before sign-in) stays small. An upload is saved into the
  backups folder and then opened here for restoring, like any other backup.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Backups
  alias Pinchflat.Backups.Restore
  alias PinchflatWeb.System.SystemHTML

  @max_upload_bytes 2_000_000_000

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(current_path: "/system/backup", dir_status: Backups.directory_status())
      |> init(socket.assigns.live_action, params)

    {:ok, socket, layout: {PinchflatWeb.Layouts, :app}}
  end

  defp init(socket, :upload, _params) do
    socket
    |> assign(page_title: "Upload a backup", upload_error: nil)
    |> allow_upload(:backup, accept: ~w(.gz), max_entries: 1, max_file_size: @max_upload_bytes)
  end

  defp init(socket, :restore, %{"filename" => filename}) do
    case Backups.backup_path(filename) do
      nil ->
        socket
        |> put_flash(:error, "That backup isn't there any more.")
        |> push_navigate(to: ~p"/system/backup")

      path ->
        stat = File.stat!(path)

        socket
        |> assign(
          page_title: "Restore a backup",
          filename: Path.basename(path),
          path: path,
          size: stat.size,
          inspected: nil,
          confirm: "",
          phase: :confirm,
          step: nil,
          result: nil
        )
        |> then(fn socket ->
          if connected?(socket), do: start_async(socket, :inspect, fn -> Restore.inspect_backup(path) end), else: socket
        end)
    end
  end

  # Upload

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, assign(socket, upload_error: nil)}

  def handle_event("save_upload", _params, socket) do
    results =
      consume_uploaded_entries(socket, :backup, fn %{path: tmp}, entry ->
        {:ok, save_upload(tmp, entry.client_name)}
      end)

    case results do
      [{:ok, filename}] ->
        {:noreply,
         socket
         |> put_flash(:info, "Uploaded #{filename}.")
         |> push_navigate(to: ~p"/system/backup/#{filename}/restore")}

      [{:error, message}] ->
        {:noreply, assign(socket, upload_error: message)}

      [] ->
        {:noreply, assign(socket, upload_error: "Choose a backup file first.")}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket), do: {:noreply, cancel_upload(socket, :backup, ref)}

  # Restore

  def handle_event("confirm_change", %{"confirm" => confirm}, socket), do: {:noreply, assign(socket, confirm: confirm)}

  def handle_event("restore", %{"confirm" => "RESTORE"}, %{assigns: %{phase: :confirm}} = socket) do
    pid = self()
    path = socket.assigns.path

    {:noreply,
     socket
     |> assign(phase: :running, step: :checking)
     |> start_async(:restore, fn -> restorer().restore(path, notify: &send(pid, {:restore_step, &1})) end)}
  end

  def handle_event("restore", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:restore_step, step}, socket), do: {:noreply, assign(socket, step: step)}

  @impl true
  def handle_async(:inspect, {:ok, result}, socket), do: {:noreply, assign(socket, inspected: result)}

  def handle_async(:inspect, {:exit, _}, socket),
    do: {:noreply, assign(socket, inspected: {:error, "The backup couldn't be read."})}

  # Pinchfork restarts a few seconds after a restore, so the browser moves to a plain page that
  # waits for it to come back; this LiveView would otherwise reconnect into its confirm form
  def handle_async(:restore, {:ok, {:ok, info}}, socket) do
    query = [restored: socket.assigns.filename, safety: info.safety_backup, warning: info[:warning] || ""]

    {:noreply, socket |> assign(phase: :done, result: {:ok, info}) |> redirect(to: ~p"/system/restarting?#{query}")}
  end

  def handle_async(:restore, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, phase: :failed, result: {:error, message})}

  def handle_async(:restore, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, phase: :failed, result: {:error, "The restore stopped unexpectedly: #{inspect(reason)}"})}

  # Tests swap in a fake: a real restore would replace the test database
  defp restorer, do: Application.get_env(:pinchflat, :backup_restorer, Restore)

  # Saves an upload into the backups folder. Keeps the uploaded name when it's a plain
  # backup-looking name that isn't taken; otherwise gives it a dated one.
  defp save_upload(tmp, client_name) do
    with :ok <- writable(),
         {:ok, _} <- Restore.inspect_backup(tmp) do
      name = upload_name(client_name)
      File.cp!(tmp, Path.join(Backups.backup_dir(), name))
      {:ok, name}
    end
  end

  defp writable do
    if Backups.directory_status() == :ok,
      do: :ok,
      else:
        {:error,
         "Pinchfork can't write to #{Backups.backup_dir()}, so the upload can't be kept. See the note on the Backup page."}
  end

  defp upload_name(client_name) do
    base = Path.basename(client_name)

    if Regex.match?(~r/\A[\w.\-]+\.sql\.gz\z/, base) and Backups.backup_path(base) == nil do
      base
    else
      "pinchfork-backup-uploaded-#{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H-%M-%S")}.sql.gz"
    end
  end

  # Rendering

  @impl true
  def render(%{live_action: :upload} = assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl">
      <.link href={~p"/system/backup"} class="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-fg">
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Backup
      </.link>
      <.page_header
        title="Upload a backup"
        description="A .sql.gz backup from Pinchfork, for example from another machine. It's added to your backups, then you choose whether to restore it."
      />

      <.dir_warning :if={@dir_status != :ok} />

      <form id="upload-form" phx-change="validate_upload" phx-submit="save_upload" class="pf-card p-5">
        <label
          for={@uploads.backup.ref}
          phx-drop-target={@uploads.backup.ref}
          class="flex cursor-pointer flex-col items-center gap-2 rounded-lg border-2 border-dashed border-line px-6 py-10 text-center hover:border-accent hover:bg-surface-2"
        >
          <.icon name="hero-arrow-up-tray" class="h-8 w-8 text-muted" />
          <span class="text-sm font-semibold text-fg">Drop a backup here, or click to choose one</span>
          <span class="text-xs text-muted">A .sql.gz file made by Pinchfork's Backup page</span>
          <.live_file_input upload={@uploads.backup} class="sr-only" />
        </label>

        <div :for={entry <- @uploads.backup.entries} class="mt-4 flex items-center gap-3" id={"upload-entry-#{entry.ref}"}>
          <.icon name="hero-document" class="h-5 w-5 shrink-0 text-muted" />
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-medium text-fg">{entry.client_name}</p>
            <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-surface-3">
              <div class="h-full rounded-full bg-accent transition-all" style={"width: #{entry.progress}%"}></div>
            </div>
            <p :for={err <- upload_errors(@uploads.backup, entry)} class="mt-1 text-[13px] text-bad">
              {upload_error_text(err)}
            </p>
          </div>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            class="text-sm text-muted hover:text-fg"
            aria-label="Remove"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>
        <p :for={err <- upload_errors(@uploads.backup)} class="mt-3 text-[13px] text-bad">{upload_error_text(err)}</p>
        <p :if={@upload_error} class="mt-3 text-[13px] text-bad" id="upload-error">{@upload_error}</p>

        <div class="mt-5 flex justify-end">
          <button
            type="submit"
            disabled={@uploads.backup.entries == [] or @dir_status != :ok}
            phx-disable-with="Checking…"
            class="inline-flex h-10 items-center gap-1.5 rounded-lg bg-accent px-5 text-sm font-semibold text-onaccent hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <.icon name="hero-arrow-up-tray-mini" class="h-4 w-4" /> Upload
          </button>
        </div>
      </form>
    </div>
    """
  end

  def render(%{live_action: :restore} = assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl">
      <.link href={~p"/system/backup"} class="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-fg">
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Backup
      </.link>
      <.page_header
        title="Restore a backup"
        description="Replaces everything in Pinchfork's database with this backup. Downloaded files aren't touched."
      />

      <.card title="Backup" id="restore-backup">
        <dl class="divide-y divide-line border-t border-line text-sm">
          <div class="flex flex-wrap justify-between gap-x-4 gap-y-1 px-5 py-2.5">
            <dt class="text-muted">File</dt>
            <dd class="break-all font-mono text-xs text-fg">{@filename}</dd>
          </div>
          <div class="flex justify-between gap-4 px-5 py-2.5">
            <dt class="text-muted">Size</dt>
            <dd class="text-fg">{SystemHTML.human_bytes(@size)}</dd>
          </div>
          <div class="flex flex-wrap justify-between gap-x-4 gap-y-1 px-5 py-2.5" id="restore-check">
            <dt class="text-muted">Check</dt>
            <dd class="text-right text-fg">
              <span :if={@inspected == nil} class="inline-flex items-center gap-1.5 text-muted">
                <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" /> Reading the backup…
              </span>
              <span :if={match?({:ok, %{newer_than_app: false}}, @inspected)} class="text-ok">
                {version_text(@inspected)}
              </span>
              <span :if={match?({:ok, %{newer_than_app: true}}, @inspected)} class="text-bad">
                Made by a newer version of Pinchfork. Update Pinchfork first, then restore it.
              </span>
              <span :if={match?({:error, _}, @inspected)} class="text-bad">{elem(@inspected, 1)}</span>
            </dd>
          </div>
        </dl>
      </.card>

      <.dir_warning :if={@dir_status != :ok and @phase == :confirm} />

      <.card :if={@phase == :confirm} title="What happens" class="mt-6" id="restore-confirm">
        <ol class="flex list-decimal flex-col gap-1.5 border-t border-line py-4 pl-10 pr-5 text-sm text-fg">
          <li>Pinchfork backs up the current database first, so you can go back.</li>
          <li>Background jobs pause. If downloads are running, it waits up to 30 seconds for them.</li>
          <li>
            The database is replaced in one step. If anything goes wrong, nothing changes.
          </li>
          <li>Pinchfork restarts to finish up. It takes about half a minute; the page waits for it.</li>
          <li>
            Your sign-in comes from the backup too, so you may need to sign in again, with the password you had then.
          </li>
          <li>Videos downloaded since the backup stay on disk, but Pinchfork may download them again.</li>
        </ol>
        <form
          id="restore-form"
          phx-change="confirm_change"
          phx-submit="restore"
          class="flex flex-wrap items-end gap-3 border-t border-line px-5 py-4"
        >
          <label class="min-w-[220px] flex-1">
            <span class="mb-1.5 block text-sm font-medium text-fg">Type RESTORE to confirm</span>
            <input
              type="text"
              name="confirm"
              value={@confirm}
              autocomplete="off"
              spellcheck="false"
              class="pf-input font-mono"
              id="restore-confirm-input"
            />
          </label>
          <button
            type="submit"
            disabled={!ready?(assigns)}
            class="inline-flex h-10 items-center gap-1.5 rounded-lg bg-bad px-5 text-sm font-semibold text-[#ffffff] hover:bg-bad/90 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <.icon name="hero-arrow-uturn-left-mini" class="h-4 w-4" /> Restore this backup
          </button>
        </form>
      </.card>

      <.card :if={@phase in [:running, :failed]} title="Restoring" class="mt-6" id="restore-progress">
        <ul class="flex flex-col gap-2.5 border-t border-line px-5 py-4 text-sm">
          <li :for={{step, label} <- Restore.steps()} class="flex items-center gap-2.5">
            <.step_icon state={step_state(step, @step, @phase)} />
            <span class={if step_state(step, @step, @phase) == :pending, do: "text-muted", else: "text-fg"}>{label}</span>
          </li>
        </ul>
        <p :if={@phase == :running} class="border-t border-line px-5 py-3 text-[13px] text-muted">
          Keep this page open until it finishes. Large libraries can take a few minutes.
        </p>
      </.card>

      <div :if={@phase == :failed} class="pf-card mt-6 flex gap-3 border-bad/40 px-5 py-4" id="restore-failed">
        <.icon name="hero-exclamation-circle" class="mt-0.5 h-5 w-5 shrink-0 text-bad" />
        <div class="min-w-0 text-sm text-fg">
          <p class="font-semibold">The restore didn't happen</p>
          <p class="mt-1 break-words">{elem(@result, 1)}</p>
        </div>
      </div>

      <div :if={@phase == :done} class="pf-card mt-6 flex gap-3 border-ok/40 px-5 py-4" id="restore-done">
        <.icon name="hero-check-circle" class="mt-0.5 h-5 w-5 shrink-0 text-ok" />
        <p class="text-sm text-fg">Restored. Pinchfork is restarting…</p>
      </div>
    </div>
    """
  end

  defp dir_warning(assigns) do
    ~H"""
    <div class="pf-card mb-6 mt-6 flex gap-3 border-bad/40 px-5 py-4" id="dir-warning">
      <.icon name="hero-exclamation-triangle" class="mt-0.5 h-5 w-5 shrink-0 text-bad" />
      <p class="text-sm text-fg">
        Pinchfork can't write to its backups folder, so it can't keep uploads or make the safety backup a restore needs.
        <.link href={~p"/system/backup"} class="font-medium text-accent hover:underline">The Backup page</.link>
        says how to fix it.
      </p>
    </div>
    """
  end

  attr :state, :atom, required: true

  defp step_icon(assigns) do
    ~H"""
    <.icon :if={@state == :done} name="hero-check-circle-mini" class="h-5 w-5 text-ok" />
    <.icon :if={@state == :current} name="hero-arrow-path-mini" class="h-5 w-5 animate-spin text-accent" />
    <.icon :if={@state == :failed} name="hero-x-circle-mini" class="h-5 w-5 text-bad" />
    <span :if={@state == :pending} class="mx-1 block h-3 w-3 rounded-full border-2 border-line"></span>
    """
  end

  defp step_state(step, current, phase) do
    keys = Keyword.keys(Restore.steps())
    index = Enum.find_index(keys, &(&1 == step))
    current_index = Enum.find_index(keys, &(&1 == current)) || 0

    cond do
      index < current_index -> :done
      index == current_index and phase == :failed -> :failed
      index == current_index -> :current
      true -> :pending
    end
  end

  defp ready?(assigns) do
    assigns.confirm == "RESTORE" and assigns.dir_status == :ok and
      match?({:ok, %{newer_than_app: false}}, assigns.inspected)
  end

  defp version_text({:ok, %{latest_migration: same, app_migration: same}}),
    do: "Made by this version of Pinchfork. Ready to restore."

  defp version_text({:ok, _}),
    do: "Made by an older version of Pinchfork. It's updated after restoring."

  defp upload_error_text(:too_large), do: "That file is bigger than 2 GB."
  defp upload_error_text(:not_accepted), do: "That isn't a .sql.gz backup."
  defp upload_error_text(:too_many_files), do: "One backup at a time."
  defp upload_error_text(other), do: "That upload didn't work (#{other})."
end
