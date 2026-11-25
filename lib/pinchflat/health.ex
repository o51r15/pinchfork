defmodule Pinchflat.Health do
  @moduledoc """
  Checks shared by the Status page and the Problems notification: free disk space where
  downloads go, and whether the PO token server answers.
  """

  alias Pinchflat.YtDlp.PoTokenServer

  @doc """
  Free space where downloads go, from `df`. nil when it can't be read.

  Returns %{path, total, used, free, used_pct} | nil
  """
  def disk_usage(nil), do: nil

  def disk_usage(path) do
    with {output, 0} <- System.cmd("df", ["-Pk", path], stderr_to_stdout: true),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, total_kb, used_kb, free_kb | _] <- String.split(line),
         {total, ""} <- Integer.parse(total_kb),
         {used, ""} <- Integer.parse(used_kb),
         {free, ""} <- Integer.parse(free_kb),
         true <- total > 0 do
      %{path: path, total: total * 1024, used: used * 1024, free: free * 1024, used_pct: round(used * 100 / total)}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Under 5% or 20 GB free is :bad; under 15% is :warn.
  """
  def disk_state(%{free: free, used_pct: pct}) do
    cond do
      pct >= 95 or free < 20 * 1_000_000_000 -> :bad
      pct >= 85 -> :warn
      true -> :ok
    end
  end

  @doc """
  The problems right now, as %{key => message}. Options replace the checks (for tests):
  `:po_status` (fn returning :up | :down) and `:disk` (fn returning a disk_usage/1 map or nil).
  """
  def problems(opts \\ []) do
    po_status = Keyword.get(opts, :po_status, &PoTokenServer.status/0)
    disk = Keyword.get(opts, :disk, fn -> disk_usage(Application.get_env(:pinchflat, :media_directory)) end)

    po =
      if po_status.() == :down,
        do: %{"po_token" => "The PO token server isn't answering. Downloads that need a token will fail."},
        else: %{}

    space =
      case disk.() do
        %{} = usage ->
          if disk_state(usage) == :bad,
            do: %{"disk" => "The download disk is nearly full: #{gigabytes(usage.free)} free."},
            else: %{}

        nil ->
          %{}
      end

    Map.merge(po, space)
  end

  @doc """
  What's sent when a problem is fixed.
  """
  def fixed_message("po_token"), do: "The PO token server is answering again."
  def fixed_message("disk"), do: "The download disk has enough free space again."
  def fixed_message(key), do: "#{key} is fixed."

  defp gigabytes(bytes), do: "#{Float.round(bytes / 1_000_000_000, 1)} GB"
end
