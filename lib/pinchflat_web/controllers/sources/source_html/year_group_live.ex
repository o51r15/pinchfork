defmodule PinchflatWeb.Sources.YearGroupLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Tasks.Task, as: PFTask
  alias Pinchflat.Downloading.DownloadingHelpers

  @policy_reasons ["policy_public", "policy_members", "policy_other"]
  @members_availability ~w(subscriber_only premium_only needs_auth)
  @default_page_size 50

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  def render(%{years: []} = assigns) do
    ~H"""
    <div class="text-center py-12 text-gray-400">
      No media items found for this source yet. Index the source to populate it.
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="year-group-live" class="space-y-3">
      <div class="flex justify-end mb-2">
        <button
          phx-click="toggle_show_excluded"
          class="flex items-center gap-1.5 text-xs text-gray-400 hover:text-white transition-colors"
        >
          <.icon
            name={if @show_excluded, do: "hero-eye-slash", else: "hero-eye"}
            class="w-3.5 h-3.5"
          />
          {if @show_excluded, do: "Hide excluded", else: "Show excluded"}
        </button>
      </div>
      <%= for year_data <- @years do %>
        <% expanded = Map.get(@expanded_years, year_data.year) %>
        <div class="rounded-lg overflow-visible border border-strokedark">

          <%!-- Year section header --%>
          <div class="flex items-center gap-3 px-4 py-3 bg-meta-4 flex-wrap">

            <%!-- Expand/collapse button — wraps left content --%>
            <button
              phx-click="toggle_expand"
              phx-value-year={year_data.year}
              class="flex items-center gap-3 flex-1 min-w-0 text-left"
            >
              <.icon
                name={if expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
                class="w-4 h-4 text-gray-400 flex-shrink-0"
              />
              <span class="text-base font-bold text-white flex-shrink-0">{year_data.year}</span>
              <span class="text-sm text-gray-400 flex-shrink-0">
                <.localized_number number={year_data.total} /> episodes
              </span>
              <%!-- Progress bar --%>
              <div class="flex-1 h-1.5 bg-gray-700 rounded-full overflow-hidden min-w-12 hidden sm:block">
                <div
                  class="h-full bg-green-500 rounded-full transition-all duration-300"
                  style={"width: #{progress_pct(year_data)}%"}
                >
                </div>
              </div>
              <%!-- Count badges --%>
              <span class="text-xs text-green-400 flex-shrink-0">
                <.localized_number number={year_data.downloaded} /> / <.localized_number number={year_data.total} />
              </span>
            </button>

            <%!-- Page size selector — only visible when expanded --%>
            <form :if={expanded} phx-change="change_page_size" class="flex items-center flex-shrink-0">
              <input type="hidden" name="year" value={year_data.year} />
              <select
                name="size"
                class="bg-gray-800 text-white text-xs border-0 rounded px-2 py-1 focus:ring-0 focus:outline-none"
              >
                <option value="50" selected={expanded.page_size == 50}>50</option>
                <option value="100" selected={expanded.page_size == 100}>100</option>
                <option value="200" selected={expanded.page_size == 200}>200</option>
                <option value="300" selected={expanded.page_size == 300}>300</option>
                <option value="all" selected={expanded.page_size == :all}>All</option>
              </select>
            </form>

            <%!-- Year monitored toggle --%>
            <button
              phx-click="toggle_year"
              phx-value-year={year_data.year}
              class={"px-3 py-1 rounded-full text-xs font-semibold flex-shrink-0 transition-colors #{year_toggle_class(year_data.toggle_state)}"}
            >
              {year_toggle_label(year_data.toggle_state)}
            </button>
          </div>

          <%!-- Episode rows — only rendered when expanded --%>
          <%= if expanded do %>
            <div class="overflow-x-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-strokedark">
                    <th class="px-4 py-2 text-left text-xs font-medium text-gray-400 uppercase tracking-wide w-20">
                      Date
                    </th>
                    <th class="px-4 py-2 text-left text-xs font-medium text-gray-400 uppercase tracking-wide">
                      Title
                    </th>
                    <th class="px-4 py-2 text-left text-xs font-medium text-gray-400 uppercase tracking-wide hidden md:table-cell w-20">
                      Duration
                    </th>
                    <th class="px-4 py-2 text-left text-xs font-medium text-gray-400 uppercase tracking-wide hidden lg:table-cell w-20">
                      Size
                    </th>
                    <th class="px-4 py-2 text-left text-xs font-medium text-gray-400 uppercase tracking-wide w-28">
                      Status
                    </th>
                    <th class="px-4 py-2 w-10"></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for item <- expanded.items do %>
                    <% status = item_status(item, expanded.active_job_ids, @source.download_cutoff_date, @source, @source.media_profile) %>
                    <tr class="border-b border-strokedark/50 hover:bg-meta-4/40 transition-colors">
                      <td class="px-4 py-2 text-gray-400 whitespace-nowrap text-xs">
                        {format_episode_date(item.uploaded_at)}
                      </td>
                      <td class="px-4 py-2 max-w-xs">
                        <div class="flex items-center gap-1.5 min-w-0">
                          <.tooltip
                            :if={item.last_error}
                            tooltip={item.last_error}
                            position="bottom-right"
                            tooltip_class="w-64"
                          >
                            <.icon name="hero-exclamation-circle-solid" class="text-red-500 w-4 h-4 flex-shrink-0" />
                          </.tooltip>
                          <.subtle_link
                            href={~p"/sources/#{@source.id}/media/#{item.id}"}
                            class="truncate block text-white hover:underline"
                          >
                            {item.title}
                          </.subtle_link>
                        </div>
                      </td>
                      <td class="px-4 py-2 text-gray-400 whitespace-nowrap text-xs hidden md:table-cell">
                        {format_duration(item.duration_seconds)}
                      </td>
                      <td class="px-4 py-2 text-gray-400 whitespace-nowrap text-xs hidden lg:table-cell">
                        {format_size(item.media_size_bytes)}
                      </td>
                      <td class="px-4 py-2">
                        <span class={"inline-flex px-2 py-0.5 rounded-full text-xs font-semibold #{status_badge_class(status)}"}>
                          {status_label(status)}
                        </span>
                      </td>
                      <td class="px-4 py-2 text-right">
                        <button
                          phx-click="toggle_item"
                          phx-value-id={item.id}
                          class="text-gray-500 hover:text-white transition-colors"
                          title={if item.prevent_download, do: "Enable download", else: "Disable download"}
                        >
                          <.icon
                            name={if item.prevent_download, do: "hero-eye-slash", else: "hero-eye"}
                            class="w-4 h-4"
                          />
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>

              <%!-- Truncation notice --%>
              <p
                :if={expanded.page_size != :all && length(expanded.items) == expanded.page_size}
                class="text-xs text-gray-500 text-center py-3"
              >
                Showing first {expanded.page_size} items. Change the selector above to load more.
              </p>
            </div>
          <% end %>

        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  def mount(_params, session, socket) do
    source = Sources.get_source!(session["source_id"]) |> Repo.preload(:media_profile)
    show_excluded = false
    years = load_year_summaries(source, show_excluded)

    # Expand the most recent year by default
    expanded_years =
      case years do
        [first | _] ->
          items = load_items_for_year(source, first.year, @default_page_size, show_excluded)
          active_ids = load_active_job_ids(source)
          %{first.year => %{items: items, page_size: @default_page_size, active_job_ids: active_ids}}

        [] ->
          %{}
      end

    {:ok, assign(socket, source: source, years: years, expanded_years: expanded_years, show_excluded: show_excluded)}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  def handle_event("toggle_expand", %{"year" => year_str}, socket) do
    year = String.to_integer(year_str)
    source = socket.assigns.source

    if Map.has_key?(socket.assigns.expanded_years, year) do
      {:noreply, assign(socket, :expanded_years, Map.delete(socket.assigns.expanded_years, year))}
    else
      items = load_items_for_year(source, year, @default_page_size, socket.assigns.show_excluded)
      active_ids = load_active_job_ids(source)
      entry = %{items: items, page_size: @default_page_size, active_job_ids: active_ids}
      {:noreply, assign(socket, :expanded_years, Map.put(socket.assigns.expanded_years, year, entry))}
    end
  end

  def handle_event("change_page_size", %{"year" => year_str, "size" => size_str}, socket) do
    year = String.to_integer(year_str)
    page_size = parse_page_size(size_str)
    items = load_items_for_year(socket.assigns.source, year, page_size, socket.assigns.show_excluded)

    {:noreply,
     assign(socket, :expanded_years,
       Map.update(socket.assigns.expanded_years, year, %{}, fn entry ->
         %{entry | items: items, page_size: page_size}
       end)
     )}
  end

  def handle_event("toggle_item", %{"id" => id_str}, socket) do
    item = Repo.get!(MediaItem, String.to_integer(id_str))

    if item.prevent_download do
      enable_item(item)
    else
      disable_item(item)
    end

    {:noreply, reload_year(socket, item.uploaded_at.year)}
  end

  def handle_event("toggle_year", %{"year" => year_str}, socket) do
    year = String.to_integer(year_str)
    source = socket.assigns.source
    year_data = Enum.find(socket.assigns.years, &(&1.year == year))

    case year_data.toggle_state do
      :on -> disable_year(source, year)
      :off -> enable_year(source, year)
      :mixed -> disable_year(source, year)
    end

    {:noreply, reload_all(socket)}
  end

  def handle_event("toggle_show_excluded", _params, socket) do
    new_val = !socket.assigns.show_excluded
    {:noreply, socket |> assign(:show_excluded, new_val) |> reload_all()}
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_year_summaries(source, show_excluded) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^MediaQuery.for_source(source))
    |> where(^visible_filter(show_excluded))
    |> group_by([mi], fragment("EXTRACT(YEAR FROM ?)::integer", mi.uploaded_at))
    |> select([mi], %{
      year: fragment("EXTRACT(YEAR FROM ?)::integer", mi.uploaded_at),
      total: count(mi.id),
      downloaded: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", mi.media_filepath)),
      pending:
        count(
          fragment(
            "CASE WHEN ? IS NULL AND ? = false AND ? IS NULL THEN 1 END",
            mi.media_filepath,
            mi.prevent_download,
            mi.error_type
          )
        ),
      prevented: count(fragment("CASE WHEN ? = true THEN 1 END", mi.prevent_download))
    })
    |> order_by([mi], desc: fragment("EXTRACT(YEAR FROM ?)::integer", mi.uploaded_at))
    |> Repo.all()
    |> Enum.map(fn row ->
      other = max(row.total - row.downloaded - row.pending, 0)

      Map.merge(row, %{
        toggle_state: compute_toggle_state(row),
        other: other
      })
    end)
  end

  defp load_items_for_year(source, year, :all, show_excluded) do
    year_base_query(source, year, show_excluded) |> Repo.all()
  end

  defp load_items_for_year(source, year, limit, show_excluded) do
    year_base_query(source, year, show_excluded) |> limit(^limit) |> Repo.all()
  end

  defp year_base_query(source, year, show_excluded) do
    MediaQuery.new()
    |> select(^select_fields())
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^MediaQuery.for_source(source))
    |> where([mi], fragment("EXTRACT(YEAR FROM ?)::integer", mi.uploaded_at) == ^year)
    |> where(^visible_filter(show_excluded))
    |> order_by([mi], desc: mi.uploaded_at)
  end

  # When show_excluded is true: show everything.
  # When show_excluded is false (default): hide items excluded by format preference,
  # availability policy, or cutoff date — but never hide already-downloaded items.
  defp visible_filter(true), do: dynamic(true)

  defp visible_filter(false) do
    policy_reasons = @policy_reasons
    members_availability = @members_availability

    dynamic(
      [mi, s, _mp],
      not is_nil(mi.media_filepath) or
        (
          # Passes profile's shorts/livestream format preference
          ^MediaQuery.format_matching_profile_preference() and
          # Not policy-excluded by reason (set at index time)
          (is_nil(mi.download_prevented_reason) or
             mi.download_prevented_reason not in ^policy_reasons) and
          # Not members-only when source has members disabled
          not (s.download_members_videos == false and
                 mi.availability in ^members_availability) and
          # Meets the source's cutoff date (items before cutoff hidden by default)
          (is_nil(s.download_cutoff_date) or
             fragment("?::date >= ?", mi.uploaded_at, s.download_cutoff_date))
        )
    )
  end

  # Selecting only what we need GREATLY speeds up queries on large tables.
  defp select_fields do
    [
      :id,
      :title,
      :uploaded_at,
      :duration_seconds,
      :media_size_bytes,
      :media_filepath,
      :prevent_download,
      :download_prevented_reason,
      :error_type,
      :last_error,
      :short_form_content,
      :livestream,
      :availability
    ]
  end

  # Batch-loads all active job media_item_ids for the source in one query.
  # Used to determine the :downloading status badge without per-row joins.
  # NOTE: oban_jobs.state is a Postgres enum — must cast to text for comparison.
  defp load_active_job_ids(source) do
    from(t in PFTask,
      join: j in assoc(t, :job),
      where: t.source_id == ^source.id,
      where: fragment("?::text", j.state) in ["executing", "available", "scheduled", "retryable"],
      select: t.media_item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # Mutations — item level
  # ---------------------------------------------------------------------------

  defp enable_item(item) do
    {:ok, updated} =
      Media.update_media_item(item, %{prevent_download: false, error_type: nil, last_error: nil})

    updated = Repo.preload(updated, :source, force: true)
    DownloadingHelpers.kickoff_download_if_pending(updated)
  end

  defp disable_item(item) do
    {:ok, _} = Media.update_media_item(item, %{prevent_download: true})
    cancel_and_delete_jobs_for_item(item.id)
  end

  defp cancel_and_delete_jobs_for_item(media_item_id) do
    # oban_jobs.state is a Postgres enum — cast required for string comparison
    job_ids =
      from(t in PFTask,
        join: j in assoc(t, :job),
        where: t.media_item_id == ^media_item_id,
        where: fragment("?::text", j.state) in ["executing", "available", "scheduled", "retryable"],
        select: j.id
      )
      |> Repo.all()

    if job_ids != [] do
      from(j in Oban.Job, where: j.id in ^job_ids)
      |> Repo.update_all(set: [state: "cancelled"])
    end

    from(t in PFTask, where: t.media_item_id == ^media_item_id)
    |> Repo.delete_all()
  end

  # ---------------------------------------------------------------------------
  # Mutations — year level
  # ---------------------------------------------------------------------------

  defp disable_year(source, year) do
    item_ids = year_item_ids(source, year)

    from(mi in MediaItem, where: mi.id in ^item_ids)
    |> Repo.update_all(set: [prevent_download: true])

    job_ids =
      from(t in PFTask,
        join: j in assoc(t, :job),
        where: t.media_item_id in ^item_ids,
        where: fragment("?::text", j.state) in ["executing", "available", "scheduled", "retryable"],
        select: j.id
      )
      |> Repo.all()

    if job_ids != [] do
      from(j in Oban.Job, where: j.id in ^job_ids)
      |> Repo.update_all(set: [state: "cancelled"])
    end

    from(t in PFTask, where: t.media_item_id in ^item_ids)
    |> Repo.delete_all()
  end

  defp enable_year(source, year) do
    item_ids = year_item_ids(source, year)

    from(mi in MediaItem, where: mi.id in ^item_ids)
    |> Repo.update_all(set: [prevent_download: false])

    DownloadingHelpers.enqueue_pending_download_tasks(source)
  end

  defp year_item_ids(source, year) do
    from(mi in MediaItem,
      where: mi.source_id == ^source.id,
      where: fragment("EXTRACT(YEAR FROM ?)::integer", mi.uploaded_at) == ^year,
      select: mi.id
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Reload helpers
  # ---------------------------------------------------------------------------

  defp reload_year(socket, year) do
    source = socket.assigns.source
    show_excluded = socket.assigns.show_excluded
    years = load_year_summaries(source, show_excluded)
    active_ids = load_active_job_ids(source)

    expanded_years =
      if Map.has_key?(socket.assigns.expanded_years, year) do
        page_size =
          get_in(socket.assigns.expanded_years, [year, :page_size]) || @default_page_size

        items = load_items_for_year(source, year, page_size, show_excluded)
        entry = %{items: items, page_size: page_size, active_job_ids: active_ids}
        Map.put(socket.assigns.expanded_years, year, entry)
      else
        socket.assigns.expanded_years
      end

    assign(socket, years: years, expanded_years: expanded_years)
  end

  defp reload_all(socket) do
    source = socket.assigns.source
    show_excluded = socket.assigns.show_excluded
    years = load_year_summaries(source, show_excluded)
    active_ids = load_active_job_ids(source)

    expanded_years =
      Enum.reduce(socket.assigns.expanded_years, %{}, fn {year, entry}, acc ->
        items = load_items_for_year(source, year, entry.page_size, show_excluded)
        Map.put(acc, year, %{entry | items: items, active_job_ids: active_ids})
      end)

    assign(socket, years: years, expanded_years: expanded_years)
  end

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  defp format_episode_date(%DateTime{} = dt) do
    "#{dt.day} #{month_abbr(dt.month)}"
  end

  defp format_episode_date(_), do: "—"

  defp month_abbr(1), do: "Jan"
  defp month_abbr(2), do: "Feb"
  defp month_abbr(3), do: "Mar"
  defp month_abbr(4), do: "Apr"
  defp month_abbr(5), do: "May"
  defp month_abbr(6), do: "Jun"
  defp month_abbr(7), do: "Jul"
  defp month_abbr(8), do: "Aug"
  defp month_abbr(9), do: "Sep"
  defp month_abbr(10), do: "Oct"
  defp month_abbr(11), do: "Nov"
  defp month_abbr(12), do: "Dec"

  defp format_duration(nil), do: "—"

  defp format_duration(seconds) when seconds >= 3600 do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    "#{h}h #{m}m"
  end

  defp format_duration(seconds) do
    m = div(seconds, 60)
    "#{m}m"
  end

  defp format_size(nil), do: "—"

  defp format_size(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  end

  defp format_size(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_size(bytes) do
    "#{div(bytes, 1024)} KB"
  end

  defp parse_page_size("all"), do: :all
  defp parse_page_size(n), do: String.to_integer(n)

  defp progress_pct(%{total: 0}), do: 0
  defp progress_pct(%{downloaded: d, total: t}), do: round(d / t * 100)

  # ---------------------------------------------------------------------------
  # Status badge helpers
  # ---------------------------------------------------------------------------

  defp item_status(item, active_job_ids, cutoff_date, source, mp) do
    cond do
      not is_nil(item.media_filepath) ->
        :downloaded

      before_cutoff?(item.uploaded_at, cutoff_date) ->
        :skipped_cutoff

      item.short_form_content == true && mp.shorts_behaviour == :exclude ->
        :skipped_short

      item.livestream == true && mp.livestream_behaviour == :exclude ->
        :skipped_live

      members_excluded?(item, source) ||
          item.download_prevented_reason == "policy_members" ->
        :skipped_members

      item.prevent_download &&
          item.download_prevented_reason in ["manual", "user_script"] ->
        :skipped_manual

      item.prevent_download ->
        :prevented

      item.error_type == "permanent" ->
        :failed

      item.error_type == "transient" ->
        :retrying

      MapSet.member?(active_job_ids, item.id) ->
        :downloading

      true ->
        :pending
    end
  end

  defp before_cutoff?(_uploaded_at, nil), do: false

  defp before_cutoff?(uploaded_at, cutoff_date) do
    Date.compare(DateTime.to_date(uploaded_at), cutoff_date) == :lt
  end

  defp members_excluded?(item, source) do
    source.download_members_videos == false &&
      item.availability in @members_availability
  end

  defp status_label(:downloaded), do: "Downloaded"
  defp status_label(:downloading), do: "Downloading"
  defp status_label(:pending), do: "Pending"
  defp status_label(:retrying), do: "Retrying"
  defp status_label(:failed), do: "Failed"
  defp status_label(:prevented), do: "Prevented"
  defp status_label(:skipped_short), do: "Skipped · Short"
  defp status_label(:skipped_live), do: "Skipped · Live"
  defp status_label(:skipped_members), do: "Skipped · Members"
  defp status_label(:skipped_manual), do: "Skipped · Manual"
  defp status_label(:skipped_cutoff), do: "Skipped · Cutoff"
  defp status_label(:excluded), do: "Excluded"

  defp status_badge_class(:downloaded), do: "bg-green-500/20 text-green-400"
  defp status_badge_class(:downloading), do: "bg-teal-500/20 text-teal-400"
  defp status_badge_class(:pending), do: "bg-blue-500/20 text-blue-400"
  defp status_badge_class(:retrying), do: "bg-orange-500/20 text-orange-400"
  defp status_badge_class(:failed), do: "bg-red-500/20 text-red-400"
  defp status_badge_class(:prevented), do: "bg-yellow-500/20 text-yellow-500"
  defp status_badge_class(:skipped_short), do: "bg-gray-500/15 text-gray-500"
  defp status_badge_class(:skipped_live), do: "bg-gray-500/15 text-gray-500"
  defp status_badge_class(:skipped_members), do: "bg-gray-500/15 text-gray-500"
  defp status_badge_class(:skipped_manual), do: "bg-gray-500/15 text-gray-500"
  defp status_badge_class(:skipped_cutoff), do: "bg-gray-500/15 text-gray-500"
  defp status_badge_class(:excluded), do: "bg-gray-500/15 text-gray-500"

  defp year_toggle_class(:on), do: "bg-green-500/20 text-green-400 hover:bg-green-500/30"
  defp year_toggle_class(:mixed), do: "bg-amber-500/20 text-amber-400 hover:bg-amber-500/30"
  defp year_toggle_class(:off), do: "bg-gray-500/20 text-gray-400 hover:bg-gray-500/30"

  defp year_toggle_label(:on), do: "Monitored"
  defp year_toggle_label(:mixed), do: "Mixed"
  defp year_toggle_label(:off), do: "Unmonitored"

  defp compute_toggle_state(%{prevented: 0}), do: :on

  defp compute_toggle_state(%{prevented: prevented, total: total})
       when prevented == total,
       do: :off

  defp compute_toggle_state(_), do: :mixed
end
