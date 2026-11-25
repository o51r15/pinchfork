defmodule Pinchflat.Settings.Setting do
  @moduledoc """
  The Setting schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @allowed_fields [
    :onboarding,
    :pro_enabled,
    :yt_dlp_version,
    :apprise_version,
    :apprise_server,
    :video_codec_preference,
    :audio_codec_preference,
    :youtube_api_key,
    :extractor_sleep_interval_seconds,
    :download_throughput_limit,
    :restrict_filenames,
    :discovery_enabled,
    :discovery_g1_enabled,
    :discovery_g2_enabled,
    :discovery_g3_enabled,
    :discovery_g4_enabled,
    :discovery_disabled_clusters,
    :default_client_enabled,
    :default_client
  ]

  @required_fields [
    :onboarding,
    :pro_enabled,
    :video_codec_preference,
    :audio_codec_preference,
    :extractor_sleep_interval_seconds
  ]

  schema "settings" do
    field :onboarding, :boolean, default: true
    field :pro_enabled, :boolean, default: false
    field :yt_dlp_version, :string
    field :apprise_version, :string
    field :apprise_server, :string
    field :youtube_api_key, :string
    field :route_token, :string
    field :extractor_sleep_interval_seconds, :integer, default: 0
    # This is a string because it accepts values like "100K" or "4.2M"
    field :download_throughput_limit, :string
    field :restrict_filenames, :boolean, default: false

    field :video_codec_preference, :string
    field :audio_codec_preference, :string

    # Discovery settings
    field :discovery_enabled, :boolean, default: false
    field :discovery_g1_enabled, :boolean, default: true
    field :discovery_g2_enabled, :boolean, default: true
    field :discovery_g3_enabled, :boolean, default: true
    field :discovery_g4_enabled, :boolean, default: true
    field :discovery_disabled_clusters, {:array, :string}, default: []

    # Video client for sources that don't choose their own. See Sources.effective_client/2.
    field :default_client_enabled, :boolean, default: false
    field :default_client, :string, default: "web_creator,tv"
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @allowed_fields)
    |> validate_required(@required_fields)
    |> validate_number(:extractor_sleep_interval_seconds, greater_than_or_equal_to: 0)
    # yt-dlp's --limit-rate format: a number with an optional K, M or G suffix
    |> validate_format(:download_throughput_limit, ~r/\A\d+(\.\d+)?[KMG]?\z/i,
      message: "use a number with K, M or G, like 500K or 4.2M"
    )
    |> validate_required([:default_client])
    |> validate_default_client()
  end

  # Same rule as a source's own client: every leg must be a known client name
  defp validate_default_client(changeset) do
    validate_change(changeset, :default_client, fn :default_client, chain ->
      unknown =
        chain |> String.split(",", trim: true) |> Enum.reject(&(&1 in Pinchflat.Sources.Source.all_known_clients()))

      cond do
        String.split(chain, ",", trim: true) == [] -> [default_client: "choose a client"]
        unknown != [] -> [default_client: "contains unknown client(s): #{Enum.join(unknown, ", ")}"]
        true -> []
      end
    end)
  end
end
