defmodule Pinchflat.Downloading.StagingCleaner do
  @moduledoc """
  Removes orphaned local temp-staging artifacts for a media item (fork-only feature).

  When local temp staging is enabled (`LOCALTEMP=true`), each download stages all of its
  intermediate work under a per-item directory keyed on `media_id`
  (`Pinchflat.Downloading.StagingPaths.staging_dir_for/1`). A failed, abandoned, or
  hard-crashed attempt can leave files behind in that directory -- fragments, a half-written
  `.temp.mp4`, a converted-but-not-embedded thumbnail, etc. If a later attempt finds those
  stale intermediates it can behave incorrectly (this is the class of failure that motivated
  the feature).

  Because staging is keyed on the unique `media_id`, clearing an item's orphans is just a
  recursive delete of that one directory. It can never touch another item's files (each
  in-flight download owns its own per-id directory), so there is no filename matching, no
  glob, and no concurrency hazard.

  All operations are:
    * NO-OPS when staging is disabled (there is no staging dir to clean), and
    * best-effort -- a cleanup failure must never raise or block a download. Failures are
      logged at debug and swallowed.
  """

  require Logger

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.StagingPaths

  @doc """
  True when local temp staging is enabled via the `LOCALTEMP` env var.
  """
  def enabled? do
    System.get_env("LOCALTEMP") == "true"
  end

  @doc """
  Removes the per-item staging directory for the given media item, clearing any orphaned
  intermediate files from a previous failed/abandoned attempt.

  No-op (returns `:ok`) when staging is disabled. Best-effort: never raises; logs at debug
  on failure. Deleting a non-existent directory is itself a successful no-op.

  Returns `:ok`.
  """
  def clean(%MediaItem{} = media_item) do
    if enabled?() do
      dir = StagingPaths.staging_dir_for(media_item)

      case File.rm_rf(dir) do
        {:ok, _removed} ->
          :ok

        {:error, reason, file} ->
          Logger.debug("StagingCleaner: best-effort cleanup of #{dir} hit #{inspect(reason)} on #{file}; ignoring")

          :ok
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.debug("StagingCleaner: unexpected error during cleanup, ignoring: #{inspect(error)}")
      :ok
  end
end
