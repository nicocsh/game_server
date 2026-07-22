defmodule GameServerWeb.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GameServerWeb.SignalingBroker
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GameServerWeb.Supervisor)
  end
end
