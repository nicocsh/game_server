defmodule GameServer.Signaling do
  @moduledoc "SDK stub for GameServer.Signaling."

  def create_room(_room_id, _topology, _opts \\ []), do: :ok
  def close_room(_room_id), do: :ok
  def room_exists?(_room_id), do: false
  def list_peers(_room_id), do: %{}
end
