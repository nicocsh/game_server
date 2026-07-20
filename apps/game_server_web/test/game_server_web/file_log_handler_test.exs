defmodule GameServerWeb.FileLogHandlerTest do
  # async: false — installs a global :logger handler and sets env vars.
  use ExUnit.Case, async: false

  require Logger

  alias GameServerWeb.FileLogHandler

  @handler_id :file_log

  setup do
    previous = Application.get_all_env(:game_server_web)
    dir = Path.join(System.tmp_dir!(), "file_log_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      :logger.remove_handler(@handler_id)
      File.rm_rf(dir)

      for key <- [:log_file, :log_file_level, :log_file_max_bytes, :log_file_max_files] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:game_server_web, key, value)
          :error -> Application.delete_env(:game_server_web, key)
        end
      end

      for env <- ~w(LOG_FILE_PATH LOG_FILE_LEVEL LOG_FILE_MAX_BYTES LOG_FILE_MAX_FILES) do
        System.delete_env(env)
      end
    end)

    Application.delete_env(:game_server_web, :log_file)
    :logger.remove_handler(@handler_id)

    %{dir: dir, path: Path.join(dir, "test.log")}
  end

  defp handler_config do
    {:ok, %{config: config}} = :logger.get_handler_config(@handler_id)
    config
  end

  defp installed? do
    match?({:ok, _}, :logger.get_handler_config(@handler_id))
  end

  describe "installation" do
    test "does nothing when no path is configured" do
      assert FileLogHandler.install() == :ok
      refute installed?()
    end

    test "installs from app config" do
      Application.put_env(:game_server_web, :log_file, "/tmp/from_app_config.log")

      FileLogHandler.install()

      assert installed?()
      assert handler_config().file == ~c"/tmp/from_app_config.log"
    end

    test "installs from LOG_FILE_PATH when app config is unset", %{path: path} do
      # The whole point of reading the env here: a host that never wired
      # LOG_FILE_PATH into its own runtime config still gets file logging.
      System.put_env("LOG_FILE_PATH", path)

      FileLogHandler.install()

      assert installed?()
      assert handler_config().file == String.to_charlist(path)
    end

    test "app config wins over the environment", %{path: path} do
      Application.put_env(:game_server_web, :log_file, path)
      System.put_env("LOG_FILE_PATH", "/tmp/should_be_ignored.log")

      FileLogHandler.install()

      assert handler_config().file == String.to_charlist(path)
    end

    test "is idempotent", %{path: path} do
      Application.put_env(:game_server_web, :log_file, path)

      assert FileLogHandler.install() == :ok
      assert FileLogHandler.install() == :ok
      assert installed?()
    end

    test "creates the log directory when it does not exist", %{dir: dir} do
      nested = Path.join([dir, "deep", "nested", "app.log"])
      Application.put_env(:game_server_web, :log_file, nested)

      FileLogHandler.install()

      assert File.dir?(Path.dirname(nested))
    end
  end

  describe "rotation settings" do
    test "defaults to 10MB across 5 files", %{path: path} do
      Application.put_env(:game_server_web, :log_file, path)

      FileLogHandler.install()

      config = handler_config()
      assert config.max_no_bytes == 10_000_000
      assert config.max_no_files == 5
    end

    test "reads limits from the environment", %{path: path} do
      Application.put_env(:game_server_web, :log_file, path)
      System.put_env("LOG_FILE_MAX_BYTES", "2048")
      System.put_env("LOG_FILE_MAX_FILES", "3")

      FileLogHandler.install()

      config = handler_config()
      assert config.max_no_bytes == 2048
      assert config.max_no_files == 3
    end

    test "falls back to defaults on unparseable limits", %{path: path} do
      Application.put_env(:game_server_web, :log_file, path)
      System.put_env("LOG_FILE_MAX_BYTES", "not-a-number")
      System.put_env("LOG_FILE_MAX_FILES", "0")

      FileLogHandler.install()

      config = handler_config()
      assert config.max_no_bytes == 10_000_000
      assert config.max_no_files == 5
    end

    test "an unknown LOG_FILE_LEVEL falls back rather than crashing", %{path: path} do
      Application.put_env(:game_server_web, :log_file, path)
      System.put_env("LOG_FILE_LEVEL", "definitely-not-a-level")

      FileLogHandler.install()

      assert installed?()
      {:ok, %{level: level}} = :logger.get_handler_config(@handler_id)
      assert level == :info
    end

    test "reads a valid LOG_FILE_LEVEL", %{path: path} do
      Application.put_env(:game_server_web, :log_file, path)
      System.put_env("LOG_FILE_LEVEL", "warning")

      FileLogHandler.install()

      {:ok, %{level: level}} = :logger.get_handler_config(@handler_id)
      assert level == :warning
    end
  end

  describe "rotation actually happens" do
    @tag :slow
    test "rolls over to numbered files once max_no_bytes is exceeded", %{dir: dir, path: path} do
      # Config alone proves nothing — this drives real writes past the limit and
      # checks OTP rotated, so the "10MB x 5" promise is verified end to end.
      Application.put_env(:game_server_web, :log_file, path)
      Application.put_env(:game_server_web, :log_file_max_bytes, 1_024)
      Application.put_env(:game_server_web, :log_file_max_files, 3)

      FileLogHandler.install()

      # Logger.warning, not info: the test env sets the primary logger level to
      # :warning, so info never reaches a handler and the probe would write
      # nothing while still "passing" a weaker assertion.
      #
      # Messages are sized well under max_no_bytes and synced individually.
      # A tight loop of hundreds trips :logger_std_h's overload protection
      # (dropping past drop_mode_qlen), and messages *larger* than the limit
      # rotate on every single write, which leaves the live file empty and makes
      # the result read as "nothing was logged".
      for i <- 1..6 do
        Logger.warning("rotation probe #{i} #{String.duplicate("x", 600)}")
        :logger_std_h.filesync(@handler_id)
      end

      files = dir |> File.ls!() |> Enum.sort()

      assert "test.log" in files

      # OTP names rotated files test.log.0, test.log.1, ...
      rotated = Enum.filter(files, &String.match?(&1, ~r/^test\.log\.\d+$/))
      assert rotated != [], "expected rotated files, got: #{inspect(files)}"

      # Bounded by max_no_files, which is the half of "10MB x 5" that keeps a
      # busy server from filling its disk.
      assert length(rotated) <= 3, "rotation kept too many files: #{inspect(files)}"

      # The live file is rolled before it grows past the limit.
      assert File.stat!(path).size <= 1_024 * 2
    end
  end
end
