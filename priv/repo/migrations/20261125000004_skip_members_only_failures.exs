defmodule Pinchflat.Repo.Migrations.SkipMembersOnlyFailures do
  use Ecto.Migration

  # Members-only videos that failed with yt-dlp's members-only error on sources that don't
  # download members-only videos were never wanted: mark them skipped (policy_members), like
  # MediaDownloadWorker now does, so they leave the Failed list. last_error is kept.
  def up do
    execute("""
    UPDATE media_items mi
    SET error_type = NULL,
        download_prevented_reason = 'policy_members',
        availability = 'subscriber_only',
        prevent_download = true
    FROM sources s
    WHERE s.id = mi.source_id
      AND s.download_members_videos = false
      AND mi.media_filepath IS NULL
      AND mi.error_type = 'permanent'
      AND (mi.last_error LIKE '%This video is available to this channel''s members%'
           OR mi.last_error LIKE '%members-only%')
    """)
  end

  # Nothing to undo: the old state was a mislabel, and last_error still records the error.
  def down, do: :ok
end
