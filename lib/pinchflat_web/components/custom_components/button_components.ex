defmodule PinchflatWeb.CustomComponents.ButtonComponents do
  @moduledoc false
  use Phoenix.Component, global_prefixes: ~w(x-)

  alias PinchflatWeb.CoreComponents
  alias PinchflatWeb.CustomComponents.TextComponents

  @doc """
  Render a button.

  `color` takes a background class. `bg-primary` (the default) renders the brand button with
  the theme's on-accent text; any other background gets the normal text color.
  `rounding` is accepted for older callers but every button now uses the same radius.

  ## Examples

      <.button>Save</.button>
      <.button color="bg-meta-4 hover:bg-meta-3">Cancel</.button>
  """
  attr :color, :string, default: "bg-primary"
  attr :rounding, :string, default: "rounded-lg"
  attr :class, :string, default: ""
  attr :type, :string, default: "submit"
  attr :disabled, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  def button(assigns) do
    assigns = assign(assigns, :text_color, text_color_for(assigns.color))

    ~H"""
    <button
      class={[
        "inline-flex h-10 items-center justify-center gap-2 whitespace-nowrap rounded-lg px-4",
        "text-center text-sm font-semibold transition-colors",
        @color,
        @text_color,
        "hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50",
        @class
      ]}
      type={@type}
      disabled={@disabled}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp text_color_for(color) do
    cond do
      String.contains?(color, ["bg-primary", "bg-accent"]) -> "text-onaccent"
      # Danger buttons (bg-red-*, bg-danger) are dark enough for white text in both themes
      String.contains?(color, ["bg-red", "bg-danger", "bg-bad"]) -> "text-[#ffffff]"
      true -> "text-fg border border-line"
    end
  end

  @doc """
  Render a dropdown based off a button

  ## Examples

      <.button_dropdown text="Actions">
        <:option>TEST</:option>
      </.button_dropdown>
  """
  attr :text, :string, required: true
  attr :class, :string, default: ""

  slot :option, required: true

  def button_dropdown(assigns) do
    ~H"""
    <div x-data="{ dropdownOpen: false }" class={["relative flex", @class]}>
      <button
        type="button"
        x-on:click.prevent="dropdownOpen = !dropdownOpen"
        x-bind:aria-expanded="dropdownOpen"
        class={[
          "inline-flex h-10 cursor-pointer items-center gap-2 rounded-lg border border-line bg-surface px-4",
          "text-sm font-semibold text-fg hover:bg-surface-2"
        ]}
      >
        {@text}
        <CoreComponents.icon
          name="hero-chevron-down"
          class="h-4 w-4 duration-200 ease-linear"
          x-bind:class="dropdownOpen && 'rotate-180'"
        />
      </button>
      <div
        x-cloak
        x-show="dropdownOpen"
        x-on:click.outside="dropdownOpen = false"
        class="absolute right-0 top-full z-40 mt-2 min-w-full rounded-xl border border-line bg-surface p-1.5 shadow-xl"
      >
        <ul class="flex flex-col">
          <li :for={option <- @option}>
            <span class="flex cursor-pointer whitespace-nowrap rounded-md px-3 py-2 text-sm text-fg hover:bg-surface-2">
              {render_slot(option)}
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Render a button with an icon. Optionally include a tooltip.

  ## Examples

      <.icon_button icon_name="hero-check" tooltip="Complete" />
  """
  attr :icon_name, :string, required: true
  attr :class, :string, default: ""
  attr :tooltip, :string, default: nil
  attr :rest, :global

  def icon_button(assigns) do
    ~H"""
    <TextComponents.tooltip position="bottom" tooltip={@tooltip} tooltip_class="text-nowrap">
      <button
        class={[
          "flex items-center justify-center rounded-lg border border-line bg-surface-2",
          "text-fg transition-colors hover:bg-surface-3",
          @class
        ]}
        type="button"
        aria-label={@tooltip}
        {@rest}
      >
        <CoreComponents.icon name={@icon_name} />
      </button>
    </TextComponents.tooltip>
    """
  end
end
