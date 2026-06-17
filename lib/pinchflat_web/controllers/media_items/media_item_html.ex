defmodule PinchflatWeb.MediaItems.MediaItemHTML do
  use PinchflatWeb, :html

  embed_templates "media_item_html/*"

  @doc """
  Renders a media item form.
  """
  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true

  def media_item_form(assigns)

  def media_file_exists?(media_item) do
    !!media_item.media_filepath and File.exists?(media_item.media_filepath)
  end

  def media_type(media_item) do
    case Path.extname(media_item.media_filepath) do
      ext when ext in [".mp4", ".webm", ".mkv"] -> :video
      ext when ext in [".mp3", ".m4a", ".opus"] -> :audio
      _ -> :unknown
    end
  end

  @doc """
  Human-readable label for a media_item's `download_prevented_reason`.

  The full set of reason values written across the app is:
    - "permanent_error" (action_on_error permanent branch, media_download_worker)
    - "manual"          (UI delete-with-prevent, media_item_controller)
    - "user_script"     (pre-download script exit != 0, media_download_worker)
    - "policy_public" / "policy_members" / "policy_other"
                        (availability policy, slow_indexing_helpers)

  Returns "" for nil/unknown so the show-page section can rely on
  `prevent_download` for visibility and still render gracefully if a reason
  was never recorded (e.g. items prevented before this field existed).
  """
  def format_prevention_reason("permanent_error"), do: "Permanent download failure"
  def format_prevention_reason("manual"), do: "Manually blocked"
  def format_prevention_reason("user_script"), do: "Blocked by pre-download script"
  def format_prevention_reason("policy_public"), do: "Public videos are disabled for this source"
  def format_prevention_reason("policy_members"), do: "Members-only content is disabled for this source"
  def format_prevention_reason("policy_other"), do: "Private, unlisted, or otherwise unavailable"
  def format_prevention_reason(_), do: "Downloads are disabled for this item"
end
