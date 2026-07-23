defmodule GameServer.Jobs.HookWorker do
  @moduledoc false
  # Generic worker that invokes a named hook. Both `GameServer.Jobs.enqueue_hook/3`
  # and `GameServer.Schedule` enqueue this with a `{"hook" => name, "args" => map}`
  # envelope. A hook returning `{:error, _}` retries with backoff; a missing hook
  # is discarded (retrying won't make the plugin implement it).

  use Oban.Worker, queue: :hooks, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"hook" => hook} = args}) do
    hook_fn = String.to_existing_atom(hook)
    hook_args = Map.get(args, "args", %{})

    case GameServer.Hooks.invoke(hook_fn, [hook_args]) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, {:not_found, _} = reason} -> {:discard, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # An unknown hook name (never registered as an atom) should not crash the
    # queue forever — discard it.
    ArgumentError -> {:discard, :unknown_hook}
  end
end
