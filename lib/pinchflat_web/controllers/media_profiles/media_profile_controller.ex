defmodule PinchflatWeb.MediaProfiles.MediaProfileController do
  use PinchflatWeb, :controller
  use Pinchflat.Sources.SourcesQuery
  use Pinchflat.Profiles.ProfilesQuery

  alias Pinchflat.Repo
  alias Pinchflat.Profiles
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Profiles.MediaProfileDeletionWorker

  def index(conn, _params) do
    media_profiles_query =
      from mp in MediaProfile,
        as: :media_profile,
        where: is_nil(mp.marked_for_deletion_at),
        order_by: [asc: mp.name],
        select: map(mp, ^MediaProfile.__schema__(:fields)),
        select_merge: %{
          source_count:
            subquery(
              from s in Source,
                where: s.media_profile_id == parent_as(:media_profile).id,
                select: count(s.id)
            )
        }

    render(conn, :index, media_profiles: Repo.all(media_profiles_query))
  end

  def show(conn, %{"id" => id}) do
    media_profile = Profiles.get_media_profile!(id)

    render(conn, :show, media_profile: media_profile, sources: sources_using(media_profile))
  end

  # A profile can only be deleted once nothing uses it. Deleting a profile used to take
  # every source (and optionally their files) with it, which was too easy to do by accident.
  # The show page lists the sources so they can be moved to another profile or deleted first.
  def delete(conn, %{"id" => id} = params) do
    # This awkward comparison converts the string to a boolean
    delete_files = Map.get(params, "delete_files", "") == "true"
    media_profile = Profiles.get_media_profile!(id)

    case sources_using(media_profile) do
      [] ->
        {:ok, _} = Profiles.update_media_profile(media_profile, %{marked_for_deletion_at: DateTime.utc_now()})
        MediaProfileDeletionWorker.kickoff(media_profile, %{delete_files: delete_files})

        conn
        |> put_flash(:info, "Media profile \"#{media_profile.name}\" deleted.")
        |> redirect(to: ~p"/media_profiles")

      sources ->
        conn
        |> put_flash(:error, in_use_message(length(sources)))
        |> redirect(to: ~p"/media_profiles/#{media_profile}")
    end
  end

  defp sources_using(media_profile) do
    SourcesQuery.new()
    |> where(^SourcesQuery.for_media_profile(media_profile))
    |> where([s], is_nil(s.marked_for_deletion_at))
    |> order_by(asc: :custom_name)
    |> Repo.all()
  end

  defp in_use_message(1), do: "This profile is used by 1 source. Move it to another profile or delete it first."

  defp in_use_message(count),
    do: "This profile is used by #{count} sources. Move them to another profile or delete them first."
end
