defmodule PinchflatWeb.Sources.SourceIndexLive do
  use PinchflatWeb, :live_view

  import Ecto.Query
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem

  @impl true
  def mount(_params, _session, socket) do
    opml_url = PinchflatWeb.Endpoint.url() <> ~p"/sources/opml"

    {:ok,
     socket
     |> assign(:opml_url, opml_url)
     |> assign(:current_path, "/sources")
     |> assign(:filter_name, "")
     |> assign(:filter_monitored, "all")
     |> assign(:sort, "name_asc")
     |> load_sources(),
     layout: {PinchflatWeb.Layouts, :app}}
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
    <%!-- Header row --%>
    <div class="mb-4 flex gap-3 flex-row items-center justify-between">
      <h2 class="text-title-md2 font-bold text-black dark:text-white">Sources</h2>
      <nav class="flex items-center gap-4">
        <.link
          href={@opml_url}
          x-data="{ copied: false }"
          x-on:click={"
            $event.preventDefault();
            copyWithCallbacks(
              '#{@opml_url}',
              () => copied = true,
              () => copied = false
            )
          "}
        >
          Copy OPML <span class="hidden sm:inline">Feed</span>
          <span x-show="copied" x-transition.duration.150ms>
            <.icon name="hero-check" class="ml-2 h-4 w-4" />
          </span>
        </.link>
        <.link href={~p"/sources/new"}>
          <.button color="bg-primary" rounding="rounded-lg">
            <span class="font-bold mx-2">+</span> New <span class="hidden sm:inline pl-1">Source</span>
          </.button>
        </.link>
      </nav>
    </div>

    <%!-- Filter / sort toolbar --%>
    <form phx-change="filter" phx-submit="filter" class="mb-5 flex flex-wrap gap-3 items-center">
      <input
        type="text"
        name="name"
        value={@filter_name}
        placeholder="Filter by name…"
        class="bg-meta-4 border-0 rounded-md px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:ring-1 focus:ring-primary w-48"
      />
      <select
        name="monitored"
        class="bg-meta-4 border-0 rounded-md px-3 py-1.5 text-sm text-white focus:ring-1 focus:ring-primary"
      >
        <option value="all" selected={@filter_monitored == "all"}>All</option>
        <option value="monitored" selected={@filter_monitored == "monitored"}>Monitored</option>
        <option value="unmonitored" selected={@filter_monitored == "unmonitored"}>Unmonitored</option>
      </select>
      <select
        name="sort"
        class="bg-meta-4 border-0 rounded-md px-3 py-1.5 text-sm text-white focus:ring-1 focus:ring-primary"
      >
        <option value="name_asc" selected={@sort == "name_asc"}>Name A–Z</option>
        <option value="name_desc" selected={@sort == "name_desc"}>Name Z–A</option>
        <option value="downloaded_desc" selected={@sort == "downloaded_desc"}>Most Downloaded</option>
        <option value="downloaded_asc" selected={@sort == "downloaded_asc"}>Least Downloaded</option>
      </select>
    </form>

    <%!-- Empty state --%>
    <%= if @sources == [] do %>
      <div class="rounded-sm border border-stroke bg-white px-5 py-10 shadow-default dark:border-strokedark dark:bg-boxdark text-center">
        <p class="text-gray-400 mb-4">No sources yet. Add one to get started.</p>
        <.link href={~p"/sources/new"}>
          <.button color="bg-primary" rounding="rounded-lg">
            <span class="font-bold mx-2">+</span> Add Source
          </.button>
        </.link>
      </div>
    <% else %>
      <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4">
        <%= for source <- @sources do %>
          <% counts = Map.get(@counts_by_source, source.id, %{total: 0, downloaded: 0}) %>
          <% pct = if counts.total > 0, do: round(counts.downloaded / counts.total * 100), else: 0 %>
          <div class="group">
            <%!-- Poster — links to source show page --%>
            <.link href={~p"/sources/#{source.id}"}>
              <div class="relative overflow-hidden rounded-lg bg-meta-4" style="aspect-ratio: 2/3;">
                <img
                  src={~p"/sources/#{source.id}/poster"}
                  alt={source.custom_name}
                  class="w-full h-full object-cover transition-opacity duration-200 group-hover:opacity-75"
                  loading="lazy"
                />
                <%!-- Progress bar --%>
                <div class="absolute bottom-0 left-0 right-0 h-1.5 bg-gray-800">
                  <div class="h-full bg-green-500 transition-all duration-300" style={"width: #{pct}%"}></div>
                </div>
              </div>
            </.link>

            <%!-- Name + action icons row --%>
            <div class="mt-2 flex items-start justify-between gap-1">
              <div class="min-w-0">
                <.link href={~p"/sources/#{source.id}"}>
                  <p class="text-sm font-medium text-white truncate hover:underline">{source.custom_name}</p>
                </.link>
                <p class="text-xs text-gray-400 capitalize">{source.collection_type}</p>
              </div>
              <div class="flex items-center gap-1 flex-shrink-0 mt-0.5">
                <%!-- Monitored toggle — always visible; green = actively downloading --%>
                <.tooltip
                  tooltip={if source.download_media, do: "Monitored — click to stop downloading", else: "Unmonitored — click to start downloading"}
                  position="top"
                  tooltip_class="w-48"
                >
                  <button
                    phx-click="toggle_monitored"
                    phx-value-id={source.id}
                    class="transition-colors duration-150"
                  >
                    <.icon
                      name={if source.download_media, do: "hero-eye", else: "hero-eye-slash"}
                      class={if source.download_media, do: "w-4 h-4 text-green-400", else: "w-4 h-4 text-gray-500"}
                    />
                  </button>
                </.tooltip>
                <%!-- Edit pencil — hover only --%>
                <.icon_link
                  href={~p"/sources/#{source.id}/edit"}
                  icon="hero-pencil-square"
                  class="opacity-0 group-hover:opacity-100 transition-opacity duration-200"
                />
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <p class="mt-8 text-xs text-gray-500 text-center">
        Cover art downloads automatically when <strong class="text-gray-400">Download Series Images</strong> is enabled in your Media Profile.
        Use <strong class="text-gray-400">Actions → Refresh Metadata</strong> on a source to fetch art immediately.
      </p>
    <% end %>
    """
  end

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

    # Apply Elixir-side sort for downloaded counts
    sources =
      case assigns.sort do
        "downloaded_desc" ->
          Enum.sort_by(sources, fn s ->
            Map.get(counts_by_source, s.id, %{downloaded: 0}).downloaded
          end, :desc)

        "downloaded_asc" ->
          Enum.sort_by(sources, fn s ->
            Map.get(counts_by_source, s.id, %{downloaded: 0}).downloaded
          end, :asc)

        _ ->
          sources
      end

    assign(socket, sources: sources, counts_by_source: counts_by_source)
  end
end
