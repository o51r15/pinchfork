defmodule PinchflatWeb.MediaItems.MediaItemHTML do
  use PinchflatWeb, :html

  alias Pinchflat.Utils.NumberUtils

  embed_templates "media_item_html/*"

  defdelegate time_ago(time), to: PinchflatWeb.Sources.SourceHTML
  defdelegate job_label(worker), to: PinchflatWeb.Sources.SourceHTML
  defdelegate job_state_label(state), to: PinchflatWeb.Sources.SourceHTML
  defdelegate job_state_kind(state), to: PinchflatWeb.Sources.SourceHTML
  defdelegate menu_item_class(), to: PinchflatWeb.Sources.SourceHTML

  def media_file_exists?(media_item) do
    !!media_item.media_filepath and File.exists?(media_item.media_filepath)
  end

  def thumbnail_exists?(media_item) do
    !!media_item.thumbnail_filepath and File.exists?(media_item.thumbnail_filepath)
  end

  def media_type(media_item) do
    case Path.extname(media_item.media_filepath) do
      ext when ext in [".mp4", ".webm", ".mkv", ".mov"] -> :video
      ext when ext in [".mp3", ".m4a", ".opus", ".ogg", ".flac", ".wav", ".aac"] -> :audio
      _ -> :unknown
    end
  end

  def stream_path(media_item) do
    ~p"/media/#{media_item.uuid}/stream?v=#{DateTime.to_unix(media_item.updated_at)}"
  end

  @doc """
  Human-readable label for a media_item's `download_prevented_reason`.

  The full set of reason values written across the app is:
    - "permanent_error" (action_on_error permanent branch, media_download_worker)
    - "manual"          (UI delete-with-prevent, media_item_controller)
    - "user_script"     (pre-download script exit != 0, media_download_worker)
    - "policy_public" / "policy_members" / "policy_other"
                        (availability policy, slow_indexing_helpers)

  Returns a generic line for nil/unknown so the page still reads well for items prevented
  before this field existed.
  """
  def format_prevention_reason("permanent_error"), do: "Permanent download failure"
  def format_prevention_reason("manual"), do: "Turned off by hand"
  def format_prevention_reason("user_script"), do: "Your pre-download script said no"
  def format_prevention_reason("policy_public"), do: "Public videos are turned off for this source"
  def format_prevention_reason("policy_members"), do: "Members-only videos are turned off for this source"
  def format_prevention_reason("policy_other"), do: "Private, unlisted, or otherwise unavailable"
  def format_prevention_reason(_), do: "Downloads are turned off for this video"

  @doc """
  The status chip for a video: {label, kind}.
  """
  def status_badge({:downloaded, _}), do: {"Downloaded", :ok}
  def status_badge({:failed, _}), do: {"Failed", :bad}
  def status_badge({:off, _}), do: {"Turned off", :warn}
  def status_badge({:pending, _}), do: {"Waiting", :info}
  def status_badge({:retrying, _}), do: {"Retrying", :warn}
  def status_badge({:removed, _}), do: {"Removed", :neutral}
  def status_badge({:skipped, _}), do: {"Skipped", :neutral}

  @doc """
  One plain sentence on why a video is where it is, or nil when there's nothing to explain.
  `profile` is the source's media profile name.
  """
  def status_text({:downloaded, _}, _profile), do: nil

  def status_text({:failed, _}, _profile),
    do: "Pinchfork stopped trying after an error it can't get past. Download now tries again."

  def status_text({:off, "manual"}, _profile),
    do: "Turned off, so Pinchfork won't download it. Turn on Download automatically below, or use Download now."

  def status_text({:off, "user_script"}, _profile),
    do: "Your pre-download script said not to download it. Download now skips that check."

  def status_text({:off, _}, _profile), do: "Downloads are turned off for this video."
  def status_text({:pending, _}, _profile), do: "Waiting for its turn in the download queue."
  def status_text({:retrying, _}, _profile), do: "The last try didn't work. Pinchfork will try again on its own."
  def status_text({:removed, nil}, _profile), do: "The file was removed by cleanup."

  def status_text({:removed, days}, _profile),
    do: "Deleted by cleanup: this source keeps downloads for #{days} #{plural(days, "day")}."

  def status_text({:skipped, reason}, profile), do: skip_text(reason, profile)

  defp skip_text(:short, profile), do: "It's a Short, and the #{profile} profile skips Shorts."
  defp skip_text(:livestream, profile), do: "It's a livestream, and the #{profile} profile skips livestreams."

  defp skip_text(:profile_only, profile),
    do: "The #{profile} profile only downloads Shorts or livestreams, and this is a regular video."

  defp skip_text(:members, _profile), do: "It's members-only, and this source doesn't download members-only videos."
  defp skip_text(:public, _profile), do: "It's a public video, and this source only downloads members-only videos."
  defp skip_text(:cutoff, _profile), do: "It was uploaded before this source's cutoff date."
  defp skip_text(:duration, _profile), do: "Its length is outside this source's shortest and longest limits."
  defp skip_text(:title, _profile), do: "Its title doesn't match this source's title filter."
  defp skip_text(:unavailable, _profile), do: "YouTube says it's private, unlisted, or no longer available."
  defp skip_text(_reason, _profile), do: "It doesn't match this source's download rules."

  @doc """
  Where to change what decided a skip: :profile, :source or nil.
  """
  def skip_owner({:skipped, reason}) when reason in [:short, :livestream, :profile_only], do: :profile
  def skip_owner({:skipped, reason}) when reason in [:members, :public, :cutoff, :duration, :title], do: :source
  def skip_owner(_status), do: nil

  def format_duration(nil), do: nil

  def format_duration(seconds) do
    {h, rest} = {div(seconds, 3600), rem(seconds, 3600)}
    {m, s} = {div(rest, 60), rem(rest, 60)}
    two = &String.pad_leading(to_string(&1), 2, "0")

    if h > 0, do: "#{h}:#{two.(m)}:#{two.(s)}", else: "#{m}:#{two.(s)}"
  end

  def human_size(nil), do: nil

  def human_size(bytes) do
    {value, suffix} = NumberUtils.human_byte_size(bytes, precision: 1)
    "#{value} #{suffix}"
  end

  @doc """
  The files a download left on disk, as [{label, path}].
  """
  def files(media_item) do
    subtitles =
      Enum.map(media_item.subtitle_filepaths || [], fn [lang, path] -> {"Subtitles (#{lang})", path} end)

    [
      {"Video", media_item.media_filepath},
      {"Thumbnail", media_item.thumbnail_filepath},
      {"Metadata", media_item.metadata_filepath},
      {"NFO", media_item.nfo_filepath}
    ]
    |> Kernel.++(subtitles)
    |> Enum.reject(fn {_, path} -> path in [nil, ""] end)
  end

  @doc """
  An on/off switch for a plain (non-LiveView) form. `on_value` is sent when it's on and
  `off_value` when it's off, so a switch can stand for the opposite of the field it sets.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :on_value, :string, required: true
  attr :off_value, :string, required: true
  attr :checked, :boolean, default: false

  def media_switch(assigns) do
    ~H"""
    <label class="relative inline-flex cursor-pointer items-center">
      <input type="hidden" name={@name} value={@off_value} />
      <input type="checkbox" id={@id} name={@name} value={@on_value} checked={@checked} role="switch" class="peer sr-only" />
      <span class="h-6 w-11 rounded-full bg-surface-3 transition-colors peer-checked:bg-accent peer-focus-visible:ring-2 peer-focus-visible:ring-accent/50">
      </span>
      <span class="absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-[#ffffff] shadow transition-transform peer-checked:translate-x-5">
      </span>
    </label>
    """
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
