defmodule Pinchflat.Sources.Source do
  @moduledoc """
  The Source schema.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Pinchflat.Utils.ChangesetUtils

  alias __MODULE__
  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Metadata.SourceMetadata

  # ---------------------------------------------------------------------------
  # Client partition constants
  # IMPORTANT: These lists are empirically verified against the 2026.06.09 yt-dlp
  # binary. Re-verify after major yt-dlp updates by probing each client with:
  #   docker exec pinchfork yt-dlp -v --simulate --extractor-args \
  #     "youtube:player_client=<client>" <url> 2>&1 | grep -iE "sabr|po token|skipp"
  # Clean output = token-free. SABR/PO-token warnings = needs sidecar.
  # ---------------------------------------------------------------------------

  # Clients that accept account cookies — can reach members-only, age-restricted,
  # and private content when cookies are configured.
  @cookie_compatible_clients ~w(web web_safari web_creator mweb tv web_embedded web_music)

  # Clients that do NOT support account cookies — members-only and private content
  # will silently fail if cookies are expected. Setting client_override to any of
  # these while also enabling members videos or cookie behaviour is blocked at save.
  @cookie_incompatible_clients ~w(android ios android_vr tv_simply)

  @all_known_clients @cookie_compatible_clients ++ @cookie_incompatible_clients

  @doc """
  Returns all known client names. Used by DownloadOptionBuilder to validate
  chains before interpolating them into a yt-dlp command (injection safety).
  """
  def all_known_clients, do: @all_known_clients

  @doc """
  Returns true if the given client_override value supports account cookies.

  nil means "no override / use yt-dlp's adaptive default" and is considered
  cookie-compatible (the default clients can carry cookies).

  A comma-separated chain is cookie-compatible only if ALL legs are compatible.
  """
  def client_override_supports_cookies?(nil), do: true

  def client_override_supports_cookies?(override) when is_binary(override) do
    override
    |> String.split(",", trim: true)
    |> Enum.all?(&(&1 in @cookie_compatible_clients))
  end

  @allowed_fields ~w(
    enabled
    collection_name
    collection_id
    collection_type
    custom_name
    custom_name_locked
    description
    description_locked
    custom_poster_filepath
    nfo_filepath
    poster_filepath
    fanart_filepath
    banner_filepath
    series_directory
    index_frequency_minutes
    fast_index
    cookie_behaviour
    download_media
    last_indexed_at
    original_url
    download_cutoff_date
    retention_period_days
    title_filter_regex
    media_profile_id
    output_path_template_override
    marked_for_deletion_at
    min_duration_seconds
    max_duration_seconds
    download_public_videos
    download_members_videos
    client_override
  )a

  # Expensive API calls are made when a source is inserted/updated so
  # we want to ensure that the source is valid before making the call.
  # This way, we check that the other attributes are valid before ensuring
  # that all fields are valid. This is still only one DB insert but it's
  # a two-stage validation process to fail fast before the API call.
  @initially_required_fields ~w(
    index_frequency_minutes
    fast_index
    download_media
    original_url
    media_profile_id
  )a

  @pre_insert_required_fields @initially_required_fields ++
                                ~w(
                                  uuid
                                  custom_name
                                  collection_name
                                  collection_id
                                  collection_type
                                )a

  schema "sources" do
    field :enabled, :boolean, default: true
    # This is _not_ used as the primary key or internally in the database
    # relations. This is only used to prevent an enumeration attack on the streaming
    # and RSS feed endpoints since those _must_ be public (ie: no basic auth)
    field :uuid, Ecto.UUID

    field :custom_name, :string
    field :custom_name_locked, :boolean, default: false
    field :description, :string
    field :description_locked, :boolean, default: false
    field :custom_poster_filepath, :string
    field :collection_name, :string
    field :collection_id, :string
    field :collection_type, Ecto.Enum, values: [:channel, :playlist]
    field :index_frequency_minutes, :integer, default: 60 * 24
    field :fast_index, :boolean, default: false
    field :cookie_behaviour, Ecto.Enum, values: [:disabled, :when_needed, :all_operations], default: :disabled
    field :download_media, :boolean, default: true
    field :last_indexed_at, :utc_datetime
    # Only download media items that were published after this date
    field :download_cutoff_date, :date
    field :retention_period_days, :integer
    field :original_url, :string
    field :title_filter_regex, :string
    field :output_path_template_override, :string

    field :min_duration_seconds, :integer
    field :max_duration_seconds, :integer

    field :download_public_videos, :boolean, default: true
    field :download_members_videos, :boolean, default: false
    field :client_override, :string, default: nil

    field :series_directory, :string
    field :nfo_filepath, :string
    field :poster_filepath, :string
    field :fanart_filepath, :string
    field :banner_filepath, :string

    field :marked_for_deletion_at, :utc_datetime

    belongs_to :media_profile, MediaProfile

    has_one :metadata, SourceMetadata, on_replace: :update

    has_many :tasks, Task
    has_many :media_items, MediaItem, foreign_key: :source_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(source, attrs, validation_stage) do
    # See above for rationale
    required_fields =
      if validation_stage == :initial do
        @initially_required_fields
      else
        @pre_insert_required_fields
      end

    source
    |> cast(attrs, @allowed_fields)
    |> normalize_client_override()
    |> dynamic_default(:custom_name, fn cs -> get_field(cs, :collection_name) end)
    |> dynamic_default(:uuid, fn _ -> Ecto.UUID.generate() end)
    |> validate_required(required_fields)
    |> validate_title_regex()
    |> validate_min_and_max_durations()
    |> validate_number(:retention_period_days, greater_than_or_equal_to: 0)
    # Ensures it ends with `.{{ ext }}` or `.%(ext)s` or similar (with a little wiggle room)
    |> validate_format(:output_path_template_override, MediaProfile.ext_regex(), message: "must end with .{{ ext }}")
    |> validate_format(:original_url, youtube_channel_or_playlist_regex(), message: "must be a channel or playlist URL")
    |> validate_client_override()
    |> validate_client_cookie_coherence()
    |> cast_assoc(:metadata, with: &SourceMetadata.changeset/2, required: false)
    |> unique_constraint([:collection_id, :media_profile_id, :title_filter_regex], error_key: :original_url)
  end

  @doc false
  def index_frequency_when_fast_indexing do
    # 30 days in minutes
    60 * 24 * 30
  end

  @doc false
  def fast_index_frequency do
    # minutes
    10
  end

  @doc false
  def filepath_attributes do
    ~w(nfo_filepath fanart_filepath poster_filepath banner_filepath)a
  end

  @doc false
  def json_exluded_fields do
    ~w(__meta__ __struct__ metadata tasks media_items)a
  end

  def youtube_channel_or_playlist_regex do
    # Validate that the original URL is not a video URL
    # Also matches if the string does NOT contain youtube.com or youtu.be. This preserves my tenuous support
    # for non-youtube sources.
    ~r<^(?:(?!youtube\.com/(watch|shorts|embed)|youtu\.be).)*$>
  end

  # Normalise empty string to nil so client_override has one consistent "no override"
  # representation. The form can submit "" for the default/blank option.
  defp normalize_client_override(changeset) do
    case get_change(changeset, :client_override) do
      "" -> put_change(changeset, :client_override, nil)
      _ -> changeset
    end
  end

  # Validates that every comma-separated leg in client_override is a known client name.
  # Unknown/legacy values (e.g. old "tv_embedded") are rejected at save time rather than
  # silently falling through — the fallthrough is at the downloader level (injection safety),
  # but a saved unknown value is a config mistake worth surfacing.
  defp validate_client_override(changeset) do
    case get_field(changeset, :client_override) do
      nil ->
        changeset

      chain ->
        unknown_legs =
          chain
          |> String.split(",", trim: true)
          |> Enum.reject(&(&1 in @all_known_clients))

        if unknown_legs == [] do
          changeset
        else
          add_error(changeset, :client_override, "contains unknown client(s): #{Enum.join(unknown_legs, ", ")}")
        end
    end
  end

  # Hard block: if any leg of the override chain is cookie-incompatible AND the source
  # is configured to use cookies (members videos enabled OR cookie_behaviour is not
  # :disabled), reject the save with an explanatory error.
  #
  # Uses get_field (not get_change) so it sees unchanged-but-present DB values — a source
  # that already has members videos enabled will trip this if a cookie-incompatible client
  # is later applied, even if members_videos wasn't part of the current changeset.
  defp validate_client_cookie_coherence(changeset) do
    client_override = get_field(changeset, :client_override)
    members_enabled = get_field(changeset, :download_members_videos)
    cookie_behaviour = get_field(changeset, :cookie_behaviour)

    cookies_in_use = members_enabled == true || cookie_behaviour != :disabled
    incompatible_client = not Source.client_override_supports_cookies?(client_override)

    if cookies_in_use && incompatible_client do
      add_error(
        changeset,
        :client_override,
        "This video client doesn't support cookies, but this source uses them " <>
          "(members-only videos or a cookie behaviour other than Disabled). " <>
          "Choose a cookie-compatible client (web_creator, tv, mweb, web, or web_safari), " <>
          "or turn off members-only downloads and set Cookie Behaviour to Disabled."
      )
    else
      changeset
    end
  end

  defp validate_title_regex(%{changes: %{title_filter_regex: regex}} = changeset) when is_binary(regex) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT '' ~ $1", [regex]) do
      {:ok, _} -> changeset
      _ -> add_error(changeset, :title_filter_regex, "is invalid")
    end
  end

  defp validate_title_regex(changeset), do: changeset

  defp validate_min_and_max_durations(changeset) do
    min_duration = get_change(changeset, :min_duration_seconds)
    max_duration = get_change(changeset, :max_duration_seconds)

    case {min_duration, max_duration} do
      {min, max} when is_nil(min) or is_nil(max) -> changeset
      {min, max} when min >= max -> add_error(changeset, :max_duration_seconds, "must be greater than minumum duration")
      _ -> changeset
    end
  end

  defimpl Jason.Encoder, for: Source do
    def encode(value, opts) do
      value
      |> Repo.preload(:media_profile)
      |> Map.drop(Source.json_exluded_fields())
      |> Jason.Encode.map(opts)
    end
  end
end
