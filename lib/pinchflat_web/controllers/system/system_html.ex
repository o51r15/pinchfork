defmodule PinchflatWeb.System.SystemHTML do
  use PinchflatWeb, :html

  embed_templates "system_html/*"

  @doc """
  One line of the Status page's health panel: what it is, whether it's fine, and details.
  """
  attr :icon, :string, required: true
  attr :name, :string, required: true
  attr :state, :atom, values: [:ok, :warn, :bad], required: true
  attr :status, :string, required: true
  attr :rest, :global
  slot :inner_block
  slot :action

  def health_row(assigns) do
    ~H"""
    <li class="flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-line px-5 py-4" {@rest}>
      <span class={["grid h-9 w-9 shrink-0 place-items-center rounded-lg", state_bg(@state)]}>
        <.icon name={@icon} class="h-5 w-5" />
      </span>
      <div class="min-w-[220px] flex-1">
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-sm font-semibold text-fg">{@name}</span>
          <.status_chip kind={@state}>{@status}</.status_chip>
        </div>
        <div class="mt-0.5 text-[13px] text-muted">{render_slot(@inner_block)}</div>
      </div>
      <div :if={@action != []} class="shrink-0">{render_slot(@action)}</div>
    </li>
    """
  end

  defp state_bg(:ok), do: "bg-ok/15 text-ok"
  defp state_bg(:warn), do: "bg-warn/15 text-warn"
  defp state_bg(:bad), do: "bg-bad/15 text-bad"

  # Under 5% or 20 GB free is a problem; under 15% is worth a look
  defdelegate disk_state(disk), to: Pinchflat.Health

  def disk_bar_class(disk) do
    case disk_state(disk) do
      :bad -> "bg-bad"
      :warn -> "bg-warn"
      :ok -> "bg-accent"
    end
  end

  def human_bytes(nil), do: "0 B"
  def human_bytes(bytes) when bytes >= 1_000_000_000_000, do: "#{Float.round(bytes / 1_000_000_000_000, 1)} TB"
  def human_bytes(bytes) when bytes >= 1_000_000_000, do: "#{Float.round(bytes / 1_000_000_000, 1)} GB"
  def human_bytes(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  def human_bytes(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  def human_bytes(bytes), do: "#{bytes} B"

  defdelegate time_ago(time), to: PinchflatWeb.Sources.SourceHTML

  @doc """
  Shell commands in a box with a Copy button. Each command is one line.
  """
  attr :commands, :list, required: true
  attr :id, :string, required: true

  def command_block(assigns) do
    assigns = assign(assigns, :text, Enum.join(assigns.commands, "\n"))

    ~H"""
    <div class="relative rounded-lg border border-line bg-surface-2" id={@id} x-data="{ copied: false }">
      <pre class="whitespace-pre-wrap break-all px-4 py-3 pr-20 font-mono text-[13px] leading-6 text-fg"><code>{@text}</code></pre>
      <button
        type="button"
        class="absolute right-2 top-2 inline-flex h-7 items-center gap-1 rounded-md border border-line bg-surface px-2 text-xs font-semibold text-fg hover:bg-surface-3"
        x-on:click={"navigator.clipboard.writeText(#{Jason.encode!(@text)}).then(() => { copied = true; setTimeout(() => copied = false, 2000) })"}
      >
        <.icon name="hero-clipboard-document-mini" class="h-3.5 w-3.5" />
        <span x-text="copied ? 'Copied' : 'Copy'">Copy</span>
      </button>
    </div>
    """
  end

  @doc """
  What YT_DLP_VERSION means for how yt-dlp stays current.
  """
  def yt_dlp_policy_text(policy) when policy in ["stable", ""], do: "Updates itself daily to the latest stable release."
  def yt_dlp_policy_text("nightly"), do: "Updates itself daily to the latest nightly build."
  def yt_dlp_policy_text("master"), do: "Updates itself daily to the latest master build."

  def yt_dlp_policy_text(policy) when policy in ["pinned", "none"],
    do: "Automatic updates are off (YT_DLP_VERSION=#{policy})."

  def yt_dlp_policy_text(version), do: "Pinned to #{version} by YT_DLP_VERSION."

  def total_size(backups), do: backups |> Enum.map(& &1.size_bytes) |> Enum.sum() |> human_bytes()

  def about_rows(about) do
    [
      {"Pinchfork", "v#{about.pinchfork_version}"},
      {"Based on Pinchflat", about.pinchflat_upstream},
      {"Elixir", about.elixir_version},
      {"Erlang/OTP", about.otp_version},
      {"yt-dlp", about.yt_dlp_version}
    ]
  end
end
