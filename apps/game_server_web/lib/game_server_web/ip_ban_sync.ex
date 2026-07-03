defmodule GameServerWeb.IpBanSync do
  @moduledoc """
  Keeps the node-local IP-ban ETS table in sync with the database and the
  other app instances.

  At boot it loads persisted bans (`GameServer.IpBans`) into ETS; afterwards
  it applies ban/unban events broadcast by other instances on the
  `GameServerWeb.Plugs.IpBan.topic/0` PubSub topic. Events originating on
  this node are skipped — the plug already applied them locally.
  """

  use GenServer

  alias GameServerWeb.Plugs.IpBan

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    IpBan.load_persisted()
    Phoenix.PubSub.subscribe(GameServer.PubSub, IpBan.topic())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:ip_ban, event, ip, expires_at_utc, from_node}, state) do
    if from_node != Node.self() do
      IpBan.apply_remote(event, ip, expires_at_utc)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
