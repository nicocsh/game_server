defmodule GameServer.Matchmaking.Worker do
  @moduledoc """
  Periodic worker that drives the matchmaking sweep.

  One instance runs per cluster via `:global` registration. On each tick
  it reads the queued tickets, forms matches, creates a hidden lobby for
  each match and notifies the matched users through their user channel.
  """

  use GenServer

  alias GameServer.Matchmaking
  alias GameServer.Matchmaking.Matcher

  @tick_interval_ms 3_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: {:global, __MODULE__})
  end

  @impl true
  def init(_) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Matchmaking.list_queued_by_params()
    |> Enum.each(fn {_params, tickets} ->
      {matches, _remaining} = Matcher.form_matches(tickets)

      Enum.each(matches, &GameServer.Matchmaking.Match.create/1)
    end)

    # TBD: cancel tickets for offline users.
    # Matchmaking.prune_offline(?.list_online_user_ids())

    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end
end
