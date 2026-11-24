defmodule Pinchflat.Utils.TtlCache do
  @moduledoc """
  A tiny in-memory cache with a time-to-live per entry, backed by a public ETS table.

  Used for cheap-but-not-free values shown on every page (like the running job count in the
  header) so a LiveView that re-renders often doesn't hit the database every time.
  """

  use GenServer

  @table :pinchfork_ttl_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Returns the cached value for `key` if it is younger than `ttl_ms`, otherwise calls `fun`,
  caches its result and returns it. Falls back to calling `fun` directly if the cache isn't
  running (e.g. in some tests).

  Returns any()
  """
  def fetch(key, ttl_ms, fun) do
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {:ok, {value, stored_at}} when now - stored_at < ttl_ms ->
        value

      _ ->
        value = fun.()
        store(key, value, now)
        value
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, stored_at}] -> {:ok, {value, stored_at}}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(key, value, now) do
    :ets.insert(@table, {key, value, now})
  rescue
    ArgumentError -> false
  end
end
