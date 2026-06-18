defmodule Pinchflat.Repo.Migrations.BumpObanToV12 do
  use Ecto.Migration

  # Oban schema v11 pins the oban_jobs priority_range CHECK constraint to (0..3).
  # MediaDownloadWorker (and other workers) use priority: 5, so on any database
  # created at v11 every Oban.insert for those workers silently fails the constraint
  # — the job is never written, no task is created, and the error is swallowed by the
  # Enum.each in enqueue_pending_download_tasks. Downloads appear to "kick off" in the
  # logs but nothing is ever enqueued.
  #
  # Oban schema v12 widens priority_range to (0..9), which is what these workers expect.
  # Bumping to v12 fixes fresh deployments and heals existing installs on next migrate.
  def up do
    Oban.Migration.up(version: 12)
  end

  def down do
    Oban.Migration.down(version: 11)
  end
end
