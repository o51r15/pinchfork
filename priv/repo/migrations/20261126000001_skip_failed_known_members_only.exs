defmodule Pinchflat.Repo.Migrations.SkipFailedKnownMembersOnly do
  use Ecto.Migration

  # Like 20261125000004, for videos already known to be members-only (availability) that failed
  # with another permanent error, such as "Video unavailable", on sources that don't download
  # members-only videos: they're skipped (policy_members), not failed. last_error is kept.
  def up do
    execute("""
    UPDATE media_items mi
    SET error_type = NULL,
        download_prevented_reason = 'policy_members',
        prevent_download = true
    FROM sources s
    WHERE s.id = mi.source_id
      AND s.download_members_videos = false
      AND mi.media_filepath IS NULL
      AND mi.error_type = 'permanent'
      AND mi.availability IN ('subscriber_only', 'premium_only', 'needs_auth')
    """)
  end

  def down, do: :ok
end
