defmodule PinchflatWeb.Sources.MediaItemTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Utils.NumberUtils

  @limit 10

  # YouTube availability values as reported by yt-dlp at index time.
  # "none" is a sentinel meaning IS NULL — used for items indexed before
  # the availability column existed or where yt-dlp returned nothing.
  @availability_options [
    {"All", ""},
    {"Public", "public"},
    {"Members only", "subscriber_only"},
    {"Needs auth", "needs_auth"},
    {"Unlisted", "unlisted"},
    {"Private / unavailable", "private"},
    {"Not captured", "none"}
  ]

  # error_type is set by MediaDownloadWorker.action_on_error/2:
  #   "transient" — failed, will retry
  #   "permanent" — failed permanently, prevent_download is also set
  #   nil         — no error (pending or successfully downloaded)
  # "none" is a sentinel meaning IS NULL.
  @error_type_options [
    {"All", ""},
    {"No error", "none"},
    {"Transient (retrying)", "transient"},
    {"Permanent (blocked)", "permanent"}
  ]

  def render(%{total_record_count: 0} = assigns) do
    ~H"""
    <div class="mb-4 flex items-center">
      <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" />
      <p class="ml-2">Nothing Here!</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <header class="flex justify-between items-start mb-4 flex-wrap gap-2">
        <span class="flex items-center">
          <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
          <span class="mx-2">
            Showing <.localized_number number={length(@records)} /> of <.localized_number number={@filtered_record_count} />
          </span>
        </span>
        <div class="flex items-center gap-2 flex-wrap">
          <form phx-change="filter_change" class="flex items-center gap-2 flex-wrap">
            <select
              name="availability_filter"
              class="bg-meta-4 text-white border-0 rounded-md px-3 py-2 text-sm focus:ring-0 focus:outline-none"
            >
              <option :for={{label, value} <- @availability_options} value={value} selected={@availability_filter == value}>
                {label}
              </option>
            </select>
            <select
              :if={@media_state != "downloaded"}
              name="error_type_filter"
              class="bg-meta-4 text-white border-0 rounded-md px-3 py-2 text-sm focus:ring-0 focus:outline-none"
            >
              <option :for={{label, value} <- @error_type_options} value={value} selected={@error_type_filter == value}>
                {label}
              </option>
            </select>
          </form>
          <div class="bg-meta-4 rounded-md">
            <div class="relative">
              <span class="absolute left-2 top-1/2 -translate-y-1/2 flex">
                <.icon name="hero-magnifying-glass" />
              </span>
              <form phx-change="search_term" phx-submit="search_term">
                <input
                  type="text"
                  name="q"
                  value={@search_term}
                  placeholder="Search in table..."
                  class="w-full bg-transparent pl-9 pr-4 border-0 focus:ring-0 focus:outline-none"
                  phx-debounce="200"
                />
              </form>
            </div>
          </div>
        </div>
      </header>
      <.table rows={@records} table_class="text-white">
        <:col :let={media_item} label="Title" class="max-w-xs">
          <section class="flex items-center space-x-1">
            <.tooltip
              :if={media_item.last_error}
              tooltip={media_item.last_error}
              position="bottom-right"
              tooltip_class="w-64"
            >
              <.icon name="hero-exclamation-circle-solid" class="text-red-500" />
            </.tooltip>
            <span class="truncate">
              <.subtle_link href={~p"/sources/#{@source.id}/media/#{media_item.id}"}>
                {media_item.title}
              </.subtle_link>
            </span>
          </section>
        </:col>
        <:col :let={media_item} :if={@media_state == "other"} label="Manually Ignored?">
          <.icon name={if media_item.prevent_download, do: "hero-check", else: "hero-x-mark"} />
        </:col>
        <:col :let={media_item} label="Upload Date">
          {DateTime.to_date(media_item.uploaded_at)}
        </:col>
        <:col :let={media_item} label="Availability">
          {media_item.availability || "—"}
        </:col>
        <:col :let={media_item} :if={@media_state != "downloaded"} label="Error Type">
          {media_item.error_type || "—"}
        </:col>
        <:col :let={media_item} label="" class="flex justify-end">
          <.icon_link href={~p"/sources/#{@source.id}/media/#{media_item.id}/edit"} icon="hero-pencil-square" class="mr-4" />
        </:col>
      </.table>
      <section class="flex justify-center mt-5">
        <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
      </section>
    </div>
    """
  end

  def mount(_params, session, socket) do
    PinchflatWeb.Endpoint.subscribe("media_table")

    page = 1
    media_state = session["media_state"]
    source = Sources.get_source!(session["source_id"])
    base_query = generate_base_query(source, media_state)
    filters = %{availability: "", error_type: ""}
    pagination_attrs = fetch_pagination_attributes(base_query, page, nil, filters)

    new_assigns =
      Map.merge(pagination_attrs, %{
        base_query: base_query,
        source: source,
        media_state: media_state,
        availability_filter: "",
        error_type_filter: "",
        availability_options: @availability_options,
        error_type_options: @error_type_options
      })

    {:ok, assign(socket, new_assigns)}
  end

  def handle_event("filter_change", params, %{assigns: assigns} = socket) do
    availability = Map.get(params, "availability_filter", "")
    # error_type_filter select is hidden on the downloaded tab, so it won't appear in
    # params — fall back to the current assign to avoid resetting it accidentally.
    error_type = Map.get(params, "error_type_filter", assigns.error_type_filter)
    filters = %{availability: availability, error_type: error_type}
    new_assigns = fetch_pagination_attributes(assigns.base_query, 1, assigns.search_term, filters)

    {:noreply,
     assign(socket, Map.merge(new_assigns, %{availability_filter: availability, error_type_filter: error_type}))}
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    direction = if direction == "inc", do: 1, else: -1
    new_page = assigns.page + direction
    filters = %{availability: assigns.availability_filter, error_type: assigns.error_type_filter}
    new_assigns = fetch_pagination_attributes(assigns.base_query, new_page, assigns.search_term, filters)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("search_term", params, %{assigns: assigns} = socket) do
    search_term = Map.get(params, "q", nil)
    filters = %{availability: assigns.availability_filter, error_type: assigns.error_type_filter}
    new_assigns = fetch_pagination_attributes(assigns.base_query, 1, search_term, filters)

    {:noreply, assign(socket, new_assigns)}
  end

  # This, along with the handle_info below, is a pattern to reload _all_
  # tables on page rather than just the one that triggered the reload.
  def handle_event("reload_page", _params, socket) do
    PinchflatWeb.Endpoint.broadcast("media_table", "reload", nil)

    {:noreply, socket}
  end

  def handle_info(%{topic: "media_table", event: "reload"}, %{assigns: assigns} = socket) do
    filters = %{availability: assigns.availability_filter, error_type: assigns.error_type_filter}
    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term, filters)

    {:noreply, assign(socket, new_assigns)}
  end

  defp fetch_pagination_attributes(base_query, page, search_term, filters) do
    column_filtered_query = apply_column_filters(base_query, filters)
    final_query = filtered_base_query(column_filtered_query, search_term)

    total_record_count = Repo.aggregate(base_query, :count, :id)
    filtered_record_count = Repo.aggregate(final_query, :count, :id)
    total_pages = max(ceil(filtered_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)

    records =
      fetch_records(final_query, page)
      |> maybe_order_by_rank(search_term)
      |> Repo.all()

    %{
      page: page,
      total_pages: total_pages,
      records: records,
      search_term: search_term,
      total_record_count: total_record_count,
      filtered_record_count: filtered_record_count
    }
  end

  defp apply_column_filters(query, %{availability: availability, error_type: error_type}) do
    query
    |> filter_by_availability(availability)
    |> filter_by_error_type(error_type)
  end

  # "" means no filter; "none" means IS NULL; any other value means = value
  defp filter_by_availability(query, ""), do: query
  defp filter_by_availability(query, "none"), do: where(query, [mi], is_nil(mi.availability))
  defp filter_by_availability(query, value), do: where(query, [mi], mi.availability == ^value)

  defp filter_by_error_type(query, ""), do: query
  defp filter_by_error_type(query, "none"), do: where(query, [mi], is_nil(mi.error_type))
  defp filter_by_error_type(query, value), do: where(query, [mi], mi.error_type == ^value)

  defp fetch_records(base_query, page) do
    offset = (page - 1) * @limit

    base_query
    |> limit(^@limit)
    |> offset(^offset)
  end

  defp maybe_order_by_rank(query, nil), do: order_by(query, desc: :uploaded_at)
  defp maybe_order_by_rank(query, ""), do: order_by(query, desc: :uploaded_at)
  defp maybe_order_by_rank(query, _term), do: order_by(query, [desc: fragment("rank"), desc: :uploaded_at])

  defp generate_base_query(source, "pending") do
    MediaQuery.new()
    |> select(^select_fields())
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
  end

  defp generate_base_query(source, "downloaded") do
    MediaQuery.new()
    |> select(^select_fields())
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
  end

  defp generate_base_query(source, "other") do
    MediaQuery.new()
    |> select(^select_fields())
    |> MediaQuery.require_assoc(:media_profile)
    |> where(
      ^dynamic(
        ^MediaQuery.for_source(source) and
          (not (^MediaQuery.downloaded()) and not (^MediaQuery.pending()))
      )
    )
  end

  defp filtered_base_query(base_query, nil), do: base_query
  defp filtered_base_query(base_query, ""), do: base_query

  defp filtered_base_query(base_query, search_term) do
    base_query
    |> MediaQuery.require_assoc(:media_items_search_index)
    |> where(^MediaQuery.matches_search_term(search_term))
  end

  # Selecting only what we need GREATLY speeds up queries on large tables.
  # availability and error_type added for column display and filter WHERE clauses.
  defp select_fields do
    [:id, :title, :uploaded_at, :prevent_download, :last_error, :availability, :error_type]
  end
end
