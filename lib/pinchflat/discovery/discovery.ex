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
  Gets a single suggestion from an untrusted id (e.g. a LiveView event param).

  Returns %DiscoverySuggestion{} | nil
  """
  def get_suggestion(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} -> Repo.get(DiscoverySuggestion, int_id)
      _ -> nil
    end
  end

  @doc """
  Creates or updates a suggestion by channel_id (upsert).
  If the channel already exists, refreshes its metadata/score/provenance. `status` is never
  in the replace list, so a dismissed or accepted suggestion keeps its status.

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
      conflict_target: :channel_id
    )
  end

  @doc """
  Brings suggestion status in line with the user's actual sources:

    * pending suggestions whose channel is now a source are marked "accepted"
      (covers channels added by hand as well as via the Discovery accept flow), and
    * "accepted" suggestions whose channel is NOT a source go back to "pending" — the user
      clicked Accept but never finished creating the source, so it should resurface.

  Cheap (two UPDATEs); called before each scan and whenever the Discovery page loads.

  Returns {accepted_count, reopened_count}
  """
  def reconcile_with_sources do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()

    source_channel_ids =
      from(s in Pinchflat.Sources.Source, where: not is_nil(s.collection_id), select: s.collection_id)

    {accepted, _} =
      from(d in DiscoverySuggestion, where: d.status == "pending" and d.channel_id in subquery(source_channel_ids))
      |> Repo.update_all(set: [status: "accepted", updated_at: now])

    {reopened, _} =
      from(d in DiscoverySuggestion,
        where: d.status == "accepted" and d.channel_id not in subquery(source_channel_ids)
      )
      |> Repo.update_all(set: [status: "pending", updated_at: now])

    {accepted, reopened}
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
  Returns lowercased identifiers (UC… channel ids and @handles) that a scan should not
  spend a yt-dlp validation call on: existing sources (by collection_id and by the @handle
  in their original_url) plus dismissed and accepted suggestions.

  Returns MapSet.t()
  """
  def excluded_identifiers do
    source_identifiers =
      from(s in Pinchflat.Sources.Source, select: {s.collection_id, s.original_url})
      |> Repo.all()
      |> Enum.flat_map(fn {collection_id, url} -> [collection_id, handle_from_url(url)] end)

    suggestion_ids =
      from(s in DiscoverySuggestion, where: s.status in ["dismissed", "accepted"], select: s.channel_id)
      |> Repo.all()

    (source_identifiers ++ suggestion_ids)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp handle_from_url(nil), do: nil

  defp handle_from_url(url) do
    case Regex.run(~r{youtube\.com/(@[^/?#]+)}i, url) do
      [_, handle] -> URI.decode(handle)
      _ -> nil
    end
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
