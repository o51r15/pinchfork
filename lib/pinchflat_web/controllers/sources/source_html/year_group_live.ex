defmodule PinchflatWeb.Sources.YearGroupLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.SkipReason
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
    <div class="pf-card">
      <.empty_state
        icon="hero-film"
        title="No videos yet"
        description="Pinchfork hasn't found any videos for this source. Use Check for new videos to look now."
      />
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="year-group-live" class="space-y-3">
      <div class="mb-2 flex justify-end">
        <button
          phx-click="toggle_show_excluded"
          class="inline-flex items-center gap-1.5 text-xs font-medium text-muted transition-colors hover:text-fg"
          id="toggle-excluded"
        >
          <.icon name={if @show_excluded, do: "hero-eye-slash-mini", else: "hero-eye-mini"} class="h-4 w-4" />
          {if @show_excluded, do: "Hide skipped videos", else: "Show skipped videos"}
        </button>
      </div>
      <%= for year_data <- @years do %>
        <% expanded = Map.get(@expanded_years, year_data.year) %>
        <section class="pf-card overflow-visible" id={"year-#{year_data.year}"}>
          <%!-- Year header --%>
          <div class="flex flex-wrap items-center gap-3 px-4 py-3">
            <button
              phx-click="toggle_expand"
              phx-value-year={year_data.year}
              class="flex min-w-0 flex-1 items-center gap-3 text-left"
              aria-expanded={to_string(expanded != nil)}
            >
              <.icon
                name={if expanded, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
                class="h-4 w-4 shrink-0 text-muted"
              />
              <span class="shrink-0 text-base font-semibold text-fg">{year_data.year}</span>
              <span class="shrink-0 text-sm text-muted">
                <.localized_number number={year_data.total} /> {if year_data.total == 1, do: "episode", else: "episodes"}
              </span>
              <div class="hidden h-1.5 min-w-12 flex-1 overflow-hidden rounded-full bg-surface-3 sm:block">
                <div
                  class="h-full rounded-full bg-ok transition-all duration-300"
                  style={"width: #{progress_pct(year_data)}%"}
                >
                </div>
              </div>
              <span class="tabular shrink-0 text-xs text-muted">
                <span class="font-medium text-ok"><.localized_number number={year_data.downloaded} /></span>
                of <.localized_number number={year_data.total} /> downloaded
              </span>
            </button>

            <%!-- How many of this year's episodes to list; only while it's open --%>
            <form :if={expanded} phx-change="change_page_size" class="flex shrink-0 items-center gap-1.5">
              <input type="hidden" name="year" value={year_data.year} />
              <label for={"page-size-#{year_data.year}"} class="text-xs text-muted">Show</label>
              <select
                id={"page-size-#{year_data.year}"}
                name="size"
                class="rounded-md border border-line bg-surface-2 py-1 pl-2 pr-7 text-xs text-fg focus:border-accent focus:ring-0"
              >
                <option :for={size <- [50, 100, 200, 300]} value={size} selected={expanded.page_size == size}>
                  {size}
                </option>
                <option value="all" selected={expanded.page_size == :all}>All</option>
              </select>
            </form>

            <button
              phx-click="toggle_year"
              phx-value-year={year_data.year}
              title={year_toggle_title(year_data.toggle_state)}
              class={[
                "shrink-0 rounded-full px-3 py-1 text-xs font-semibold transition-colors",
                year_toggle_class(year_data.toggle_state)
              ]}
            >
              {year_toggle_label(year_data.toggle_state)}
            </button>
          </div>

          <%!-- Episodes --%>
          <div :if={expanded} class="overflow-x-auto border-t border-line">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b border-line text-left text-xs font-medium uppercase tracking-wide text-muted">
                  <th class="w-20 px-4 py-2 font-medium">Date</th>
                  <th class="px-4 py-2 font-medium">Title</th>
                  <th class="hidden w-20 px-4 py-2 font-medium md:table-cell">Length</th>
                  <th class="hidden w-20 px-4 py-2 font-medium lg:table-cell">Size</th>
                  <th class="w-32 px-4 py-2 font-medium">Status</th>
                  <th class="w-10 px-4 py-2"><span class="sr-only">Download</span></th>
                </tr>
              </thead>
              <tbody>
                <%= for item <- expanded.items do %>
                  <% status =
                    item_status(
                      item,
                      expanded.active_job_ids,
                      @source.download_cutoff_date,
                      @source,
                      @source.media_profile
                    ) %>
                  <tr class="border-b border-line/60 transition-colors last:border-0 hover:bg-surface-2">
                    <td class="whitespace-nowrap px-4 py-2 text-xs text-muted">{format_episode_date(item.uploaded_at)}</td>
                    <td class="max-w-xs px-4 py-2">
                      <div class="flex min-w-0 items-center gap-1.5">
                        <.tooltip
                          :if={item.last_error}
                          tooltip={item.last_error}
                          position="bottom-right"
                          tooltip_class="w-64"
                        >
                          <.icon name="hero-exclamation-circle-mini" class="h-4 w-4 shrink-0 text-bad" />
                        </.tooltip>
                        <.link
                          href={~p"/sources/#{@source.id}/media/#{item.id}"}
                          class="block truncate text-fg hover:text-accent"
                        >
                          {item.title}
                        </.link>
                      </div>
                    </td>
                    <td class="hidden whitespace-nowrap px-4 py-2 text-xs text-muted md:table-cell">
                      {format_duration(item.duration_seconds)}
                    </td>
                    <td class="hidden whitespace-nowrap px-4 py-2 text-xs text-muted lg:table-cell">
                      {format_size(item.media_size_bytes)}
                    </td>
                    <td class="px-4 py-2">
                      <.status_chip kind={status_kind(status)}>{status_label(status)}</.status_chip>
                    </td>
                    <td class="px-4 py-2 text-right">
                      <button
                        phx-click="toggle_item"
                        phx-value-id={item.id}
                        class="text-muted transition-colors hover:text-fg"
                        title={
                          if item.prevent_download,
                            do: "Turn downloading on for this video",
                            else: "Turn downloading off for this video"
                        }
                      >
                        <.icon
                          name={if item.prevent_download, do: "hero-eye-slash-mini", else: "hero-eye-mini"}
                          class="h-4 w-4"
                        />
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>

            <p
              :if={expanded.page_size != :all && length(expanded.items) == expanded.page_size}
              class="border-t border-line py-3 text-center text-xs text-muted"
            >
              Showing the newest {expanded.page_size} of {year_data.total}. Choose more with Show above.
            </p>
          </div>
        </section>
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
     assign(
       socket,
       :expanded_years,
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
      # Passes profile's shorts/livestream format preference
      # Not policy-excluded by reason (set at index time)
      # Not members-only when source has members disabled
      # Meets the source's cutoff date (items before cutoff hidden by default)
      # (an unknown availability is not members-only; without the is_nil check a NULL
      # here made the whole condition NULL and hid the video)
      # Fails the source's title or length filter: skipped, unless it was turned off or
      # failed (those still show)
      not is_nil(mi.media_filepath) or
        (^MediaQuery.format_matching_profile_preference() and
           (is_nil(mi.download_prevented_reason) or
              mi.download_prevented_reason not in ^policy_reasons) and
           not (s.download_members_videos == false and not is_nil(mi.availability) and
                  mi.availability in ^members_availability) and
           (is_nil(s.download_cutoff_date) or
              fragment("?::date >= ?", mi.uploaded_at, s.download_cutoff_date)) and
           (mi.prevent_download or not is_nil(mi.error_type) or
              (^MediaQuery.matches_source_title_regex() and ^MediaQuery.meets_min_and_max_duration())))
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
      Media.update_media_item(item, %{
        prevent_download: false,
        download_prevented_reason: nil,
        error_type: nil,
        last_error: nil
      })

    updated = Repo.preload(updated, :source, force: true)
    DownloadingHelpers.kickoff_download_if_pending(updated)
  end

  defp disable_item(item) do
    {:ok, _} = Media.update_media_item(item, %{prevent_download: true, download_prevented_reason: "manual"})
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
      |> Oban.cancel_all_jobs()
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
    |> Repo.update_all(set: [prevent_download: true, download_prevented_reason: "manual"])

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
      |> Oban.cancel_all_jobs()
    end

    from(t in PFTask, where: t.media_item_id in ^item_ids)
    |> Repo.delete_all()
  end

  defp enable_year(source, year) do
    item_ids = year_item_ids(source, year)

    from(mi in MediaItem, where: mi.id in ^item_ids)
    |> Repo.update_all(set: [prevent_download: false, download_prevented_reason: nil])

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

      # The source's or profile's download rules leave it out (same rules as the source
      # page's Skipped count)
      (rule = SkipReason.rule(item, source, mp)) in [:profile_only, :duration, :title] ->
        %{profile_only: :skipped_profile_only, duration: :skipped_duration, title: :skipped_title}[rule]

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
  defp status_label(:pending), do: "Waiting"
  defp status_label(:retrying), do: "Retrying"
  defp status_label(:failed), do: "Failed"
  defp status_label(:prevented), do: "Turned off"
  defp status_label(:skipped_short), do: "Skipped · Short"
  defp status_label(:skipped_live), do: "Skipped · Live"
  defp status_label(:skipped_members), do: "Skipped · Members"
  defp status_label(:skipped_manual), do: "Turned off"
  defp status_label(:skipped_cutoff), do: "Skipped · Cutoff"
  defp status_label(:skipped_duration), do: "Skipped · Length"
  defp status_label(:skipped_title), do: "Skipped · Title"
  defp status_label(:skipped_profile_only), do: "Skipped · Profile"

  defp status_kind(:downloaded), do: :ok
  defp status_kind(:downloading), do: :accent
  defp status_kind(:pending), do: :info
  defp status_kind(:retrying), do: :warn
  defp status_kind(:failed), do: :bad
  defp status_kind(:prevented), do: :warn
  defp status_kind(_skipped), do: :neutral

  defp year_toggle_class(:on), do: "bg-ok/15 text-ok hover:bg-ok/25"
  defp year_toggle_class(:mixed), do: "bg-warn/15 text-warn hover:bg-warn/25"
  defp year_toggle_class(:off), do: "bg-surface-2 text-muted hover:bg-surface-3"

  defp year_toggle_label(:on), do: "Monitored"
  defp year_toggle_label(:mixed), do: "Mixed"
  defp year_toggle_label(:off), do: "Unmonitored"

  defp year_toggle_title(:on), do: "Downloading this year's videos. Click to stop."
  defp year_toggle_title(:mixed), do: "Some of this year's videos are turned off. Click to turn the whole year off."
  defp year_toggle_title(:off), do: "Not downloading this year's videos. Click to start."
  defp compute_toggle_state(%{prevented: 0}), do: :on

  defp compute_toggle_state(%{prevented: prevented, total: total})
       when prevented == total,
       do: :off

  defp compute_toggle_state(_), do: :mixed
end
