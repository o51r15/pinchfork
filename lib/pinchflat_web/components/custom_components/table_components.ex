defmodule PinchflatWeb.CustomComponents.TableComponents do
  @moduledoc false
  use Phoenix.Component

  import PinchflatWeb.CoreComponents
  import PinchflatWeb.CustomComponents.TextComponents

  @doc """
  Renders a table component with the given rows and columns.

  ## Examples

      <.table rows={@users}>
        <:col :let={user} label="Name"><%= user.name %></:col>
      </.table>
  """
  attr :rows, :list, required: true
  attr :table_class, :string, default: ""
  attr :sort_key, :string, default: nil
  attr :sort_direction, :string, default: nil

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
    attr :sort_key, :string
  end

  def table(assigns) do
    ~H"""
    <table class={["w-full table-auto text-sm text-fg", @table_class]}>
      <thead>
        <tr class="text-left">
          <th
            :for={col <- @col}
            class={[
              "whitespace-nowrap px-3 py-2 text-xs font-medium uppercase tracking-wide text-muted first:pl-0",
              col[:sort_key] && "cursor-pointer select-none hover:text-fg"
            ]}
            phx-click={col[:sort_key] && "sort_update"}
            phx-value-sort_key={col[:sort_key]}
          >
            <span class="inline-flex items-center gap-1">
              {col[:label]}
              <.icon
                :if={to_string(@sort_key) == col[:sort_key]}
                name={if @sort_direction == :asc, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
                class="h-3.5 w-3.5"
              />
            </span>
          </th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows} class="border-t border-line transition-colors hover:bg-surface-2/60">
          <td
            :for={col <- @col}
            class={[
              "px-3 py-2.5 first:pl-0",
              col[:class]
            ]}
          >
            {render_slot(col, @row_item.(row))}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders simple pagination controls for a table in a liveview.

  ## Examples

      <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
  """
  attr :page_number, :integer, default: 1
  attr :total_pages, :integer, default: 1

  def live_pagination_controls(assigns) do
    ~H"""
    <nav aria-label="Pages">
      <ul class="flex flex-wrap items-center gap-1 text-sm text-muted">
        <li>
          <span
            class={[
              "pagination-prev flex h-8 w-8 items-center justify-center rounded-lg border border-line",
              @page_number != 1 && "cursor-pointer text-fg hover:bg-surface-2",
              @page_number <= 1 && "cursor-not-allowed opacity-40"
            ]}
            phx-click={@page_number != 1 && "page_change"}
            phx-value-direction="dec"
          >
            <.icon name="hero-chevron-left-mini" class="h-4 w-4" />
          </span>
        </li>
        <li>
          <span class="tabular mx-2">
            Page <.localized_number number={@page_number} /> of <.localized_number number={@total_pages} />
          </span>
        </li>
        <li>
          <span
            class={[
              "pagination-next flex h-8 w-8 items-center justify-center rounded-lg border border-line",
              @page_number != @total_pages && "cursor-pointer text-fg hover:bg-surface-2",
              @page_number >= @total_pages && "cursor-not-allowed opacity-40"
            ]}
            phx-click={@page_number != @total_pages && "page_change"}
            phx-value-direction="inc"
          >
            <.icon name="hero-chevron-right-mini" class="h-4 w-4" />
          </span>
        </li>
      </ul>
    </nav>
    """
  end
end
