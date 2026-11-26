defmodule Pinchflat.YtDlp.YtDlpCommandRunner do
  @moduledoc """
  A behaviour for running CLI commands against a downloader backend (yt-dlp).

  Used so we can implement Mox for testing without actually running the
  yt-dlp command.
  """

  @type url :: binary() | [binary()]
  @type run_result :: {:ok, binary()} | {:partial, binary(), binary()} | {:error, binary(), integer()}

  @callback run(url(), atom(), keyword(), binary()) :: run_result()
  @callback run(url(), atom(), keyword(), binary(), keyword()) :: run_result()
  @callback version() :: {:ok, binary()} | {:error, binary()}
  @callback update() :: {:ok, binary()} | {:error, binary()}
  @callback update(binary()) :: {:ok, binary()} | {:error, binary()}
end
