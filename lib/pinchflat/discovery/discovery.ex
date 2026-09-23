defmodule Pinchflat.Discovery do
  @moduledoc """
  Context module for AI Discovery — suggests new YouTube channels based on the
  user's existing library.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Discovery.DiscoverySuggestion

  @doc """
  Returns all suggestions with the given status, ordered by score descending.

  Returns [%DiscoverySuggestion{}, ...]
  """
  def list_suggestions(status \\ "pending") do
    from(s in DiscoverySuggestion,
      where: s.status == ^status,
      order_by: [desc: s.score]
    )
    |> Repo.all()
  end

  @doc """
  Returns N random pending suggestions for display on the Discovery page.
  """
  def list_random_suggestions(count \\ 10) do
    from(s in DiscoverySuggestion,
      where: s.status == "pending",
      order_by: fragment("RANDOM()"),
      limit: ^count
    )
    |> Repo.all()
  end

  @doc """
  Returns the total count of pending suggestions.
  """
  def pending_suggestion_count do
    from(s in DiscoverySuggestion, where: s.status == "pending", select: count())
    |> Repo.one()
  end

  @doc """
  Gets a single suggestion.

  Returns %DiscoverySuggestion{}. Raises `Ecto.NoResultsError` if not found.
  """
  def get_suggestion!(id), do: Repo.get!(DiscoverySuggestion, id)

  @doc """
  Creates or updates a suggestion by channel_id (upsert).
  If the channel already exists, updates score/provenance/status fields.

  Returns {:ok, %DiscoverySuggestion{}} | {:error, %Ecto.Changeset{}}
  """
  def upsert_suggestion(attrs) do
    %DiscoverySuggestion{}
    |> DiscoverySuggestion.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :name,
           :description,
           :thumbnail_url,
           :subscriber_count,
           :video_count,
           :last_upload_at,
           :cluster,
           :reason,
           :provenance,
           :score,
           :scanned_at,
           :updated_at
         ]},
      conflict_target: :channel_id,
      # Don't overwrite a dismissed suggestion
      where: [status: "pending"]
    )
  end

  @doc """
  Marks a suggestion as accepted. The caller should then redirect to source creation
  with the channel info prefilled.

  Returns {:ok, %DiscoverySuggestion{}} | {:error, %Ecto.Changeset{}}
  """
  def accept_suggestion(%DiscoverySuggestion{} = suggestion) do
    suggestion
    |> DiscoverySuggestion.changeset(%{status: "accepted"})
    |> Repo.update()
  end

  @doc """
  Marks a suggestion as dismissed. Dismissed channels won't resurface in future scans.

  Returns {:ok, %DiscoverySuggestion{}} | {:error, %Ecto.Changeset{}}
  """
  def restore_suggestion(%DiscoverySuggestion{} = suggestion) do
    suggestion
    |> DiscoverySuggestion.changeset(%{status: "pending"})
    |> Repo.update()
  end

  def dismiss_suggestion(%DiscoverySuggestion{} = suggestion) do
    suggestion
    |> DiscoverySuggestion.changeset(%{status: "dismissed"})
    |> Repo.update()
  end

  @doc """
  Returns a list of channel_ids that should be excluded from scan results
  (already a source, or previously dismissed).

  Returns MapSet.t()
  """
  def excluded_channel_ids do
    source_ids =
      from(s in Pinchflat.Sources.Source, select: s.collection_id)
      |> Repo.all()
      |> MapSet.new()

    dismissed_ids =
      from(s in DiscoverySuggestion, where: s.status == "dismissed", select: s.channel_id)
      |> Repo.all()
      |> MapSet.new()

    MapSet.union(source_ids, dismissed_ids)
  end

  @doc """
  Returns whether discovery is enabled and which generators are active.

  Returns %{enabled: boolean, generators: %{g1: boolean, g2: boolean, g3: boolean, g4: boolean},
            disabled_clusters: [String.t()]}
  """
  def discovery_settings do
    case Settings.get(:discovery_enabled) do
      {:ok, enabled} ->
        %{
          enabled: enabled,
          generators: %{
            g1: get_setting(:discovery_g1_enabled, true),
            g2: get_setting(:discovery_g2_enabled, true),
            g3: get_setting(:discovery_g3_enabled, true),
            g4: get_setting(:discovery_g4_enabled, true)
          },
          disabled_clusters: get_setting(:discovery_disabled_clusters, []) || []
        }

      _ ->
        %{enabled: false, generators: %{g1: true, g2: true, g3: true, g4: true}, disabled_clusters: []}
    end
  end

  defp get_setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _ -> default
    end
  end
end
