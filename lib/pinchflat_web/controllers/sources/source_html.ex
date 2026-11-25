defmodule PinchflatWeb.Sources.SourceHTML do
  use PinchflatWeb, :html

  embed_templates "source_html/*"

  @doc """
  Renders a source form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true
  attr :media_profiles, :list, required: true
  attr :method, :string, required: true

  def source_form(assigns)

  def friendly_index_frequencies do
    [
      {"Only once when first created", -1},
      {"30 minutes", 30},
      {"1 Hour", 60},
      {"3 Hours", 3 * 60},
      {"6 Hours", 6 * 60},
      {"12 Hours", 12 * 60},
      {"Daily (recommended)", 24 * 60},
      {"Weekly", 7 * 24 * 60},
      {"Monthly", 30 * 24 * 60}
    ]
  end

  def friendly_cookie_behaviours do
    [
      {"Disabled", :disabled},
      {"When Needed", :when_needed},
      {"All Operations", :all_operations}
    ]
  end

  def cutoff_date_presets do
    [
      {"7 days", compute_date_offset(7)},
      {"14 days", compute_date_offset(14)},
      {"30 days", compute_date_offset(30)},
      {"60 days", compute_date_offset(60)},
      {"90 days", compute_date_offset(90)},
      {"180 days", compute_date_offset(180)},
      {"365 days", compute_date_offset(365)}
    ]
  end

  def rss_feed_url(conn, source) do
    # NOTE: The reason for this concatenation is to avoid what appears to be a bug in Phoenix
    # See: https://github.com/phoenixframework/phoenix/issues/6033
    url(conn, ~p"/sources/#{source.uuid}/feed") <> ".xml"
  end

  def opml_feed_url(conn) do
    url(conn, ~p"/sources/opml.xml?#{[route_token: Settings.get!(:route_token)]}")
  end

  def output_path_template_override_placeholders(media_profiles) do
    media_profiles
    |> Enum.map(&{&1.id, &1.output_path_template})
    |> Map.new()
    |> Phoenix.json_library().encode!()
  end

  def title_filter_regex_help do
    url = "https://github.com/nalgeon/sqlean/blob/main/docs/regexp.md#supported-syntax"
    classes = "underline decoration-bodydark decoration-1 hover:decoration-white"

    """
    A PCRE-compatible regex. Only media with titles that match this regex will be downloaded. <a href="#{url}" class="#{classes}" target="_blank">See here</a> for syntax
    """
  end

  def output_path_template_override_help do
    help_button_classes = "underline decoration-bodydark decoration-1 hover:decoration-white cursor-pointer"
    help_button = ~s{<span class="#{help_button_classes}" x-on:click="$dispatch('load-template')">Click here</span>}

    """
    Must end with .{{ ext }}. Same rules as Media Profile output path templates. #{help_button} to load your media profile's output template
    """
  end

  @doc """
  A labelled count for the source page's summary row.
  """
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :help, :string, required: true
  attr :class, :string, default: nil

  def count_card(assigns) do
    ~H"""
    <div class="pf-card px-4 py-3">
      <div class="text-xs font-medium text-muted">{@label}</div>
      <div class={["tabular mt-0.5 text-2xl font-semibold tracking-tight", @class || "text-fg"]}>
        <.localized_number number={@value} />
      </div>
      <div class="mt-0.5 text-[11px] leading-4 text-muted">{@help}</div>
    </div>
    """
  end

  @doc """
  Groups skip reasons by what decides them, so the card can link to the right place:
  the media profile (Shorts, livestreams) or the source's own settings.
  """
  def group_skip_reasons(reasons) do
    reasons
    |> Enum.group_by(fn {reason, _count} -> skip_reason_owner(reason) end)
    |> Enum.sort_by(fn {owner, _} -> Enum.find_index([:profile, :source, :other], &(&1 == owner)) end)
  end

  defp skip_reason_owner(reason) when reason in [:short, :livestream, :profile_only], do: :profile
  defp skip_reason_owner(reason) when reason in [:members, :public, :cutoff, :duration, :title], do: :source
  defp skip_reason_owner(_reason), do: :other

  def skip_reason_text(:short, 1), do: "1 Short"
  def skip_reason_text(:short, n), do: "#{n} Shorts"
  def skip_reason_text(:livestream, 1), do: "1 livestream"
  def skip_reason_text(:livestream, n), do: "#{n} livestreams"
  def skip_reason_text(:profile_only, n), do: "#{n} regular #{plural(n, "video")}"
  def skip_reason_text(:members, n), do: "#{n} members-only"
  def skip_reason_text(:public, n), do: "#{n} public #{plural(n, "video")}"
  def skip_reason_text(:cutoff, n), do: "#{n} before the cutoff date"
  def skip_reason_text(:duration, n), do: "#{n} too short or too long"
  def skip_reason_text(:title, n), do: "#{n} not matching the title filter"
  def skip_reason_text(_other, n), do: "#{n} for other reasons"

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  @doc """
  The "keep my version" switch next to a name or description, so a refresh from YouTube
  doesn't overwrite what the user wrote.
  """
  attr :field, Phoenix.HTML.FormField, required: true

  def lock_switch(assigns) do
    assigns = assign(assigns, :checked, Phoenix.HTML.Form.normalize_value("checkbox", assigns.field.value))

    ~H"""
    <label
      class="inline-flex cursor-pointer items-center gap-2 text-[13px] text-muted"
      title="When on, refreshing from YouTube won't change this"
    >
      <input type="hidden" name={@field.name} value="false" />
      <input type="checkbox" id={@field.id} name={@field.name} value="true" checked={@checked} class="peer sr-only" />
      <.icon name="hero-lock-closed-mini" class="h-4 w-4 peer-checked:text-accent" /> Keep when refreshing
      <span class="relative h-5 w-9 rounded-full bg-surface-3 transition-colors peer-checked:bg-accent peer-checked:[&>span]:translate-x-4 peer-focus-visible:ring-2 peer-focus-visible:ring-accent/50">
        <span class="absolute left-0.5 top-0.5 h-4 w-4 rounded-full bg-[#ffffff] shadow transition-transform"></span>
      </span>
    </label>
    """
  end

  def menu_item_class do
    "flex items-center gap-2.5 rounded-lg px-3 py-2 text-left text-sm text-fg hover:bg-surface-2"
  end

  @job_labels %{
    "FastIndexingWorker" => "Checking for new uploads",
    "MediaCollectionIndexingWorker" => "Full scan",
    "MediaDownloadWorker" => "Downloading a video",
    "SourceMetadataStorageWorker" => "Fetching artwork and description",
    "FileSyncingWorker" => "Checking files on disk",
    "MediaQualityUpgradeWorker" => "Upgrading video quality",
    "SourceDeletionWorker" => "Deleting the source"
  }

  @doc """
  A plain-language name for a background job, from its Oban worker module name.
  """
  def job_label(worker) do
    short = worker |> String.split(".") |> List.last()

    Map.get_lazy(@job_labels, short, fn ->
      short
      |> String.replace_suffix("Worker", "")
      |> Macro.underscore()
      |> String.replace("_", " ")
      |> String.capitalize()
    end)
  end

  def job_state_label("executing"), do: "Running"
  def job_state_label("available"), do: "Queued"
  def job_state_label("scheduled"), do: "Scheduled"
  def job_state_label("retryable"), do: "Will retry"
  def job_state_label(state), do: state |> to_string() |> String.capitalize()

  def job_state_kind("executing"), do: :accent
  def job_state_kind("available"), do: :info
  def job_state_kind("retryable"), do: :warn
  def job_state_kind(_), do: :neutral

  @doc """
  "3 h ago" style relative time for recent events, a date for older ones.
  """
  def time_ago(%DateTime{} = time) do
    seconds = DateTime.diff(DateTime.utc_now(), time)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      seconds < 2 * 86_400 -> "yesterday"
      seconds < 30 * 86_400 -> "#{div(seconds, 86_400)} days ago"
      true -> Calendar.strftime(time, "%-d %b %Y")
    end
  end

  def time_ago(%NaiveDateTime{} = time), do: time |> DateTime.from_naive!("Etc/UTC") |> time_ago()

  defp compute_date_offset(days) do
    timezone = Application.get_env(:pinchflat, :timezone)

    timezone
    |> Timex.now()
    |> Timex.shift(days: -days)
    |> Timex.format!("{YYYY}-{0M}-{0D}")
  end
end
