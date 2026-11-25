defmodule Pinchflat.YtDlp.PoTokenServer do
  @moduledoc """
  Talks to the bgutil PO token provider sidecar (`bgutil-provider:4416` on the Docker network).

  Uses curl rather than :httpc because Erlang's DNS resolver doesn't pick up Docker's embedded
  DNS, while system processes (including curl) do.
  """

  @base_url "http://bgutil-provider:4416"

  @doc """
  Whether the sidecar answers at all.

  Returns :up | :down
  """
  def status do
    case run_curl(["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", @base_url]) do
      {code, 0} when code != "" -> :up
      _ -> :down
    end
  end

  @doc """
  Asks the sidecar to mint a token. An empty JSON body makes bgutil generate its own
  visitor_data and return a real token, so this is an end-to-end test.

  Returns {:ok, token_preview} | {:error, message}
  """
  def fetch_token do
    args = ["-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", "{}", "--max-time", "30"]

    case run_curl(args ++ ["#{@base_url}/get_pot"]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"poToken" => token}} when is_binary(token) and byte_size(token) > 0 ->
            {:ok, String.slice(token, 0, 40) <> "…"}

          {:ok, resp} ->
            {:error, "Server responded but no token found. Response: #{inspect(resp)}"}

          {:error, _} ->
            {:error, "Server responded but output was not valid JSON: #{String.slice(output, 0, 200)}"}
        end

      {output, exit_code} ->
        {:error, "Couldn't reach the token server (curl exit #{exit_code}). #{String.slice(output, 0, 200)}"}
    end
  end

  defp run_curl(args) do
    System.cmd("curl", args, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 127}
  end
end
