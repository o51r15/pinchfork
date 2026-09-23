defmodule PinchflatWeb.Discovery.DiscoveryLive do
  use PinchflatWeb, :live_view

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.ScanWorker

  @display_count 10

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pinchflat.PubSub, "discovery:scan")
    end

    scanning = scan_running?()

    {:ok,
     socket
     |> assign(:current_path, "/discovery")
     |> assign(:scanning, scanning)
     |> assign(:scan_result, nil)
     |> load_suggestions(), layout: {PinchflatWeb.Layouts, :app}}
  end

  @impl true
  def handle_info({:scan_complete, result}, socket) do
    {flash_type, message} =
      case result do
        %{error: error} -> {:error, "Scan failed: #{error}"}
        %{persisted: persisted} -> {:info, "Scan complete — #{persisted} suggestions updated."}
      end

    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:scan_result, result)
     |> put_flash(flash_type, message)
     |> load_suggestions()}
  end

  @impl true
  def handle_event("scan", _params, socket) do
    case ScanWorker.new(%{}) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        # A scan is already queued or running — its completion broadcast will clear the spinner.
        {:noreply,
         socket
         |> assign(:scanning, true)
         |> put_flash(:info, "A scan is already running. This page will update when it finishes.")}

      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:scanning, true)
         |> put_flash(:info, "Discovery scan started. This may take a few minutes.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to start scan.")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:scan_result, nil)
     |> load_suggestions()}
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    # Status is NOT changed here: the suggestion flips to "accepted" only once a source for the
    # channel actually exists (Discovery.reconcile_with_sources/0). Backing out of the source
    # form therefore leaves it pending instead of hiding it forever.
    case Discovery.get_suggestion(id) do
      %{} = suggestion ->
        {:noreply,
         socket
         |> put_flash(:info, "Create a source for #{suggestion.name || suggestion.channel_id} below.")
         |> redirect(
           to: ~p"/sources/new?prefill_url=#{suggestion.url}&prefill_name=#{suggestion.name || ""}&prefill_type=channel"
         )}

      nil ->
        {:noreply, socket |> put_flash(:error, "That suggestion is no longer available.") |> load_suggestions()}
    end
  end

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    with %{} = suggestion <- Discovery.get_suggestion(id),
         {:ok, _} <- Discovery.dismiss_suggestion(suggestion) do
      {:noreply, load_suggestions(socket)}
    else
      _ -> {:noreply, socket |> put_flash(:error, "That suggestion is no longer available.") |> load_suggestions()}
    end
  end

  defp load_suggestions(socket) do
    Discovery.reconcile_with_sources()
    suggestions = Discovery.list_random_suggestions(@display_count)
    pending_count = Discovery.pending_suggestion_count()
    settings = Discovery.discovery_settings()
    assign(socket, suggestions: suggestions, pending_count: pending_count, discovery_enabled: settings.enabled)
  end

  defp scan_running? do
    import Ecto.Query

    Pinchflat.Repo.exists?(
      from(j in Oban.Job,
        where: j.worker == "Pinchflat.Discovery.ScanWorker",
        where: fragment("?::text", j.state) in ["available", "executing", "scheduled"]
      )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-4 flex gap-3 flex-row items-center justify-between">
      <div>
        <h2 class="text-title-md2 font-bold text-black dark:text-white">Discovery</h2>
        <p :if={@pending_count > 0} class="text-sm text-bodydark2 mt-1">
          Showing {length(@suggestions)} of {@pending_count} suggestions
        </p>
      </div>
      <div class="flex gap-2">
        <button
          phx-click="refresh"
          class="inline-flex items-center gap-1 rounded-md bg-meta-3/10 px-3 py-1.5 text-sm font-medium text-meta-3 hover:bg-meta-3/20"
        >
          <.icon name="hero-arrow-path" class="h-4 w-4" /> Refresh
        </button>
        <button
          :if={@discovery_enabled}
          phx-click="scan"
          disabled={@scanning}
          class={[
            "inline-flex items-center gap-1 rounded-md px-4 py-1.5 text-sm font-medium text-white",
            if(@scanning, do: "bg-primary/50 cursor-not-allowed", else: "bg-primary hover:bg-primary/90")
          ]}
        >
          <.icon name="hero-magnifying-glass" class="h-4 w-4" />
          {if @scanning, do: "Scanning...", else: "Scan Now"}
        </button>
      </div>
    </div>

    <div
      :if={@scanning}
      class="mb-4 rounded-sm border border-stroke bg-white px-5 py-3 shadow-default dark:border-strokedark dark:bg-boxdark"
    >
      <div class="flex items-center gap-2 text-sm text-bodydark">
        <svg class="h-4 w-4 animate-spin" viewBox="0 0 24 24" fill="none">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
        </svg>
        Scan in progress — this usually takes 3-5 minutes. You can navigate away; the page will update when it finishes.
      </div>
    </div>

    <div
      :if={!@discovery_enabled}
      class="rounded-sm border border-stroke bg-white px-5 py-8 shadow-default dark:border-strokedark dark:bg-boxdark text-center"
    >
      <p class="text-lg text-bodydark mb-4">Discovery is disabled.</p>
      <.link href={~p"/settings"} class="text-primary hover:underline">
        Enable it in Settings → Discovery
      </.link>
    </div>

    <div
      :if={@discovery_enabled && @suggestions == []}
      class="rounded-sm border border-stroke bg-white px-5 py-8 shadow-default dark:border-strokedark dark:bg-boxdark text-center"
    >
      <p class="text-lg text-bodydark mb-2">No suggestions yet.</p>
      <p class="text-sm text-bodydark2">Click "Scan Now" to discover new channels based on your library.</p>
    </div>

    <div :if={@discovery_enabled && @suggestions != []} class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
      <div
        :for={suggestion <- @suggestions}
        class="rounded-sm border border-stroke bg-white p-5 shadow-default dark:border-strokedark dark:bg-boxdark"
      >
        <div class="flex items-start justify-between mb-3">
          <div class="flex-1 min-w-0">
            <h3 class="text-lg font-semibold text-black dark:text-white truncate">
              <a href={suggestion.url} target="_blank" class="hover:underline">
                {suggestion.name || suggestion.channel_id}
              </a>
            </h3>
            <p class="text-sm text-bodydark2 mt-1">
              {format_subs(suggestion.subscriber_count)} subscribers {if suggestion.video_count,
                do: " · #{suggestion.video_count} videos"}
            </p>
          </div>
        </div>

        <p class="text-sm text-bodydark mb-4">
          {suggestion.reason || "Discovered by scan"}
        </p>

        <div class="flex items-center justify-between">
          <span class="text-xs text-bodydark2">
            Score: {Float.round(suggestion.score, 1)}
          </span>
          <div class="flex gap-2">
            <button
              phx-click="dismiss"
              phx-value-id={suggestion.id}
              class="rounded px-3 py-1 text-sm text-bodydark hover:bg-danger/10 hover:text-danger"
            >
              Dismiss
            </button>
            <button
              phx-click="accept"
              phx-value-id={suggestion.id}
              class="rounded bg-primary px-3 py-1 text-sm text-white hover:bg-primary/90"
            >
              Accept
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_subs(nil), do: "?"
  defp format_subs(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_subs(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_subs(n), do: "#{n}"
end
