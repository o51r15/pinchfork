defmodule Pinchflat.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :pinchflat

  require Logger

  alias Pinchflat.Utils.FilesystemUtils

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Gives a user a new random password and prints it. Run from the host with:

      docker exec -it pinchfork /app/bin/reset_password <username>
  """
  def reset_password(username) when is_binary(username) do
    load_app()
    Application.ensure_all_started(:ssl)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Pinchflat.Repo, fn _repo ->
        case Pinchflat.Repo.get_by(Pinchflat.Accounts.User, username: username) do
          nil ->
            IO.puts("No user named #{inspect(username)}.")

          user ->
            new_password = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
            {:ok, _} = Pinchflat.Accounts.reset_user_password(user, new_password)
            IO.puts("New password for #{user.username}: #{new_password}")
            IO.puts("Sign in with it, then change it in Settings > General.")
        end
      end)

    :ok
  end

  def check_file_permissions do
    load_app()

    directories =
      [
        "/config",
        "/downloads",
        "/etc/yt-dlp",
        "/etc/yt-dlp/plugins",
        Application.get_env(:pinchflat, :media_directory),
        Application.get_env(:pinchflat, :tmpfile_directory),
        Application.get_env(:pinchflat, :extras_directory),
        Application.get_env(:pinchflat, :metadata_directory),
        Application.get_env(:tzdata, :data_dir)
      ]
      |> Enum.uniq()
      |> Enum.filter(&(&1 != nil))

    Enum.each(directories, fn dir ->
      Logger.info("Checking permissions for #{dir}")
      filepath = Path.join([dir, ".keep"])

      case FilesystemUtils.write_p(filepath, "") do
        :ok ->
          Logger.info("Permissions OK")

        {:error, :eacces} ->
          Logger.error(permission_denied_screed(dir))
          raise "Permission denied"

        err ->
          Logger.error("Permissions check failed: #{inspect(err)}")
          raise "Unknown error"
      end
    end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp permission_denied_screed(dir) do
    """
    The directory "#{dir}" is not writeable by the Docker container.

    Please ensure that the directory exists and is writeable by the Docker
    container. All setups are different, but you may be able to run something
    like this on the *host*:

      chown nobody -R <host path that maps to #{dir}>
      chmod 755 -R <host path that maps to #{dir}>

    Swapping in your real host path. Then, you should set the user running
    this container by editing your `docker run` command like so:

        docker run --user 99:100 <rest of the command>

    Or adding `user: '99:100'` to the Pinchflat service of your Docker Compose
    file. Again, there are many ways to do this depending on your setup and
    this is just one example. See issue #106 in the Pinchflat Github for more.

    No matter the case, this _is_ a permissions error and allowing the container
    to write to the directory is the only way to fix it. It is not recommended
    to run the container as `root` because files created by Pinchflat may not
    be accessible to other apps that want to modify them.
    """
  end
end
