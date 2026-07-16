defmodule GameServer.Matchmaking.Match do
  @moduledoc """
  Creates a lobby for a formed match and notifies the players.
  """

  alias GameServer.Lobbies
  alias GameServer.Matchmaking
  alias GameServerWeb.Endpoint

  @doc """
  Creates a hidden lobby for the given tickets, joins the users, locks
  the lobby and broadcasts `matchmaking:found` on each user's channel.
  """
  @spec create([map()]) :: :ok
  def create(tickets) do
    first = hd(tickets)

    {:ok, lobby} =
      Lobbies.create_lobby(%{
        title: "Match Lobby",
        max_users: first.max_players,
        is_hidden: true,
        is_locked: false,
        hostless: true,
        metadata: %{
          match_params: first.match_params
        }
      })

    Enum.each(tickets, fn ticket ->
      Lobbies.join_lobby(ticket.user, lobby.id)
    end)

    Lobbies.update_lobby(lobby, %{is_locked: true})

    :ok = Matchmaking.mark_matched(tickets, lobby.id)

    Enum.each(tickets, fn ticket ->
      Endpoint.broadcast(
        "user:#{ticket.user_id}",
        "matchmaking:found",
        %{lobby_id: lobby.id}
      )
    end)

    :ok
  end
end
