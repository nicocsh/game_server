defmodule GameServer.Jobs do
  @moduledoc """
  Durable background jobs, backed by Oban.

  Use this from your hooks to run work that must survive a restart, retry on
  failure, or happen later — things `GameServer.Async` (best-effort, in-memory)
  cannot guarantee.

  Jobs are persisted in the same database as the rest of your data (Postgres or
  SQLite), executed with retries and backoff, and observable from the admin
  panel.

  ## Enqueue a hook to run in the background

      # Run `on_welcome_email` now, retried on failure
      GameServer.Jobs.enqueue_hook(:on_welcome_email, %{"user_id" => user.id})

      # Run it in 24 hours (delayed job)
      GameServer.Jobs.enqueue_in(24 * 60 * 60, :on_trial_reminder, %{"user_id" => user.id})

  The callback receives the args map you passed. **Args are stored as JSON**, so
  keys come back as strings and values must be JSON-encodable:

      def on_welcome_email(%{"user_id" => user_id}) do
        # ...
        :ok
      end

  Returning `{:error, reason}` from the callback makes the job retry with
  backoff; `:ok`/`{:ok, _}` completes it.

  ## Recurring work

  For cron-like recurring jobs use `GameServer.Schedule` (also durable, built on
  top of this module).

  ## RPC safety

  Any hook enqueued through `enqueue_hook/3` is automatically protected from
  client RPC — a client cannot invoke a job callback directly.
  """

  alias GameServer.Jobs.HookWorker
  alias GameServer.Jobs.ProtectedCallbacks

  @type args :: map()

  @doc false
  # Internal: enqueue any Oban.Worker module. Plugins use enqueue_hook/enqueue_in.
  @spec enqueue(module(), args(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(worker, args \\ %{}, opts \\ []) when is_atom(worker) and is_map(args) do
    args
    |> worker.new(opts)
    |> Oban.insert()
  end

  @doc """
  Enqueue a hook function to run in the background.

  Returns `{:ok, job_id}` — pass `job_id` to `cancel/1` to cancel it while it is
  still pending. See the module doc for the callback contract.
  """
  @spec enqueue_hook(atom(), args(), keyword()) :: {:ok, integer()} | {:error, term()}
  def enqueue_hook(hook_fn, args \\ %{}, opts \\ []) when is_atom(hook_fn) and is_map(args) do
    ProtectedCallbacks.register(hook_fn)

    case enqueue(HookWorker, hook_job_args(hook_fn, args), opts) do
      {:ok, %Oban.Job{id: id}} -> {:ok, id}
      {:error, _} = err -> err
    end
  end

  @doc """
  Enqueue a hook function to run after `seconds`.

  Returns `{:ok, job_id}`; cancel it with `cancel/1` before it runs.
  """
  @spec enqueue_in(non_neg_integer(), atom(), args(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def enqueue_in(seconds, hook_fn, args \\ %{}, opts \\ [])
      when is_integer(seconds) and seconds >= 0 do
    enqueue_hook(hook_fn, args, Keyword.put(opts, :schedule_in, seconds))
  end

  @doc """
  Cancel a pending job by its id (from `enqueue_hook/3` or `enqueue_in/4`).
  """
  @spec cancel(integer()) :: :ok
  def cancel(job_id) when is_integer(job_id) do
    _ = Oban.cancel_job(job_id)
    :ok
  end

  @doc false
  # The JSON envelope `HookWorker` unwraps. Kept here so `Schedule` builds the
  # same shape without duplicating the contract.
  @spec hook_job_args(atom(), args()) :: map()
  def hook_job_args(hook_fn, args) when is_atom(hook_fn) and is_map(args) do
    %{"hook" => Atom.to_string(hook_fn), "args" => args}
  end

  @doc false
  # Oban start options with the engine derived from the Repo's *actual* adapter.
  # The compile-time `default_adapter` keys off `DATABASE_ADAPTER`, but dev/test
  # switch the Repo to Postgres off `POSTGRES_HOST` — so deriving the engine from
  # the running adapter is the only value that's always correct.
  @spec oban_config() :: keyword()
  def oban_config do
    # Read the adapter from config (not Repo.__adapter__/0, a compile-time
    # constant the type checker narrows) so the same source drives both the Repo
    # and the Oban engine.
    adapter = Application.get_env(:game_server_core, GameServer.Repo)[:adapter]

    engine =
      if adapter == Ecto.Adapters.Postgres,
        do: Oban.Engines.Basic,
        else: Oban.Engines.Lite

    :game_server_core
    |> Application.fetch_env!(Oban)
    |> Keyword.put(:engine, engine)
  end
end
