defmodule PinchflatWeb.CustomComponents.TabComponents do
  @moduledoc false
  use Phoenix.Component

  @doc """
  Takes a list of tabs and renders them in a tabbed layout. The open tab is kept in the URL
  hash, and a LiveView can switch tabs with `push_event(socket, "switch-tab", %{tab: id})`.
  A tab can show a count badge.
  """
  slot :tab, required: true do
    attr :id, :string, required: true
    attr :title, :string, required: true
    attr :count, :integer
  end

  slot :tab_append, required: false

  def tabbed_layout(assigns) do
    assigns = Map.put(assigns, :first_tab_id, hd(assigns.tab).id)

    ~H"""
    <div
      x-data={"{ openTab: getTabFromHash('#{@first_tab_id}', '#{@first_tab_id}') }"}
      @hashchange.window={"openTab = getTabFromHash(openTab, '#{@first_tab_id}')"}
      class="w-full"
    >
      <header class="flex flex-col gap-2 border-b border-line md:flex-row md:items-center md:justify-between">
        <nav class="-mb-px flex flex-wrap gap-x-6" role="tablist">
          <a
            :for={tab <- @tab}
            href="#"
            role="tab"
            @click.prevent={"openTab = setTabByName('#{tab.id}')"}
            x-bind:aria-selected={"openTab === '#{tab.id}'"}
            x-bind:class={"openTab === '#{tab.id}' ? 'border-accent text-fg' : 'border-transparent text-muted hover:text-fg'"}
            class="inline-flex items-center gap-2 border-b-2 py-3 text-sm font-semibold transition-colors"
          >
            {tab.title}
            <span
              :if={tab[:count] not in [nil, 0]}
              class="tabular rounded-full bg-surface-2 px-2 py-0.5 text-xs font-semibold text-muted"
            >
              {tab.count}
            </span>
          </a>
        </nav>
        <div :if={@tab_append != []} class="flex items-center gap-4 pb-2 md:pb-0">
          {render_slot(@tab_append)}
        </div>
      </header>
      <div class="mt-4 min-h-40 overflow-x-auto">
        <div :for={tab <- @tab} x-show={"openTab === '#{tab.id}'"} role="tabpanel">
          {render_slot(tab)}
        </div>
      </div>
    </div>
    """
  end
end
