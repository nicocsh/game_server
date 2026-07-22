defmodule GameServer.Signaling do
  @moduledoc """
  Public API for the WebRTC signaling broker.

  This module is exposed to plugins through the SDK.  All operations are
  delegated to the internal `GameServerWeb.SignalingBroker` process.
  """

  alias GameServerWeb.SignalingBroker

  defdelegate create_room(room_id, topology, opts \\ []), to: SignalingBroker
  defdelegate close_room(room_id), to: SignalingBroker
  defdelegate room_exists?(room_id), to: SignalingBroker
  defdelegate list_peers(room_id), to: SignalingBroker
end
