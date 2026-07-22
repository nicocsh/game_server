defmodule GameServer.Schedule do
  @moduledoc """
  Dynamic cron-like job scheduling for hooks.

  Use this module in your `after_startup/0` hook to register scheduled jobs
  that will call your hook functions at specified intervals.

  Jobs are durable and safe for distributed deployments: they run through the
  background job queue (`GameServer.Jobs`, backed by Oban), so exactly one
  instance executes each job per period and a crash mid-run is retried.

  Scheduled callbacks are automatically protected from user RPC calls.

  ## Examples

      def after_startup do
        # Simple intervals
        Schedule.every_minutes(5, :on_every_5m)
        Schedule.hourly(:on_hourly)
        Schedule.daily(:on_daily)

        # With options
        Schedule.daily(:on_morning_report, hour: 9)
        Schedule.weekly(:on_monday, day: :monday, hour: 10)

        # Full cron syntax
        Schedule.cron(:my_job, "0 */6 * * *", :on_every_6h)

        :ok
      end

      # Callback receives a context map (public function, but protected from RPC)
      def on_hourly(context) do
        IO.puts("Triggered at \#{context["triggered_at"]}")
        :ok
      end

  ## Context

  Callbacks run as background jobs, so the context is a **JSON map with string
  keys** (`triggered_at` is an ISO8601 string):

      %{
        "triggered_at" => "2026-07-22T14:00:00Z",
        "job_name" => "on_hourly",
        "schedule" => "0 * * * *"
      }

  ## Distributed Safety

  A single per-minute tick (`GameServer.Schedule.TickWorker`, driven by Oban's
  leader-elected Cron plugin) enqueues each due callback as a **unique** job.
  Oban's uniqueness guarantees a callback runs at most once per period across
  the whole cluster — no application-level locks required.
  """

  alias Crontab.CronExpression.Parser
  alias Crontab.DateChecker
  alias GameServer.Jobs
  alias GameServer.Jobs.HookWorker
  alias GameServer.Jobs.ProtectedCallbacks
  require Logger

  # ETS table of registered schedules: {job_name, cron_expr, hook_fn}
  @table :schedule_jobs

  # Uniqueness window (seconds) for a per-minute tick — comfortably longer than
  # a minute so a duplicate tick near the boundary can't double-enqueue.
  @unique_period 90

  @day_map %{
    sunday: 0,
    monday: 1,
    tuesday: 2,
    wednesday: 3,
    thursday: 4,
    friday: 5,
    saturday: 6
  }

  @doc false
  @spec start_link() :: :ignore
  def start_link do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    ProtectedCallbacks.init()
    :ignore
  end

  @doc """
  Returns the set of callback function names registered for background jobs.

  The union of hook functions bound to an active schedule and any hook enqueued
  via `GameServer.Jobs`. These are protected from user RPC calls via
  `Hooks.call/3`. Cancelling a schedule drops its callback from the set unless
  another schedule (or a `Jobs` enqueue) still references it.
  """
  @spec registered_callbacks() :: MapSet.t(atom())
  def registered_callbacks do
    scheduled =
      registry_entries()
      |> Enum.map(fn {_name, _cron, hook_fn} -> hook_fn end)
      |> MapSet.new()

    MapSet.union(scheduled, ProtectedCallbacks.all())
  end

  @doc """
  Register a job with full cron syntax.

  ## Examples

      Schedule.cron(:my_job, "*/15 * * * *", :on_every_15m)
      Schedule.cron(:weekdays, "0 9 * * 1-5", :on_weekday_morning)
  """
  @spec cron(atom(), String.t(), atom()) :: :ok | {:error, term()}
  def cron(name, cron_expr, hook_fn) when is_atom(name) and is_atom(hook_fn) do
    case Parser.parse(cron_expr) do
      {:ok, _schedule} ->
        if :ets.whereis(@table) != :undefined do
          :ets.insert(@table, {name, cron_expr, hook_fn})
        end

        Logger.info("[Schedule] Registered job #{name} with schedule #{cron_expr}")
        :ok

      {:error, reason} ->
        Logger.error(
          "[Schedule] Failed to parse cron expression '#{cron_expr}': #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Run a job every N minutes.

  ## Examples

      Schedule.every_minutes(5, :on_5m)
      Schedule.every_minutes(15, :on_15m)
  """
  @spec every_minutes(pos_integer(), atom()) :: :ok | {:error, term()}
  def every_minutes(n, hook_fn) when is_integer(n) and n > 0 and is_atom(hook_fn) do
    cron(hook_fn, "*/#{n} * * * *", hook_fn)
  end

  @doc """
  Run a job every hour.

  ## Options

    * `:minute` - minute of the hour (0-59), default: 0

  ## Examples

      Schedule.hourly(:on_hourly)
      Schedule.hourly(:on_half_hour, minute: 30)
  """
  @spec hourly(atom()) :: :ok | {:error, term()}
  @spec hourly(atom(), minute: 0..59) :: :ok | {:error, term()}
  def hourly(hook_fn, opts \\ []) when is_atom(hook_fn) do
    minute = Keyword.get(opts, :minute, 0)
    cron(hook_fn, "#{minute} * * * *", hook_fn)
  end

  @doc """
  Run a job every day.

  ## Options

    * `:hour` - hour of the day (0-23), default: 0
    * `:minute` - minute of the hour (0-59), default: 0

  ## Examples

      Schedule.daily(:on_midnight)
      Schedule.daily(:on_morning, hour: 9)
      Schedule.daily(:on_evening, hour: 18, minute: 30)
  """
  @spec daily(atom()) :: :ok | {:error, term()}
  @spec daily(atom(), hour: 0..23, minute: 0..59) :: :ok | {:error, term()}
  def daily(hook_fn, opts \\ []) when is_atom(hook_fn) do
    hour = Keyword.get(opts, :hour, 0)
    minute = Keyword.get(opts, :minute, 0)
    cron(hook_fn, "#{minute} #{hour} * * *", hook_fn)
  end

  @doc """
  Run a job every week.

  ## Options

    * `:day` - day of week (`:sunday`, `:monday`, etc.), default: `:sunday`
    * `:hour` - hour of the day (0-23), default: 0
    * `:minute` - minute of the hour (0-59), default: 0

  ## Examples

      Schedule.weekly(:on_sunday)
      Schedule.weekly(:on_monday_morning, day: :monday, hour: 9)
  """
  @spec weekly(atom()) :: :ok | {:error, term()}
  @spec weekly(atom(), day: atom(), hour: 0..23, minute: 0..59) :: :ok | {:error, term()}
  def weekly(hook_fn, opts \\ []) when is_atom(hook_fn) do
    day = Keyword.get(opts, :day, :sunday)
    hour = Keyword.get(opts, :hour, 0)
    minute = Keyword.get(opts, :minute, 0)
    day_num = Map.get(@day_map, day, 0)
    cron(hook_fn, "#{minute} #{hour} * * #{day_num}", hook_fn)
  end

  @doc """
  Cancel a scheduled job.

  ## Examples

      Schedule.cancel(:my_job)
  """
  @spec cancel(atom()) :: :ok
  def cancel(name) when is_atom(name) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, name)
    Logger.info("[Schedule] Cancelled job #{name}")
    :ok
  end

  @doc """
  List all scheduled jobs.

  Returns a list of job info maps.
  """
  @spec list() :: [%{name: atom(), schedule: String.t(), hook: atom(), state: atom()}]
  def list do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {name, cron_expr, hook_fn} ->
        %{name: name, schedule: cron_expr, hook: hook_fn, state: :active}
      end)
    end
  end

  @doc false
  # Called once per minute by `TickWorker`. Enqueues a unique job for each
  # registered schedule whose cron matches `now` (to the minute).
  @spec enqueue_due(DateTime.t()) :: :ok
  def enqueue_due(now) do
    minute = %{now | second: 0, microsecond: {0, 0}}
    naive = DateTime.to_naive(minute)

    for {name, cron_expr, hook_fn} <- registry_entries() do
      with {:ok, cron} <- Parser.parse(cron_expr),
           true <- DateChecker.matches_date?(cron, naive) do
        enqueue_due_job(name, cron_expr, hook_fn, minute)
      end
    end

    :ok
  end

  defp registry_entries do
    if :ets.whereis(@table) == :undefined, do: [], else: :ets.tab2list(@table)
  end

  defp enqueue_due_job(name, cron_expr, hook_fn, minute) do
    context = %{
      "triggered_at" => DateTime.to_iso8601(minute),
      "job_name" => Atom.to_string(name),
      "schedule" => cron_expr
    }

    # The context (incl. the minute-bucketed timestamp) is identical for every
    # tick in the same minute, so Oban's uniqueness dedupes duplicate ticks and
    # collapses the fan-out to one run per period across the cluster.
    Jobs.enqueue(
      HookWorker,
      Jobs.hook_job_args(hook_fn, context),
      queue: :default,
      unique: [period: @unique_period]
    )
  end
end
