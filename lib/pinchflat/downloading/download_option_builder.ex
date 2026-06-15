defmodule Pinchflat.Downloading.DownloadOptionBuilder do
  @moduledoc """
  Builds the options for yt-dlp to download media based on the given media profile.
  """

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.OutputPathBuilder
  alias Pinchflat.Downloading.QualityOptionBuilder
  alias Pinchflat.Downloading.StagingPaths

  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @doc """
  Builds the options for yt-dlp to download media based on the given media's profile.

  Returns {:ok, [Keyword.t()]}
  """
  def build(%MediaItem{} = media_item_with_preloads, override_opts \\ []) do
    media_profile = media_item_with_preloads.source.media_profile

    built_options =
      default_options(override_opts) ++
        subtitle_options(media_profile) ++
        thumbnail_options(media_item_with_preloads) ++
        metadata_options(media_profile) ++
        quality_options(media_profile) ++
        sponsorblock_options(media_profile) ++
        output_options(media_item_with_preloads) ++
        client_override_options(media_item_with_preloads.source) ++
        pot_provider_options() ++
        download_resilience_options() ++
        config_file_options(media_item_with_preloads)

    {:ok, apply_local_staging(built_options, media_item_with_preloads)}
  end

  @doc """
  Builds the output path for yt-dlp to download media based on the given source's
  or media_item's media profile. Uses the source's override output path template if it exists.

  Accepts a %MediaItem{} or %Source{} struct. If a %Source{} struct is passed, it
  will use a default %MediaItem{} struct with the given source.

  Returns binary()
  """
  def build_output_path_for(%Source{} = source_with_preloads) do
    build_output_path_for(%MediaItem{source: source_with_preloads})
  end

  def build_output_path_for(%MediaItem{} = media_item_with_preloads) do
    output_path_template = Sources.output_path_template(media_item_with_preloads.source)

    build_output_path(output_path_template, media_item_with_preloads)
  end

  @doc """
  Builds the quality options for yt-dlp to download media based on the given source's
  or media_item's media profile. Useful for helping predict final filepath of downloaded
  media.

  returns [Keyword.t()]
  """
  def build_quality_options_for(%Source{} = source_with_preloads) do
    build_quality_options_for(%MediaItem{source: source_with_preloads})
  end

  def build_quality_options_for(%MediaItem{} = media_item_with_preloads) do
    media_profile = media_item_with_preloads.source.media_profile

    quality_options(media_profile)
  end

  defp default_options(override_opts) do
    overwrite_behaviour = Keyword.get(override_opts, :overwrite_behaviour, :force_overwrites)

    [
      :no_progress,
      overwrite_behaviour,
      # This makes the date metadata conform to what jellyfin expects
      parse_metadata: "%(upload_date>%Y-%m-%d)s:(?P<meta_date>.+)"
    ]
  end

  defp subtitle_options(media_profile) do
    mapped_struct = Map.from_struct(media_profile)

    Enum.reduce(mapped_struct, [], fn attr, acc ->
      case {attr, media_profile} do
        {{:download_subs, true}, _} ->
          # Force SRT for now - MAY provide as an option in the future
          acc ++ [:write_subs, convert_subs: "srt"]

        {{:download_auto_subs, true}, %{download_subs: true}} ->
          acc ++ [:write_auto_subs]

        {{:download_auto_subs, true}, %{embed_subs: true}} ->
          acc ++ [:write_auto_subs]

        {{:embed_subs, true}, %{preferred_resolution: pr}} when pr != :audio ->
          acc ++ [:embed_subs]

        {{:sub_langs, sub_langs}, %{download_subs: true}} ->
          acc ++ [sub_langs: sub_langs]

        {{:sub_langs, sub_langs}, %{embed_subs: true}} ->
          acc ++ [sub_langs: sub_langs]

        _ ->
          acc
      end
    end)
  end

  defp thumbnail_options(media_item_with_preloads) do
    media_profile = media_item_with_preloads.source.media_profile
    mapped_struct = Map.from_struct(media_profile)

    Enum.reduce(mapped_struct, [], fn attr, acc ->
      case attr do
        {:download_thumbnail, true} ->
          thumbnail_save_location = determine_thumbnail_location(media_item_with_preloads)

          acc ++ [:write_thumbnail, convert_thumbnail: "jpg", output: "thumbnail:#{thumbnail_save_location}"]

        {:embed_thumbnail, true} ->
          acc ++ [:embed_thumbnail, convert_thumbnail: "jpg"]

        _ ->
          acc
      end
    end)
  end

  defp metadata_options(media_profile) do
    mapped_struct = Map.from_struct(media_profile)

    Enum.reduce(mapped_struct, [], fn attr, acc ->
      case attr do
        {:download_metadata, true} -> acc ++ [:write_info_json, :clean_info_json]
        {:embed_metadata, true} -> acc ++ [:embed_metadata]
        _ -> acc
      end
    end)
  end

  defp quality_options(media_profile) do
    QualityOptionBuilder.build(media_profile)
  end

  defp sponsorblock_options(media_profile) do
    categories = media_profile.sponsorblock_categories
    behaviour = media_profile.sponsorblock_behaviour

    case {behaviour, categories} do
      {_, []} -> []
      {:remove, _} -> [sponsorblock_remove: Enum.join(categories, ",")]
      {:mark, _} -> [sponsorblock_mark: Enum.join(categories, ",")]
      {:disabled, _} -> []
    end
  end

  # This is put here instead of the CommandRunner module because it should only
  # be applied to downloading - if it were in CommandRunner it would apply to
  # all yt-dlp commands (like indexing)
  defp config_file_options(media_item) do
    base_dir = Path.join(Application.get_env(:pinchflat, :extras_directory), "yt-dlp-configs")
    # Ordered by priority - the first file has the highest priority
    filenames = [
      "media-item-#{media_item.id}-config.txt",
      "source-#{media_item.source_id}-config.txt",
      "media-profile-#{media_item.source.media_profile_id}-config.txt",
      "base-config.txt"
    ]

    config_filepaths =
      Enum.reduce(filenames, [], fn filename, acc ->
        filepath = Path.join(base_dir, filename)

        if FSUtils.exists_and_nonempty?(filepath) do
          [filepath | acc]
        else
          acc
        end
      end)

    Enum.map(config_filepaths, fn filepath -> {:config_locations, filepath} end)
  end

  defp output_options(media_item_with_preloads) do
    [
      output: build_output_path_for(media_item_with_preloads)
    ]
  end

  defp build_output_path(string, media_item_with_preloads) do
    additional_options_map = output_options_map(media_item_with_preloads)
    {:ok, output_path} = OutputPathBuilder.build(string, additional_options_map)

    Path.join(base_directory(), output_path)
  end

  defp output_options_map(media_item_with_preloads) do
    source = media_item_with_preloads.source

    %{
      "media_item_id" => to_string(media_item_with_preloads.id),
      "source_id" => to_string(source.id),
      "media_profile_id" => to_string(source.media_profile_id),
      "source_custom_name" => source.custom_name,
      "source_collection_id" => source.collection_id,
      "source_collection_name" => source.collection_name,
      "source_collection_type" => to_string(source.collection_type),
      "media_playlist_index" => pad_int(media_item_with_preloads.playlist_index),
      "media_upload_date_index" => pad_int(media_item_with_preloads.upload_date_index)
    }
  end

  # I don't love the string manipulation here, but what can ya' do.
  # It's dependent on the output_path_template being a string ending `.{{ ext }}`
  # (or equivalent), but that's validated by the MediaProfile schema.
  defp determine_thumbnail_location(media_item_with_preloads) do
    output_path_template = Sources.output_path_template(media_item_with_preloads.source)

    output_path_template
    |> String.split(~r{\.}, include_captures: true)
    |> List.insert_at(-3, "-thumb")
    |> Enum.join()
    |> build_output_path(media_item_with_preloads)
  end

  defp pad_int(integer, count \\ 2, padding \\ "0") do
    integer
    |> to_string()
    |> String.pad_leading(count, padding)
  end

  # When a source has client_override set, use an alternate yt-dlp player client.
  # The stored value is a comma-separated chain of client names (e.g. "web_creator,tv").
  # Multi-client chains make yt-dlp MERGE formats from all legs (not stop at the first),
  # so a fallback leg's formats stay available alongside the lead leg's — this is intentional,
  # not a bug. The chain REPLACES yt-dlp's adaptive default entirely (no `default,` prefix).
  #
  # Cookie-compatibility is enforced at the media_downloader level: any chain leg that is
  # in the cookie-incompatible set causes cookies to be disabled for that source.
  # See Source.client_override_supports_cookies?/1.
  #
  # The per-leg whitelist guard is intentional: only legs in @all_known_clients ever get
  # interpolated into the yt-dlp arg, so a stray/legacy stored value falls through to no
  # override rather than injecting arbitrary text into the command line.
  defp client_override_options(%{client_override: chain}) when is_binary(chain) do
    legs = String.split(chain, ",", trim: true)

    if legs != [] and Enum.all?(legs, &(&1 in Source.all_known_clients())) do
      [{:extractor_args, "youtube:player_client=#{Enum.join(legs, ",")}"}]
    else
      # Stray or fully-unknown chain: fall through to no override (injection-safe)
      []
    end
  end

  defp client_override_options(_source), do: []

  # Passes the bgutil POT provider base_url to yt-dlp so it knows where to fetch
  # GVS PO Tokens. Uses a separate extractor namespace (youtubepot-bgutilhttp:) from
  # the player_client arg (youtube:) — these MUST remain separate extractor_args entries;
  # do NOT merge them into a single string. yt-dlp accumulates repeated --extractor-args
  # flags, and the CommandRunner serializer emits each keyword-list entry as its own flag.
  # The sidecar container is reachable at bgutil-provider:4416 on the Docker internal network.
  defp pot_provider_options do
    [{:extractor_args, "youtubepot-bgutilhttp:base_url=http://bgutil-provider:4416"}]
  end

  # Hardens downloads against fragment truncation — the root cause of intermittent
  # "Postprocessing: Error opening input files: Invalid data found" failures. That error
  # is ffmpeg refusing to mux a video/audio file that arrived incomplete: a fragment came
  # back short or empty mid-download (common under load and over SABR streaming), so the
  # file on disk is corrupt before the merge step ever runs. A valid PO Token gets a valid
  # stream URL but does nothing for bytes dropped in transit — so this is a separate fix.
  #
  # - fragment_retries "infinite": never give up on an individual fragment (the single most
  #   important flag for this failure mode).
  # - retries 10 / file_access_retries 5: survive transient network and local FS hiccups.
  # - extractor_retries 3: retry the metadata/extraction step on transient extractor errors.
  # - abort_on_unavailable_fragment FALSE via :skip_unavailable_fragments is intentionally
  #   NOT set — we want a missing fragment to RETRY (and ultimately fail loudly so the item
  #   stays transient and re-queues), not to silently produce a file with a hole in it.
  #
  # Note on concurrency: this does not cap parallel fragments/downloads here. If truncation
  # persists under heavy queues, the lever is YT_DLP_WORKER_CONCURRENCY (worker count) and/or
  # a global rate limit in Settings — not a per-download flag. Kept out of scope deliberately.
  defp download_resilience_options do
    [
      {:fragment_retries, "infinite"},
      {:retries, 10},
      {:file_access_retries, 5},
      {:extractor_retries, 3}
    ]
  end

  # Stages ALL of yt-dlp's intermediate work — fragment downloads, the merge of separate
  # video+audio streams, the [FixupM3u8] .temp.mp4 write-then-rename used when YouTube forces
  # SABR down the HLS/m3u8 path, and every postprocessor temp file (thumbnail convert, metadata
  # embed, etc.) — on a LOCAL host disk. Only the finished files are moved to the final output
  # location, in a single move per file at the very end.
  #
  # WHY: the production downloads directory is an SMB-mounted network drive. The residual
  # "Postprocessing: Error opening input files: Invalid data found when processing input"
  # failures (~6%) only reproduce against that mount — every hand-run to local /tmp succeeded.
  # The working hypothesis is that the temp write/rename/reopen over SMB corrupts the
  # intermediate file mid-pipeline. Staging everything locally eliminates the mount as a
  # variable. This is deliberately a VARIABLE-ELIMINATION step, NOT a confirmed fix: if failures
  # vanish it confirms the SMB hypothesis; if they persist the mount is exonerated.
  #
  # HOW: yt-dlp's --paths (-P) accepts "home:<dir>" (where final files land) and "temp:<dir>"
  # (where all intermediates go, then move to home). CRUCIAL CONSTRAINT: --paths is silently
  # IGNORED if --output is an ABSOLUTE path (yt-dlp prints "WARNING: --paths is ignored since an
  # absolute path is given in output template"). Pinchflat builds absolute outputs
  # (Path.join(base_directory(), ...)), so to make staging actually take effect we must:
  #   1. pass the base dir as "home:<base>",
  #   2. rewrite every {:output, ...} entry to be RELATIVE to that base (strip the base prefix),
  #   3. pass "temp:<per-item staging dir>".
  # The temp dir is PER MEDIA_ID (StagingPaths.staging_dir_for/1 → /downloads-staging/<media_id>),
  # NOT a shared dir. This isolates every intermediate file for an item — including aux files like
  # the convert/embed thumbnail that orphaned in the 91289 case — under one directory keyed on the
  # globally-unique, drift-immune YouTube id. That makes orphan cleanup a trivial, collision-proof
  # directory wipe (StagingCleaner), with no filename matching and no risk of touching a concurrent
  # download's files. (yt-dlp recreates the relative output subtree INSIDE that per-id dir for
  # intermediates, then moves finished files to home: — final layout is unchanged.)
  # We do this transform HERE on the already-built options rather than changing build_output_path
  # itself, because build_output_path_for/1 is ALSO called by external callers (filepath
  # prediction, existence checks) that depend on it returning the ABSOLUTE final path. Those must
  # keep seeing absolute paths; only the yt-dlp command options get the relative+home treatment.
  #
  # Gated on LOCALTEMP=true. When absent, options pass through completely unchanged (true no-op).
  defp apply_local_staging(options, media_item) do
    if System.get_env("LOCALTEMP") == "true" do
      base = base_directory()
      temp_dir = StagingPaths.staging_dir_for(media_item)

      relative_options = Enum.map(options, fn opt -> relativize_output_option(opt, base) end)

      [{:paths, "home:#{base}"}, {:paths, "temp:#{temp_dir}"}] ++ relative_options
    else
      options
    end
  end

  # Rewrites an {:output, ...} option from absolute to relative-to-base so that yt-dlp's
  # --paths home:/temp: take effect. Handles both the plain video output ("/base/Chan/x.ext")
  # and typed outputs that carry a "<type>:" prefix ("thumbnail:/base/Chan/x-thumb.ext").
  # Non-output options, and output values that don't start with the base prefix, pass through
  # untouched.
  defp relativize_output_option({:output, value}, base) do
    {:output, relativize_output_value(value, base)}
  end

  defp relativize_output_option(other, _base), do: other

  defp relativize_output_value(value, base) do
    case String.split(value, ":", parts: 2) do
      # Typed output, e.g. "thumbnail:/base/..." — strip base from the path portion only,
      # preserving the "<type>:" prefix. yt-dlp output types are bare words (no "/"), so a
      # colon that appears inside a path/filename (e.g. "/base/Channel: News/x.ext") won't be
      # mistaken for a type prefix. Also guards against Windows-style "C:\..." for the same reason.
      [type, path] when path != "" and type != "" ->
        if not String.contains?(type, "/") and String.starts_with?(path, base) do
          "#{type}:#{strip_base(path, base)}"
        else
          value
        end

      # Plain output, e.g. "/base/Chan/x.ext"
      _ ->
        if String.starts_with?(value, base) do
          strip_base(value, base)
        else
          value
        end
    end
  end

  defp strip_base(path, base) do
    path
    |> String.replace_prefix(base, "")
    |> String.trim_leading("/")
  end

  defp base_directory do
    Application.get_env(:pinchflat, :media_directory)
  end
end
