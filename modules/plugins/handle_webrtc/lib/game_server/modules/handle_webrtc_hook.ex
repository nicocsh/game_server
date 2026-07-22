defmodule GameServer.Modules.HandleWebRTCHook do
  use GameServer.Hooks
  
  require Logger

  alias GameServer.Signaling

  @impl true
  def after_matchmaking_matched(tickets, lobby_id) do
    server_user_id = "019f8a7d-485e-7000-bd09-6743f91a74e3"
    Logger.warning("Creating WebRTC room")
    :ok = Signaling.create_room(lobby_id, :star, host_user_id: server_user_id)

  end
end
