defmodule PinchflatWeb.Layouts do
  use PinchflatWeb, :html

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Utils.TtlCache

  embed_templates "layouts/*"
  embed_templates "layouts/partials/*"

  @doc """
  Collects everything the app shell (sidebar and header) needs, for both controller-rendered
  pages (which have a conn) and LiveViews (which don't).

  Returns map()
  """
  def shell_assigns(assigns) do
    conn = assigns[:conn]

    %{
      current_path: if(conn, do: Phoenix.Controller.current_path(conn), else: assigns[:current_path] || ""),
      params: if(conn, do: conn.params, else: %{}),
      current_user: assigns[:current_user] || (conn && conn.assigns[:current_user]),
      running_count: running_count(),
      discovery_enabled: setting(:discovery_enabled, true),
      yt_dlp_version: setting(:yt_dlp_version, "unknown")
    }
  end

  @doc """
  Number of background jobs executing right now, cached for a few seconds so pages that
  re-render often don't query the database each time.

  Returns integer()
  """
  def running_count do
    TtlCache.fetch(:running_job_count, 5_000, fn ->
      Repo.one(from j in Oban.Job, where: j.state == "executing", select: count(j.id))
    end)
  rescue
    _ -> 0
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, nil} -> default
      {:ok, value} -> value
      _ -> default
    end
  end

  @doc """
  Renders a top-level sidebar link. `match` is the path prefix that marks it as active.
  """
  attr :icon, :string, required: true
  attr :text, :string, required: true
  attr :href, :any, required: true
  attr :current_path, :string, required: true
  attr :match, :string, required: true
  attr :badge, :integer, default: 0

  def nav_item(assigns) do
    assigns = assign(assigns, :active, active?(assigns.current_path, assigns.match))

    ~H"""
    <li>
      <.link href={@href} class={["pf-nav-link", @active && "pf-nav-link-active"]} aria-current={@active && "page"}>
        <.icon name={@icon} class={["h-5 w-5", @active && "text-accent"]} />
        <span class="flex-1">{@text}</span>
        <span :if={@badge > 0} class="tabular rounded-full bg-accent px-2 py-0.5 text-xs font-semibold text-onaccent">
          {@badge}
        </span>
      </.link>
    </li>
    """
  end

  @doc """
  Renders a sidebar group with sub-links. It starts open when the current page is inside it.
  """
  attr :icon, :string, required: true
  attr :text, :string, required: true
  attr :current_path, :string, required: true
  attr :matches, :list, required: true

  slot :item, required: true do
    attr :text, :string
    attr :href, :any
    attr :match, :string
  end

  def nav_group(assigns) do
    open = Enum.any?(assigns.matches, &active?(assigns.current_path, &1))
    assigns = assign(assigns, :open, open)

    ~H"""
    <li x-data={"{ open: #{@open} }"}>
      <button type="button" class="pf-nav-link w-full" x-on:click="open = !open" x-bind:aria-expanded="open">
        <.icon name={@icon} class={["h-5 w-5", @open && "text-accent"]} />
        <span class="flex-1 text-left">{@text}</span>
        <.icon name="hero-chevron-down" class="h-4 w-4 transition-transform" x-bind:class="open && 'rotate-180'" />
      </button>
      <ul x-cloak x-show="open" class="mt-1 mb-2 ml-5 flex flex-col gap-0.5 border-l border-line pl-3">
        <li :for={item <- @item}>
          <.link
            href={item[:href]}
            class={[
              "block rounded-md px-3 py-1.5 text-sm transition-colors",
              if(active?(@current_path, item[:match]),
                do: "font-semibold text-accent",
                else: "text-muted hover:bg-surface-2 hover:text-fg"
              )
            ]}
          >
            {item[:text]}
          </.link>
        </li>
      </ul>
    </li>
    """
  end

  defp active?(nil, _), do: false
  defp active?(_, nil), do: false

  defp active?(current_path, match) do
    current_path == match or String.starts_with?(current_path, match <> "/")
  end
end
