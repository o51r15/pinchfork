defmodule Pinchflat.Repo.Migrations.ScopedBackfillClientOverride do
  use Ecto.Migration

  @moduledoc """
  Scoped backfill of the client_override column.

  Resets rows that are in an invalid or legacy state to the safe default chain
  "web_creator,tv" — both clients are empirically clean + cookie-capable on the
  2026.06.09 yt-dlp binary.

  Three cases are covered by a single UPDATE:

  1. Unknown/legacy client values (e.g. old "tv_embedded", which was removed from
     yt-dlp's client roster). These are no longer valid and would fall through to
     no override in the downloader, silently doing nothing.

  2. Forbidden combos: a cookie-incompatible client (android, ios, android_vr,
     tv_simply) paired with either members-only downloads enabled OR a cookie
     behaviour other than 'disabled'. These sources would silently fail to
     authenticate for gated content. Resetting them to the safe chain restores
     the intended behaviour.

  3. Plain nil rows are DELIBERATELY LEFT UNTOUCHED. nil means "no override,
     let yt-dlp use its adaptive default" — public-only sources are fine as-is
     and should not be pinned to a specific chain unnecessarily.

  This migration is intentionally UP-ONLY. The reset cannot cleanly be undone
  because the pre-migration values were already invalid or unknown — reverting
  would restore broken state. The down/0 is a documented no-op.

  If you need to manually inspect affected rows before this runs, execute:
    SELECT id, client_override, download_members_videos, cookie_behaviour
    FROM sources
    WHERE client_override IS NOT NULL
      AND (
        client_override NOT IN (
          'web', 'web_safari', 'web_creator', 'mweb', 'tv',
          'web_embedded', 'web_music',
          'android', 'ios', 'android_vr', 'tv_simply'
        )
        OR (
          client_override IN ('android', 'ios', 'android_vr', 'tv_simply')
          AND (
            download_members_videos = true
            OR cookie_behaviour <> 'disabled'
          )
        )
      );
  """

  def up do
    execute("""
    UPDATE sources
    SET client_override = 'web_creator,tv'
    WHERE client_override IS NOT NULL
      AND (
        -- Case 1: unknown/legacy client value no longer in the known roster
        client_override NOT IN (
          'web', 'web_safari', 'web_creator', 'mweb', 'tv',
          'web_embedded', 'web_music',
          'android', 'ios', 'android_vr', 'tv_simply'
        )
        OR
        -- Case 2: cookie-incompatible client paired with cookie-dependent settings
        (
          client_override IN ('android', 'ios', 'android_vr', 'tv_simply')
          AND (
            download_members_videos = true
            OR cookie_behaviour <> 'disabled'
          )
        )
      )
    """)
  end

  # Intentional no-op: the pre-migration values were invalid or legacy and
  # restoring them would put sources back into a broken state. If a rollback
  # is needed, restore from a database backup taken before this migration ran.
  def down do
    :ok
  end
end
