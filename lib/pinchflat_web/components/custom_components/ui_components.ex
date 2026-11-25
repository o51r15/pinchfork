defmodule PinchflatWeb.CustomComponents.UiComponents do
  @moduledoc """
  Shared building blocks for the redesigned UI: page headers, cards, settings rows, status
  chips, stats, empty states and the setup wizard's step indicator. New pages should be
  built from these rather than hand-written class lists.
  """

  use Phoenix.Component, global_prefixes: ~w(x-)

  alias PinchflatWeb.CoreComponents

  @setup_steps ~w(Account Storage YouTube Profile Source Done)

  def setup_step_names, do: @setup_steps

  @doc """
  The Pinchfork mark: a three-tine pitchfork whose handle ends in a download arrow, on a
  rounded teal square. The same drawing is priv/static/images/pinchfork-mark.svg (favicon).
  """
  attr :class, :string, default: "h-7 w-7"

  def brand_mark(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 64 64" aria-hidden="true">
      <rect width="64" height="64" rx="15" class="fill-accent" />
      <path
        d="M20 10 V21 Q20 30 32 30 Q44 30 44 21 V10 M32 10 V52 M24 44.5 L32 53 L40 44.5"
        class="stroke-onaccent"
        stroke-width="5"
        fill="none"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  @doc """
  The setup wizard's progress bar. `current` is the zero-based index of the active step.
  """
  attr :current, :integer, required: true

  def setup_steps(assigns) do
    assigns = assign(assigns, :steps, Enum.with_index(@setup_steps))

    ~H"""
    <ol class="flex w-full gap-1.5" aria-label="Setup steps">
      <li :for={{name, index} <- @steps} class="flex flex-1 flex-col gap-1.5" aria-current={index == @current && "step"}>
        <span class={["h-1 rounded-full", if(index <= @current, do: "bg-accent", else: "bg-surface-3")]}></span>
        <span class={["text-xs font-medium", if(index <= @current, do: "text-fg", else: "text-muted")]}>
          {name}
        </span>
      </li>
    </ol>
    """
  end

  @doc """
  A page title with an optional description and action buttons on the right.
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :actions
  slot :inner_block

  def page_header(assigns) do
    ~H"""
    <div class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div class="min-w-0 flex-1">
        <h1 class="text-2xl font-semibold tracking-tight text-fg">{@title}</h1>
        <p :if={@description} class="mt-1 max-w-3xl text-sm leading-6 text-muted">{@description}</p>
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  A bordered surface for grouped content, with an optional heading row.
  """
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section class={["pf-card", @class]} {@rest}>
      <div :if={@title} class="flex flex-wrap items-start justify-between gap-3 px-5 pt-4 pb-3">
        <div>
          <h2 class="text-base font-semibold text-fg">{@title}</h2>
          <p :if={@description} class="mt-0.5 text-[13px] leading-5 text-muted">{@description}</p>
        </div>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  One setting inside a card: label and help on the left, the control on the right. Shows an
  "environment" tag when the value is set by a Docker variable and can't be changed here.
  """
  attr :label, :string, required: true
  attr :help, :string, default: nil
  attr :for, :string, default: nil
  attr :env, :string, default: nil, doc: "name of the env var that controls this setting"
  slot :inner_block, required: true

  def settings_row(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-x-8 gap-y-3 border-t border-line px-5 py-4">
      <div class="min-w-[220px] max-w-sm flex-1">
        <label for={@for} class="text-sm font-medium text-fg">{@label}</label>
        <p :if={@help} class="mt-1 text-[13px] leading-5 text-muted">{@help}</p>
        <p :if={@env} class="mt-1.5">
          <span class="pf-chip border border-line font-medium text-muted">
            Set by environment · <code class="font-mono">{@env}</code>
          </span>
        </p>
      </div>
      <div class="min-w-[260px] flex-[1.4]">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  The Sonarr-style "unsaved changes" bar for settings pages. It sits at the bottom of the page
  and only shows when something has changed. The buttons target a form by id, so the bar can
  live outside the form it saves.
  """
  attr :form, :string, required: true, doc: "id of the form to submit"
  attr :dirty, :boolean, required: true
  attr :discard_event, :string, default: "discard"

  def save_bar(assigns) do
    ~H"""
    <div class="pointer-events-none sticky bottom-4 z-10 mt-6 flex justify-center" aria-live="polite">
      <div
        :if={@dirty}
        id={"#{@form}-save-bar"}
        class="pointer-events-auto flex w-full max-w-2xl items-center gap-3 rounded-xl border border-line bg-surface-3/95 px-4 py-3 shadow-lg backdrop-blur"
      >
        <CoreComponents.icon name="hero-pencil-square" class="h-5 w-5 shrink-0 text-accent" />
        <span class="flex-1 text-sm font-medium text-fg">You have unsaved changes</span>
        <button
          type="button"
          phx-click={@discard_event}
          class="inline-flex h-9 items-center rounded-lg px-3 text-sm font-semibold text-muted hover:bg-surface-2 hover:text-fg"
        >
          Discard
        </button>
        <button
          type="submit"
          form={@form}
          phx-disable-with="Saving…"
          class="inline-flex h-9 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-onaccent hover:opacity-90"
        >
          Save changes
        </button>
      </div>
    </div>
    """
  end

  @doc """
  A small status pill. `kind` picks the color.
  """
  attr :kind, :atom, default: :neutral, values: [:ok, :accent, :warn, :bad, :neutral, :info]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def status_chip(assigns) do
    ~H"""
    <span class={["pf-chip", chip_class(@kind), @class]}>{render_slot(@inner_block)}</span>
    """
  end

  defp chip_class(:ok), do: "bg-ok/15 text-ok"
  defp chip_class(:accent), do: "bg-accent-soft text-accent"
  defp chip_class(:warn), do: "bg-warn/15 text-warn"
  defp chip_class(:bad), do: "bg-bad/15 text-bad"
  defp chip_class(:info), do: "bg-info/15 text-info"
  defp chip_class(:neutral), do: "bg-surface-2 text-muted"

  @doc """
  A labelled number, for summary strips.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: nil

  def stat(assigns) do
    ~H"""
    <div class="pf-card px-4 py-3">
      <div class="text-xs font-medium text-muted">{@label}</div>
      <div class={["tabular mt-0.5 text-2xl font-semibold tracking-tight", @class || "text-fg"]}>{@value}</div>
    </div>
    """
  end

  @doc """
  What to show when a list is empty: an icon, a sentence and usually one action.
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-3 px-6 py-14 text-center">
      <span class="grid h-12 w-12 place-items-center rounded-full bg-surface-2">
        <CoreComponents.icon name={@icon} class="h-6 w-6 text-muted" />
      </span>
      <h3 class="text-base font-semibold text-fg">{@title}</h3>
      <p :if={@description} class="max-w-md text-sm leading-6 text-muted">{@description}</p>
      <div :if={@actions != []} class="mt-1 flex gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end
end
