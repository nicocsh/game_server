defmodule GameServerWeb.FileLogHandler do
  @moduledoc """
  Persists all logs to a rotating file so history survives restarts — the
  admin log buffer (`GameServerWeb.AdminLogBuffer`) is in-memory only and is
  lost on redeploy/restart.

  Disabled unless `:game_server_web, :log_file` is set to a path (wired from
  the `LOG_FILE_PATH` env in host runtime config). Runs *alongside* the default
  stdout handler, so `fly logs` still receives everything. On a Fly deploy,
  point it at the mounted volume, e.g.
  `LOG_FILE_PATH=/data/log/game_server.log`.

  Backed by OTP's built-in `:logger_std_h`, which handles size-based rotation
  (`max_no_bytes` per file, `max_no_files` kept).
  """

  require Logger

  @handler_id :file_log

  @default_max_no_bytes 10_000_000
  @default_max_no_files 5

  @doc """
  Installs the file handler when a log file path is configured. Idempotent —
  calling it again while already installed is a no-op.
  """
  def install do
    with path when is_binary(path) and path != "" <-
           Application.get_env(:game_server_web, :log_file),
         :undefined <- handler_status() do
      add_handler(path)
    else
      _ -> :ok
    end
  end

  defp handler_status do
    case :logger.get_handler_config(@handler_id) do
      {:ok, _config} -> :installed
      {:error, _reason} -> :undefined
    end
  end

  defp add_handler(path) do
    _ = File.mkdir_p(Path.dirname(path))

    config = %{
      level: log_level(),
      config: %{
        file: String.to_charlist(path),
        max_no_bytes: env_int(:log_file_max_bytes, @default_max_no_bytes),
        max_no_files: env_int(:log_file_max_files, @default_max_no_files),
        filesync_repeat_interval: 5_000
      },
      formatter:
        Logger.Formatter.new(
          format: "$date $time [$level] $metadata$message\n",
          metadata: [:module, :request_id]
        )
    }

    case :logger.add_handler(@handler_id, :logger_std_h, config) do
      :ok ->
        Logger.info("file log handler writing to #{path}")
        :ok

      {:error, {:already_exist, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning("file log handler install failed: #{inspect(reason)}")
        :ok
    end
  end

  defp log_level do
    case Application.get_env(:game_server_web, :log_file_level, :info) do
      level when is_atom(level) -> level
      _ -> :info
    end
  end

  defp env_int(key, default) do
    case Application.get_env(:game_server_web, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
