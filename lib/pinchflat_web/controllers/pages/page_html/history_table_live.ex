defmodule Pinchflat.Pages.HistoryTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.Downloading.DownloadingHelpers
  alias PinchflatWeb.CustomComponents.TextComponents

  @limit 5

  def render(%{records: []} = assigns) do
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
      <span class="mb-4 flex items-center">
        <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
        <span class="ml-2">
          Showing <.localized_number number={length(@records)} /> of <.localized_number number={@total_record_count} />
        </span>
      </span>
      <div class="max-w-full overflow-x-auto">
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
                <.subtle_link href={~p"/sources/#{media_item.source_id}/media/#{media_item.id}"}>
                  {media_item.title}
                </.subtle_link>
              </span>
            </section>
          </:col>
          <:col :let={media_item} label="Upload Date">
            {DateTime.to_date(media_item.uploaded_at)}
          </:col>
          <:col :let={media_item} label="Indexed At">
            {format_datetime(media_item.inserted_at)}
          </:col>
          <:col :let={media_item} :if={@media_state == "retry"} label="Next Retry">
            <span
              :if={media_item.next_retry_at}
              id={"retry-countdown-#{media_item.id}"}
              phx-hook="RetryCountdown"
              data-retry-at={DateTime.to_iso8601(media_item.next_retry_at)}
            >
              …
            </span>
            <span :if={is_nil(media_item.next_retry_at)}>queued</span>
          </:col>
          <:col :let={media_item} :if={@media_state == "downloaded"} label="Downloaded At">
            {format_datetime(media_item.media_downloaded_at)}
          </:col>
          <:col :let={media_item} label="Source" class="truncate max-w-xs">
            <.subtle_link href={~p"/sources/#{media_item.source_id}"}>
              {media_item.source.custom_name}
            </.subtle_link>
          </:col>
          <:col :let={media_item} :if={@media_state == "retry"} label="">
            <.button type="button" phx-click="retry_now" phx-value-id={media_item.id} class="text-sm">
              Retry Now
            </.button>
          </:col>
          <:col :let={media_item} :if={@media_state == "failed"} label="">
            <.button
              type="button"
              phx-click="force_retry"
              phx-value-id={media_item.id}
              data-confirm="This clears all error info for this item and restarts the download from scratch. Proceed?"
              class="text-sm"
            >
              Force Retry
            </.button>
          </:col>
        </.table>
      </div>
      <section class="flex justify-center mt-5">
        <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
      </section>
    </div>
    """
  end

  def mount(_params, session, socket) do
    page = 1
    media_state = session["media_state"]
    base_query = generate_base_query(media_state)
    pagination_attrs = fetch_pagination_attributes(base_query, page)

    {:ok,
     assign(
       socket,
       Map.merge(pagination_attrs, %{base_query: base_query, media_state: media_state})
     )}
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    direction = if direction == "inc", do: 1, else: -1
    new_page = assigns.page + direction
    new_assigns = fetch_pagination_attributes(assigns.base_query, new_page)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("reload_page", _params, %{assigns: assigns} = socket) do
    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("retry_now", %{"id" => id}, %{assigns: assigns} = socket) do
    case Repo.get(Pinchflat.Media.MediaItem, id) do
      nil -> :noop
      media_item -> DownloadingHelpers.retry_now(media_item)
    end

    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("force_retry", %{"id" => id}, %{assigns: assigns} = socket) do
    case Repo.get(Pinchflat.Media.MediaItem, id) do
      nil -> :noop
      media_item -> DownloadingHelpers.force_retry(media_item)
    end

    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page)

    {:noreply, assign(socket, new_assigns)}
  end

  defp fetch_pagination_attributes(base_query, page) do
    total_record_count = Repo.aggregate(base_query, :count, :id)
    total_pages = max(ceil(total_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)
    records = fetch_records(base_query, page)

    %{page: page, total_pages: total_pages, records: records, total_record_count: total_record_count}
  end

  defp fetch_records(base_query, page) do
    offset = (page - 1) * @limit

    base_query
    |> limit(^@limit)
    |> offset(^offset)
    |> Repo.all()
    |> Repo.preload(:source)
    |> attach_next_retry_at()
  end

  # For the Retry tab the table shows a live countdown to the next attempt. The retry time lives
  # on the item's MediaDownloadWorker Oban job (scheduled_at) reached via the tasks table. We
  # fetch the soonest scheduled_at per media item in one query and attach it as a virtual
  # `next_retry_at` field. nil when there's no pending/retryable job (e.g. it's executing now or
  # was pruned) — the template shows "queued" in that case.
  defp attach_next_retry_at([]), do: []

  defp attach_next_retry_at(records) do
    media_item_ids = Enum.map(records, & &1.id)

    retry_times =
      from(t in Pinchflat.Tasks.Task,
        join: j in assoc(t, :job),
        where: t.media_item_id in ^media_item_ids,
        # oban_jobs.state is a Postgres enum (oban_job_state), not text. Ecto won't auto-cast it
        # to match plain string literals, so we cast the column to text in a fragment. Without
        # this the comparison silently matches nothing.
        where: fragment("?::text", j.state) in ["scheduled", "retryable", "available"],
        group_by: t.media_item_id,
        select: {t.media_item_id, min(j.scheduled_at)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(records, fn media_item ->
      Map.put(media_item, :next_retry_at, Map.get(retry_times, media_item.id))
    end)
  end

  defp generate_base_query("pending") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.staged_pending()))
    |> order_by(desc: :id)
  end

  defp generate_base_query("retry") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.retrying()))
    |> order_by(desc: :id)
  end

  defp generate_base_query("failed") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.failed()))
    |> order_by(desc: :id)
  end

  defp generate_base_query("downloaded") do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.downloaded()))
    |> order_by(desc: :id)
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end
end
