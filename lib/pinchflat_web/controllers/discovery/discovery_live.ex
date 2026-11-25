defmodule PinchflatWeb.Discovery.DiscoveryLive do
  @moduledoc """
  Channels suggested from the user's own library: who their sources mention and feature.
  Shows a random handful of the pending suggestions at a time; Add source opens Add Source
  prefilled, Dismiss hides one (with Undo).
  """

  use PinchflatWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.ScanWorker
  alias PinchflatWeb.Sources.SourceHTML

  @display_count 12

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pinchflat.PubSub, "discovery:scan")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Discovery",
       current_path: "/discovery",
       scanning: scan_running?(),
       dismissed: nil
     )
     |> load_suggestions(), layout: {PinchflatWeb.Layouts, :app}}
  end

  @impl true
  def handle_info({:scan_complete, result}, socket) do
    {flash_type, message} =
      case result do
        %{error: error} -> {:error, "The scan didn't finish: #{error}"}
        %{persisted: 0} -> {:info, "Scan finished. Nothing new this time."}
        %{persisted: 1} -> {:info, "Scan finished with 1 suggestion."}
        %{persisted: persisted} -> {:info, "Scan finished with #{persisted} suggestions."}
      end

    {:noreply,
     socket
     |> assign(scanning: false)
     |> put_flash(flash_type, message)
     |> load_suggestions()}
  end

  @impl true
  def handle_event("scan", _params, socket) do
    case ScanWorker.new(%{}) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        # A scan is already queued or running; its completion broadcast clears the banner
        {:noreply, assign(socket, scanning: true)}

      {:ok, _job} ->
        {:noreply, assign(socket, scanning: true)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The scan couldn't be started.")}
    end
  end

  def handle_event("shuffle", _params, socket) do
    {:noreply, socket |> assign(dismissed: nil) |> load_suggestions()}
  end

  def handle_event("accept", %{"id" => id}, socket) do
    # Status is NOT changed here: the suggestion flips to "accepted" only once a source for the
    # channel actually exists (Discovery.reconcile_with_sources/0). Backing out of Add Source
    # therefore leaves it pending instead of hiding it forever.
    case Discovery.get_suggestion(id) do
      %{} = suggestion ->
        {:noreply,
         redirect(socket,
           to: ~p"/sources/new?prefill_url=#{suggestion.url}&prefill_name=#{suggestion.name || ""}&prefill_type=channel"
         )}

      nil ->
        {:noreply, socket |> put_flash(:error, "That suggestion is no longer available.") |> load_suggestions()}
    end
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    with %{} = suggestion <- Discovery.get_suggestion(id),
         {:ok, suggestion} <- Discovery.dismiss_suggestion(suggestion) do
      {:noreply,
       socket
       |> assign(dismissed: suggestion)
       |> assign(suggestions: Enum.reject(socket.assigns.suggestions, &(&1.id == suggestion.id)))
       |> update(:pending_count, &max(&1 - 1, 0))}
    else
      _ -> {:noreply, socket |> put_flash(:error, "That suggestion is no longer available.") |> load_suggestions()}
    end
  end

  def handle_event("undo_dismiss", _params, socket) do
    case socket.assigns.dismissed do
      %{} = suggestion ->
        {:ok, suggestion} = Discovery.restore_suggestion(suggestion)

        {:noreply,
         socket
         |> assign(dismissed: nil)
         |> update(:suggestions, &(&1 ++ [suggestion]))
         |> update(:pending_count, &(&1 + 1))}

      nil ->
        {:noreply, socket}
    end
  end

  defp load_suggestions(socket) do
    Discovery.reconcile_with_sources()

    assign(socket,
      suggestions: Discovery.list_random_suggestions(@display_count),
      pending_count: Discovery.pending_suggestion_count(),
      last_scanned_at: Discovery.last_scanned_at(),
      discovery_enabled: Discovery.discovery_settings().enabled
    )
  end

  defp scan_running? do
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
    <div class="mx-auto max-w-6xl">
      <.page_header
        title="Discovery"
        description="Channels like the ones you already follow, found from who your sources mention and feature."
      >
        <:actions :if={@discovery_enabled}>
          <button
            :if={@pending_count > length(@suggestions)}
            type="button"
            phx-click="shuffle"
            id="shuffle"
            class="inline-flex h-9 items-center gap-1.5 rounded-lg border border-line px-3.5 text-sm font-semibold text-fg hover:bg-surface-2"
          >
            <.icon name="hero-arrows-right-left-mini" class="h-4 w-4" /> Show others
          </button>
          <button
            type="button"
            phx-click="scan"
            disabled={@scanning}
            id="scan"
            class="inline-flex h-9 items-center gap-1.5 rounded-lg bg-accent px-3.5 text-sm font-semibold text-onaccent hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <.icon name="hero-magnifying-glass-mini" class="h-4 w-4" />
            {if @scanning, do: "Scanning…", else: "Scan now"}
          </button>
        </:actions>
      </.page_header>

      <div :if={!@discovery_enabled} class="pf-card" id="discovery-off">
        <.empty_state
          icon="hero-sparkles"
          title="Discovery is off"
          description="When it's on, Pinchfork looks through your sources' videos for channels they mention and feature, and suggests the ones you don't have yet."
        >
          <:actions>
            <.link
              navigate={~p"/settings/discovery"}
              class="inline-flex h-9 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-onaccent hover:opacity-90"
            >
              Turn it on in Settings
            </.link>
          </:actions>
        </.empty_state>
      </div>

      <div :if={@discovery_enabled}>
        <div :if={@scanning} class="pf-card mb-4 flex items-center gap-3 px-5 py-3.5" id="scan-banner">
          <.icon name="hero-arrow-path" class="h-5 w-5 shrink-0 animate-spin text-accent" />
          <p class="text-sm text-fg">
            Scanning your library. This usually takes a few minutes; you can leave this page and the list updates when it's done.
          </p>
        </div>

        <div :if={@dismissed} class="pf-card mb-4 flex items-center justify-between gap-3 px-5 py-3" id="dismissed-banner">
          <p class="text-sm text-fg">
            Dismissed <span class="font-semibold">{@dismissed.name || @dismissed.channel_id}</span>. It won't be suggested again.
          </p>
          <button type="button" phx-click="undo_dismiss" class="text-sm font-semibold text-accent hover:underline">
            Undo
          </button>
        </div>

        <p :if={@suggestions != []} class="mb-3 text-sm text-muted" id="suggestion-count">
          Showing {length(@suggestions)} of {@pending_count}
          {if @pending_count == 1, do: "suggestion", else: "suggestions"}
          <span :if={@last_scanned_at}>· Last scan {SourceHTML.time_ago(@last_scanned_at)}</span>
        </p>

        <div :if={@suggestions == []} class="pf-card" id="discovery-empty">
          <.empty_state
            icon="hero-sparkles"
            title={if @last_scanned_at, do: "You've seen every suggestion", else: "No suggestions yet"}
            description={
              if @last_scanned_at,
                do: "Scan again later: as your sources upload, they mention new channels.",
                else: "Run a scan to look through your library for channels your sources mention and feature."
            }
          />
        </div>

        <div :if={@suggestions != []} class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3" id="suggestions">
          <article
            :for={suggestion <- @suggestions}
            class="pf-card flex flex-col gap-3 p-5"
            id={"suggestion-#{suggestion.id}"}
          >
            <div class="flex items-start gap-3">
              <%!-- The channel picture loads straight from YouTube. The initials sit underneath and
                   show whenever there's no picture or it fails to load (the image hides itself). --%>
              <span
                class="relative grid h-11 w-11 shrink-0 place-items-center overflow-hidden rounded-full bg-accent-soft text-sm font-semibold text-accent"
                id={"avatar-#{suggestion.id}"}
              >
                {initials(suggestion.name || suggestion.channel_id)}
                <img
                  :if={suggestion.thumbnail_url}
                  src={suggestion.thumbnail_url}
                  alt=""
                  loading="lazy"
                  referrerpolicy="no-referrer"
                  class="absolute inset-0 h-full w-full object-cover"
                  x-data
                  x-init="if ($el.complete && $el.naturalWidth === 0) $el.remove()"
                  x-on:error="$el.remove()"
                />
              </span>
              <div class="min-w-0 flex-1">
                <a
                  href={suggestion.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group inline-flex max-w-full items-center gap-1 font-semibold text-fg hover:text-accent"
                  title="Open on YouTube"
                >
                  <span class="truncate">{suggestion.name || suggestion.channel_id}</span>
                  <.icon
                    name="hero-arrow-top-right-on-square-mini"
                    class="h-3.5 w-3.5 shrink-0 text-muted group-hover:text-accent"
                  />
                </a>
                <p :if={facts(suggestion) != ""} class="mt-0.5 text-xs text-muted">{facts(suggestion)}</p>
                <p :if={suggestion.last_upload_at} class="text-xs text-muted">
                  Last upload {SourceHTML.time_ago(suggestion.last_upload_at)}
                </p>
              </div>
            </div>

            <p class="text-sm leading-6 text-fg">{reason(suggestion.reason)}</p>
            <div class="flex flex-wrap gap-1.5">
              <.status_chip kind={elem(match(suggestion.score), 1)}>{elem(match(suggestion.score), 0)}</.status_chip>
              <.status_chip :if={suggestion.cluster}>{suggestion.cluster}</.status_chip>
            </div>

            <div class="mt-auto flex items-center justify-end gap-2 border-t border-line pt-3">
              <div class="flex gap-2">
                <button
                  type="button"
                  phx-click="dismiss"
                  phx-value-id={suggestion.id}
                  class="inline-flex h-8 items-center rounded-lg px-3 text-[13px] font-semibold text-muted hover:bg-surface-2 hover:text-fg"
                >
                  Dismiss
                </button>
                <button
                  type="button"
                  phx-click="accept"
                  phx-value-id={suggestion.id}
                  class="inline-flex h-8 items-center gap-1 rounded-lg bg-accent px-3 text-[13px] font-semibold text-onaccent hover:opacity-90"
                >
                  <.icon name="hero-plus-mini" class="h-4 w-4" /> Add source
                </button>
              </div>
            </div>
          </article>
        </div>
      </div>
    </div>
    """
  end

  # "Fall of Civilizations" -> "FC": small joining words don't count
  defp initials(name) do
    words = String.split(name, ~r/[\s_\-]+/, trim: true)
    main = Enum.reject(words, &(String.downcase(&1) in ~w(of the and a an & to in on for)))
    picked = if main == [], do: words, else: main

    picked
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  # "1.2M subscribers · 340 videos", leaving out what's unknown
  defp facts(suggestion) do
    [
      suggestion.subscriber_count && "#{format_count(suggestion.subscriber_count)} subscribers",
      suggestion.video_count && "#{format_count(suggestion.video_count)} videos"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp format_count(n) when n >= 1_000_000, do: "#{trim_float(n / 1_000_000)}M"
  defp format_count(n) when n >= 1_000, do: "#{trim_float(n / 1_000)}K"
  defp format_count(n), do: to_string(n)

  defp trim_float(value) do
    rounded = Float.round(value, 1)
    if rounded == trunc(rounded), do: to_string(trunc(rounded)), else: to_string(rounded)
  end

  defp reason(nil), do: "Found by a library scan."
  defp reason("Discovered by scan"), do: "Found by a library scan."
  defp reason(text), do: if(String.ends_with?(text, "."), do: text, else: text <> ".")

  # Scores are sums of signals (see Discovery.Scorer); 50+ means at least two independent
  # signals agreed, 20+ is one solid signal.
  defp match(score) when score >= 50, do: {"Strong match", :accent}
  defp match(score) when score >= 20, do: {"Good match", :ok}
  defp match(_score), do: {"Possible match", :neutral}
end
