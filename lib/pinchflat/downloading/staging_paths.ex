defmodule Pinchflat.Downloading.StagingPaths do
  @moduledoc """
  Single source of truth for the local temp-staging directory layout (fork-only feature,
  gated on the `LOCALTEMP` env var elsewhere).

  When local temp staging is enabled, every yt-dlp download stages its intermediate work
  (fragments, stream merge, the [FixupM3u8] `.temp.mp4`, and every post-processor temp file
  such as the convert/embed thumbnail) under a PER-ITEM directory keyed on the media item's
  globally-unique `media_id` (the YouTube id). yt-dlp recreates the relative output subtree
  inside that per-id directory for intermediates, then moves the finished files to their real
  final location. The final on-disk layout under the downloads directory is unchanged.

  Keying on `media_id` (rather than the output filename) is deliberate: the predicted filename
  drifts between index time and download time (the `media_upload_date_index` template token is
  recomputed when more same-day uploads are discovered), and yt-dlp's own `after_move:filepath`
  is documented to be unreliable. `media_id` never drifts and is globally unique, so:

    * `DownloadOptionBuilder` points yt-dlp's `temp:` at `staging_dir_for/1`, and
    * `StagingCleaner` removes exactly that directory to clear orphans,

  both deriving the identical path from this module. Because each in-flight download owns its
  own per-id directory, cleanup is a trivial, collision-proof directory wipe -- it can never
  touch a concurrently-downloading item's files. (Concurrent downloads of the SAME media_id are
  impossible: all downloads funnel through `MediaDownloadWorker`, which is `unique` on the job
  args for the active states, so a normal/forced/quality-upgrade download for one id can't
  overlap with another for the same id.)

  The hardcoded base mirrors the container path bind-mounted to a local host disk in the
  compose file (`/downloads-staging`).
  """

  alias Pinchflat.Media.MediaItem

  @staging_base "/downloads-staging"

  @doc """
  Returns the base staging directory (the local-disk mount point). All per-item staging
  directories live directly beneath this.
  """
  def staging_base, do: @staging_base

  @doc """
  Returns the per-item staging directory for a media item:
  `/downloads-staging/<sanitized media_id>`.

  The media_id is sanitized so it can never escape the staging base or produce an
  unintended nested path -- only `[A-Za-z0-9._-]` are kept and any other character
  (path separators, whitespace, etc.) is replaced with `_`. YouTube ids are already in
  this safe set; the sanitization defensively covers the "tenuous non-YouTube source"
  case so a malformed id can never turn a later `rm_rf` into something destructive.
  """
  def staging_dir_for(%MediaItem{media_id: media_id}) do
    Path.join(@staging_base, sanitize(media_id))
  end

  defp sanitize(nil), do: "_unknown"

  defp sanitize(media_id) when is_binary(media_id) do
    case String.replace(media_id, ~r/[^A-Za-z0-9._-]/, "_") do
      # Guard against a value that sanitizes to empty, "." or ".." -- any of which would
      # resolve to the staging base itself or its parent. Never allow that.
      sanitized when sanitized in ["", ".", ".."] -> "_unknown"
      sanitized -> sanitized
    end
  end

  defp sanitize(media_id), do: sanitize(to_string(media_id))
end
