defmodule Pinchflat.Accounts.LoginThrottle do
  @moduledoc """
  Slows down password guessing: after #{10} failed sign-ins from one address within
  15 minutes, further attempts from that address are refused until the window passes.
  Kept in memory, so a restart clears it.
  """

  use GenServer

  @table :pinchfork_login_throttle
  @max_failures 10
  @window_ms :timer.minutes(15)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, nil}
  end

  @doc """
  Whether this address is currently locked out.

  Returns boolean()
  """
  def blocked?(key) do
    case lookup(key) do
      {count, started_at} -> fresh?(started_at) and count >= @max_failures
      nil -> false
    end
  end

  @doc """
  Records a failed sign-in for this address.
  """
  def record_failure(key) do
    now = now()

    case lookup(key) do
      {count, started_at} -> if fresh?(started_at), do: put(key, count + 1, started_at), else: put(key, 1, now)
      nil -> put(key, 1, now)
    end

    :ok
  end

  @doc """
  Clears the failure count after a successful sign-in.
  """
  def reset(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, count, started_at}] -> {count, started_at}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp put(key, count, started_at) do
    :ets.insert(@table, {key, count, started_at})
  rescue
    ArgumentError -> false
  end

  defp fresh?(started_at), do: now() - started_at < @window_ms
  defp now, do: System.monotonic_time(:millisecond)
end
