defmodule Pinchflat.Health.CheckWorker do
  @moduledoc """
  Runs every 30 minutes (Oban Cron). Sends a "Problem" notification when a problem starts and a
  "Fixed" one when it ends, so each problem is reported once rather than every half hour. The
  problems last seen are kept in settings.health_problems, even while the notification is off,
  so turning it on doesn't report old news.
  """

  use Oban.Worker, queue: :local_data, max_attempts: 1, unique: [period: 600]

  alias Pinchflat.Health
  alias Pinchflat.Settings
  alias Pinchflat.Lifecycle.Notifications.Notifier

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: check()

  @doc """
  Compares the current problems with the last ones and notifies about the difference.
  `opts` go to Health.problems/1.

  Returns :ok
  """
  def check(opts \\ []) do
    previous = Settings.get!(:health_problems)
    current = Health.problems(opts)
    keys = current |> Map.keys() |> Enum.sort()

    for key <- keys, key not in previous do
      Notifier.notify(:problem, "Problem", current[key])
    end

    for key <- previous, key not in keys do
      Notifier.notify(:problem, "Fixed", Health.fixed_message(key))
    end

    if keys != previous, do: Settings.set(health_problems: keys)

    :ok
  end
end
