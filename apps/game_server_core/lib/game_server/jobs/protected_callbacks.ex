defmodule GameServer.Jobs.ProtectedCallbacks do
  @moduledoc false
  # Registry of hook function names that run in the background — scheduled via
  # `GameServer.Schedule` or enqueued via `GameServer.Jobs`. `GameServer.Hooks`
  # blocks these from client RPC so a client can't trigger a job callback
  # directly. The table is a public, named ETS set owned by whoever calls
  # `init/0` first (see `GameServer.Schedule.start_link/0`).

  @table :job_protected_callbacks

  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @spec register(atom()) :: :ok
  def register(name) when is_atom(name) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {name})
    :ok
  end

  @spec all() :: MapSet.t(atom())
  def all do
    if :ets.whereis(@table) != :undefined do
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {name} -> name end)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end
end
