defmodule PinchflatWeb.Sources.SourceIndexLive do
  use PinchflatWeb, :live_view

  import Ecto.Query
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.MediaQuery

  @impl true
  def mount(_params, _session, socket) do
    # A path, not a full URL: the browser turns it into an absolute link using the address
    # the user actually reached Pinchfork on (the endpoint's configured host is often
    # "localhost", which is wrong for anyone else on the network).
    opml_path = ~p"/sources/opml?#{[route_token: Settings.get!(:route_token)]}"

    {:ok,
     socket
     |> assign(:opml_path, opml_path)
     |> assign(:page_title, "Sources")
     |> assign(:current_path, "/sources")
     |> assign(:filter_name, "")
     |> assign(:filter_monitored, "all")
     |> assign(:sort, "name_asc")
     |> load_sources(), layout: {PinchflatWeb.Layouts, :app}}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_name, Map.get(params, "name", ""))
     |> assign(:filter_monitored, Map.get(params, "monitored", "all"))
     |> assign(:sort, Map.get(params, "sort", "name_asc"))
     |> load_sources()}
  end

  @impl true
  def handle_event("toggle_monitored", %{"id" => id}, socket) do
    source = Sources.get_source!(String.to_integer(id))
    {:ok, _} = Sources.update_source(source, %{download_media: !source.download_media})
    {:noreply, load_sources(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Sources">
      <:actions>
        <button
          type="button"
          class="inline-flex h-10 items-center gap-2 rounded-lg border border-line px-3.5 text-sm font-semibold text-fg hover:bg-surface-2"
          title="Copy the OPML link for podcast apps"
          x-data="{ copied: false }"
          x-on:click={"
            copyWithCallbacks(
              new URL('#{@opml_path}', window.location.href).href,
              () => copied = true,
              () => copied = false
            )
          "}
        >
          <.icon name="hero-rss" class="h-4 w-4 text-muted" x-show="!copied" />
          <.icon name="hero-check" class="h-4 w-4 text-ok" x-show="copied" x-cloak /> Copy OPML
        </button>
        <.link
          href={~p"/sources/new"}
          class="inline-flex h-10 items-center gap-1.5 rounded-lg bg-accent px-4 text-sm font-semibold text-onaccent hover:opacity-90"
        >
          <.icon name="hero-plus" class="h-4 w-4" /> Add source
        </.link>
      </:actions>
    </.page_header>

    <div :if={@all_count > 0} class="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
      <.stat label="Sources" value={format_number(@all_count)} />
      <.stat label="Videos found" value={format_number(@totals.total)} />
      <.stat
        label="Downloaded"
        value={"#{format_number(@totals.downloaded)} of #{format_number(@totals.wanted)}"}
        class="text-accent"
      />
      <.stat label="Monitored" value={"#{@monitored_count} of #{@all_count}"} />
    </div>

    <form :if={@all_count > 0} phx-change="filter" phx-submit="filter" class="mb-5 flex flex-wrap items-center gap-2">
      <label class="flex h-10 min-w-[200px] flex-1 items-center gap-2 rounded-lg border border-line bg-surface px-3 text-muted focus-within:border-accent sm:max-w-xs">
        <.icon name="hero-magnifying-glass" class="h-4 w-4" />
        <input
          type="text"
          name="name"
          value={@filter_name}
          placeholder="Filter by name"
          aria-label="Filter sources by name"
          phx-debounce="200"
          class="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-fg placeholder:text-muted focus:outline-none focus:ring-0"
        />
      </label>
      <div class="flex gap-1.5" role="radiogroup" aria-label="Show">
        <label
          :for={{value, label} <- [{"all", "All"}, {"monitored", "Monitored"}, {"unmonitored", "Unmonitored"}]}
          class={[
            "inline-flex h-8 cursor-pointer items-center rounded-full border px-3 text-[13px] font-medium transition-colors",
            if(@filter_monitored == value,
              do: "border-accent bg-accent-soft text-fg",
              else: "border-line text-muted hover:text-fg"
            )
          ]}
        >
          <input type="radio" name="monitored" value={value} checked={@filter_monitored == value} class="sr-only" />
          {label}
        </label>
      </div>
      <span class="flex-1"></span>
      <%!-- Poster size: kept in this browser (localStorage) and applied as a CSS variable on the
           grid. LiveView leaves this element alone (phx-update="ignore"), and the slider's own
           input/change events stop here so they don't send a filter event. --%>
      <div
        id="poster-size"
        phx-update="ignore"
        class="hidden items-center gap-2 text-muted sm:flex"
        x-data="{ size: (() => { try { return Number(localStorage.getItem('pf-poster-size')) || 180 } catch (e) { return 180 } })() }"
        x-init="$watch('size', v => { try { localStorage.setItem('pf-poster-size', v) } catch (e) {} })"
      >
        <style x-text="'#source-grid { --poster: ' + size + 'px; }'">
        </style>
        <.icon name="hero-photo-mini" class="h-3.5 w-3.5" />
        <input
          type="range"
          min="120"
          max="320"
          step="10"
          x-model.number="size"
          x-on:input.stop
          x-on:change.stop
          aria-label="Poster size"
          title="Poster size"
          class="h-1.5 w-28 cursor-pointer accent-[rgb(var(--c-accent))]"
        />
        <.icon name="hero-photo" class="h-5 w-5" />
      </div>
      <div class="relative">
        <select
          name="sort"
          aria-label="Sort sources"
          class="h-10 appearance-none rounded-lg border border-line bg-surface py-0 pl-3 pr-9 text-sm text-fg focus:border-accent focus:ring-0"
        >
          <option value="name_asc" selected={@sort == "name_asc"}>Name A–Z</option>
          <option value="name_desc" selected={@sort == "name_desc"}>Name Z–A</option>
          <option value="downloaded_desc" selected={@sort == "downloaded_desc"}>Most downloaded</option>
          <option value="downloaded_asc" selected={@sort == "downloaded_asc"}>Least downloaded</option>
        </select>
        <.icon
          name="hero-chevron-up-down-mini"
          class="pointer-events-none absolute right-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted"
        />
      </div>
    </form>

    <div :if={@all_count == 0} class="pf-card">
      <.empty_state
        icon="hero-tv"
        title="No sources yet"
        description="Add a YouTube channel or playlist and Pinchfork will index it and start downloading."
      >
        <:actions>
          <.link
            href={~p"/sources/new"}
            class="inline-flex h-10 items-center gap-1.5 rounded-lg bg-accent px-4 text-sm font-semibold text-onaccent hover:opacity-90"
          >
            <.icon name="hero-plus" class="h-4 w-4" /> Add source
          </.link>
        </:actions>
      </.empty_state>
    </div>

    <p :if={@all_count > 0 and @sources == []} class="py-10 text-center text-sm text-muted">
      No sources match these filters.
    </p>

    <div id="source-grid" class="grid grid-cols-2 gap-4 sm:grid-cols-[repeat(auto-fill,minmax(var(--poster,180px),1fr))]">
      <%= for source <- @sources do %>
        <% counts = Map.get(@counts_by_source, source.id, %{total: 0, downloaded: 0, wanted: 0}) %>
        <% pct = if counts.wanted > 0, do: min(round(counts.downloaded / counts.wanted * 100), 100), else: 0 %>
        <div class="group pf-card flex flex-col overflow-hidden transition-colors hover:border-accent/60">
          <.link href={~p"/sources/#{source.id}"} class="relative block bg-surface-2" style="aspect-ratio: 2/3;">
            <img src={~p"/sources/#{source.id}/poster"} alt="" class="h-full w-full object-cover" loading="lazy" />
            <span :if={!source.download_media} class="pf-chip absolute left-2 top-2 border border-line bg-bg/90 text-muted">
              Unmonitored
            </span>
          </.link>
          <div class="flex flex-1 flex-col gap-1.5 px-3 pb-3 pt-2.5">
            <div class="flex items-start gap-1">
              <.link
                href={~p"/sources/#{source.id}"}
                class="min-w-0 flex-1 truncate text-sm font-semibold text-fg hover:text-accent"
                title={source.custom_name}
              >
                {source.custom_name}
              </.link>
              <button
                phx-click="toggle_monitored"
                phx-value-id={source.id}
                class="-mr-1 rounded p-0.5 text-muted transition-colors hover:text-fg"
                aria-label={
                  if source.download_media,
                    do: "Stop monitoring #{source.custom_name}",
                    else: "Monitor #{source.custom_name}"
                }
                title={
                  if source.download_media,
                    do: "Monitored. Click to stop downloading.",
                    else: "Unmonitored. Click to start downloading."
                }
              >
                <.icon
                  name={if source.download_media, do: "hero-eye-mini", else: "hero-eye-slash-mini"}
                  class={if source.download_media, do: "h-4 w-4 text-accent", else: "h-4 w-4"}
                />
              </button>
            </div>
            <div class="text-xs capitalize text-muted">{source.collection_type}</div>
            <div class="h-1 overflow-hidden rounded-full bg-surface-3" role="presentation">
              <div class="h-full rounded-full bg-accent" style={"width: #{pct}%"}></div>
            </div>
            <div
              class="tabular font-mono text-[11.5px] text-muted"
              title={"#{counts.downloaded} downloaded of #{counts.wanted} wanted (#{counts.total} found on YouTube)"}
            >
              {format_number(counts.downloaded)} / {format_number(counts.wanted)}
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_sources(%{assigns: assigns} = socket) do
    query =
      from(s in Source,
        where: is_nil(s.marked_for_deletion_at)
      )

    query =
      case String.trim(assigns.filter_name) do
        "" -> query
        name -> from(s in query, where: ilike(s.custom_name, ^"%#{name}%"))
      end

    query =
      case assigns.filter_monitored do
        "monitored" -> from(s in query, where: s.download_media == true)
        "unmonitored" -> from(s in query, where: s.download_media == false)
        _ -> query
      end

    # DB-level sort for name; downloaded sorts applied in Elixir after counts are fetched
    query =
      case assigns.sort do
        "name_desc" -> from(s in query, order_by: [desc: s.custom_name])
        _ -> from(s in query, order_by: [asc: s.custom_name])
      end

    sources = Repo.all(query)
    source_ids = Enum.map(sources, & &1.id)

    counts_by_source =
      if source_ids == [] do
        %{}
      else
        from(mi in MediaItem,
          where: mi.source_id in ^source_ids,
          group_by: mi.source_id,
          select: {
            mi.source_id,
            %{
              total: count(mi.id),
              downloaded: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", mi.media_filepath))
            }
          }
        )
        |> Repo.all()
        |> Map.new()
      end

    wanted = wanted_counts(source_ids)

    counts_by_source =
      Map.new(counts_by_source, fn {id, counts} -> {id, Map.put(counts, :wanted, Map.get(wanted, id, 0))} end)

    # Apply Elixir-side sort for downloaded counts
    sources =
      case assigns.sort do
        "downloaded_desc" ->
          Enum.sort_by(
            sources,
            fn s ->
              Map.get(counts_by_source, s.id, %{downloaded: 0}).downloaded
            end,
            :desc
          )

        "downloaded_asc" ->
          Enum.sort_by(
            sources,
            fn s ->
              Map.get(counts_by_source, s.id, %{downloaded: 0}).downloaded
            end,
            :asc
          )

        _ ->
          sources
      end

    socket
    |> assign(sources: sources, counts_by_source: counts_by_source)
    |> assign_library_totals()
  end

  # Whole-library numbers for the summary strip, independent of the current filters
  defp assign_library_totals(socket) do
    live_sources = from(s in Source, where: is_nil(s.marked_for_deletion_at))

    {all_count, monitored_count} =
      Repo.one(
        from s in live_sources,
          select: {count(s.id), count(fragment("CASE WHEN ? THEN 1 END", s.download_media))}
      )

    totals =
      Repo.one(
        from mi in MediaItem,
          join: s in subquery(live_sources),
          on: s.id == mi.source_id,
          select: %{
            total: count(mi.id),
            downloaded: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", mi.media_filepath))
          }
      )

    live_ids = Repo.all(from s in live_sources, select: s.id)
    totals = Map.put(totals, :wanted, wanted_counts(live_ids) |> Map.values() |> Enum.sum())

    assign(socket, all_count: all_count, monitored_count: monitored_count, totals: totals)
  end

  # Videos a source is meant to download: already downloaded, still wanted by the download
  # rules (waiting or retrying), or permanently failed. Videos skipped by the profile or source
  # rules, or turned off by hand, aren't counted, so "34 / 34" means nothing is missing.
  # Returns %{source_id => count}
  defp wanted_counts([]), do: %{}

  defp wanted_counts(source_ids) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where([mi], mi.source_id in ^source_ids)
    |> where(
      ^dynamic(
        [mi],
        not is_nil(mi.media_filepath) or fragment("COALESCE(?::text = 'permanent', false)", mi.error_type) or
          ^MediaQuery.pending()
      )
    )
    |> group_by([mi], mi.source_id)
    |> select([mi], {mi.source_id, count(mi.id)})
    |> Repo.all()
    |> Map.new()
  end
end
