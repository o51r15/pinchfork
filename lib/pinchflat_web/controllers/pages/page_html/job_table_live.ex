defmodule Pinchflat.Pages.JobTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Tasks.TasksQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task
  alias PinchflatWeb.CustomComponents.TextComponents

  def render(%{tasks: []} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 rounded-lg border border-dashed border-line px-4 py-6 text-sm text-muted">
      <.icon name="hero-pause-circle" class="h-5 w-5 shrink-0" />
      Nothing is running right now. Downloads and scans show up here while they work.
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <table class="w-full text-sm">
      <thead>
        <tr class="text-left text-xs font-medium uppercase tracking-wide text-muted">
          <th class="py-2 pr-3 font-medium">Job</th>
          <th class="px-3 py-2 font-medium">Item</th>
          <th class="px-3 py-2 font-medium">Attempt</th>
          <th class="py-2 pl-3 font-medium">Started</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={task <- @tasks} class="border-t border-line">
          <td class="whitespace-nowrap py-2.5 pr-3">
            <span class="inline-flex items-center gap-2 text-fg">
              <span class="h-2 w-2 shrink-0 animate-pulse rounded-full bg-accent"></span>
              {PinchflatWeb.Sources.SourceHTML.job_label(task.job.worker)}
            </span>
          </td>
          <td class="max-w-md truncate px-3 py-2.5">
            <.link href={task_to_link(task)} class="text-fg hover:text-accent">{task_to_record_name(task)}</.link>
          </td>
          <td class="tabular px-3 py-2.5 text-muted">{task.job.attempt}</td>
          <td class="whitespace-nowrap py-2.5 pl-3 text-muted">{format_datetime(task.job.attempted_at)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  def mount(_params, _session, socket) do
    PinchflatWeb.Endpoint.subscribe("job:state")

    {:ok, assign(socket, tasks: get_tasks())}
  end

  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    {:noreply, assign(socket, tasks: get_tasks())}
  end

  @doc """
  How many dashboard-visible jobs are running, for the Activity tab badge.
  """
  def running_count do
    tasks_query() |> Repo.aggregate(:count)
  end

  defp get_tasks do
    tasks_query()
    |> order_by([t, j], desc: j.attempted_at)
    |> Repo.all()
    |> Repo.preload([:media_item, :source])
  end

  defp tasks_query do
    TasksQuery.new()
    |> TasksQuery.join_job()
    |> where(^TasksQuery.in_state("executing"))
    |> where(^TasksQuery.has_tag("show_in_dashboard"))
  end

  defp task_to_record_name(%Task{} = task) do
    case task do
      %Task{source: source} when source != nil -> source.custom_name
      %Task{media_item: mi} when mi != nil -> mi.title
      _ -> "Unknown Record"
    end
  end

  defp task_to_link(%Task{} = task) do
    case task do
      %Task{source: source} when source != nil -> ~p"/sources/#{source.id}"
      %Task{media_item: mi} when mi != nil -> ~p"/sources/#{mi.source_id}/media/#{mi}"
      _ -> "#"
    end
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end
end
