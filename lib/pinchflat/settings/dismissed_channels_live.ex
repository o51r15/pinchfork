defmodule Pinchflat.Settings.DismissedChannelsLive do
  use PinchflatWeb, :live_view

  alias Pinchflat.Discovery

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_dismissed(socket)}
  end

  @impl true
  def handle_event("restore", %{"id" => id}, socket) do
    with %{} = suggestion <- Discovery.get_suggestion(id),
         {:ok, _} <- Discovery.restore_suggestion(suggestion) do
      {:noreply, load_dismissed(socket)}
    else
      _ -> {:noreply, load_dismissed(socket)}
    end
  end

  defp load_dismissed(socket) do
    dismissed = Discovery.list_suggestions("dismissed")
    assign(socket, dismissed: dismissed)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mt-6">
      <h4 class="text-lg text-black dark:text-white mb-2">Dismissed Channels</h4>
      <p :if={@dismissed == []} class="text-sm text-bodydark2">No dismissed channels.</p>
      <ul :if={@dismissed != []} class="space-y-2">
        <li :for={s <- @dismissed} class="flex items-center justify-between rounded bg-meta-4/30 px-3 py-2">
          <div>
            <a href={s.url} target="_blank" class="text-sm font-medium text-white hover:underline">
              {s.name || s.channel_id}
            </a>
            <span :if={s.subscriber_count} class="ml-2 text-xs text-bodydark2">
              ({format_subs(s.subscriber_count)} subs)
            </span>
          </div>
          <button phx-click="restore" phx-value-id={s.id} class="rounded px-3 py-1 text-xs text-meta-3 hover:bg-meta-3/10">
            Restore
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp format_subs(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_subs(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_subs(n), do: "#{n}"
end
