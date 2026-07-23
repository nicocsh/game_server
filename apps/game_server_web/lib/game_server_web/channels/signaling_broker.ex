defmodule GameServerWeb.SignalingBroker do
  @moduledoc """
  Signaling relay for WebRTC peer-to-peer and client-server topologies.

  Rooms are created explicitly by a worker process (e.g. a lobby worker) and
  are keyed by the lobby id.  Each room stores its topology and, for :star,
  the designated host user id.  The broker validates membership and topology
  rules on every relay.

  Does not create PeerConnections or handle media; only routes SDP offers,
  answers, and ICE candidates between registered peers in a room.

  ## Topologies

    * `:mesh` — any member may send an offer/answer/ICE to any other member.
    * `:star` — one host peer (the Godot headless server) and client peers.
      Clients may only signal to the host; the host may signal to any client.
      Non-host peers cannot exchange messages directly.

  Each peer is monitored via `Process.monitor/1`.  When a peer crashes or
  disconnects it is automatically removed and the remaining peers are notified.
  """

  use GenServer
  require Logger

  defstruct rooms: %{}, refs: %{}

  # ── Public API ───────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a signaling room.  `room_id` is typically the lobby id.

  For `:star` topology `host_user_id` is required and designates the user
  that will act as the authoritative server peer.
  """
  def create_room(room_id, topology, opts \\ []) when topology in [:mesh, :star] do
    host_user_id = if topology == :star, do: Keyword.fetch!(opts, :host_user_id), else: nil
    GenServer.call(__MODULE__, {:create_room, room_id, topology, host_user_id})
  end

  @doc """
  Closes a signaling room.  Existing peers are notified with a `room_closed`
  event so their channels can stop gracefully.
  """
  def close_room(room_id) do
    GenServer.call(__MODULE__, {:close_room, room_id})
  end

  def room_exists?(room_id) do
    GenServer.call(__MODULE__, {:room_exists, room_id})
  end

  @doc """
  Registers a peer in a room.

  Returns `{:ok, role}` where `role` is derived from the room topology and
  the provided `user_id`.  Returns `{:error, :room_not_found}` if the room
  does not exist, and `{:error, :duplicate_peer}` if `peer_id` is already
  present.
  """
  def join(room_id, peer_id, pid, user_id, metadata \\ %{})
      when is_binary(room_id) and is_binary(peer_id) and is_pid(pid) and is_binary(user_id) do
    GenServer.call(__MODULE__, {:join, room_id, peer_id, pid, user_id, metadata})
  end

  def leave(room_id, peer_id) when is_binary(room_id) and is_binary(peer_id) do
    GenServer.call(__MODULE__, {:leave, room_id, peer_id})
  end

  @doc """
  Routes a signaling message from one peer to a specific target.

  Enforces topology rules: in `:star` mode a non-host peer may only relay
  to the host.
  """
  def relay(room_id, from_peer_id, to_peer_id, type, payload) do
    GenServer.call(__MODULE__, {:relay, room_id, from_peer_id, to_peer_id, type, payload})
  end

  @doc """
  Broadcasts a signaling message to every other peer in the room.

  In `:star` mode only the host may broadcast.
  """
  def broadcast(room_id, from_peer_id, type, payload) do
    GenServer.call(__MODULE__, {:broadcast, room_id, from_peer_id, type, payload})
  end

  def list_peers(room_id) do
    GenServer.call(__MODULE__, {:list_peers, room_id})
  end

  def is_host?(room_id, user_id) do
    GenServer.call(__MODULE__, {:is_host, room_id, user_id})
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:create_room, room_id, topology, host_user_id}, _from, state) do
    if Map.has_key?(state.rooms, room_id) do
      Logger.warning("SignalingBroker: room already exists room=#{room_id}")
      {:reply, {:error, :already_exists}, state}
    else
      room = %{
        topology: topology,
        host_user_id: host_user_id,
        peers: %{}
      }

      Logger.info("SignalingBroker: room created room=#{room_id} topology=#{topology} host_user_id=#{host_user_id || "none"}")
      {:reply, :ok, %{state | rooms: Map.put(state.rooms, room_id, room)}}
    end
  end

  @impl true
  def handle_call({:close_room, room_id}, _from, state) do
    case Map.pop(state.rooms, room_id) do
      {nil, _} ->
        Logger.warning("SignalingBroker: close_room for non-existent room=#{room_id}")
        {:reply, {:error, :room_not_found}, state}

      {room, rooms} ->
        peer_count = map_size(room.peers)
        Logger.info("SignalingBroker: closing room=#{room_id} topology=#{room.topology} evicting=#{peer_count}")

        for {peer_id, %{pid: pid}} <- room.peers do
          Logger.debug("SignalingBroker: sending room_closed to peer=#{peer_id} pid=#{inspect(pid)}")
          send(pid, {:signaling_relay, :room_closed, nil, %{}})
        end

        refs = Enum.reject(state.refs, fn {_ref, {r, _p}} -> r == room_id end) |> Map.new()

        {:reply, :ok, %{state | rooms: rooms, refs: refs}}
    end
  end

  @impl true
  def handle_call({:room_exists, room_id}, _from, state) do
    {:reply, Map.has_key?(state.rooms, room_id), state}
  end

  @impl true
  def handle_call({:join, room_id, peer_id, pid, user_id, metadata}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        Logger.warning("SignalingBroker: join failed room_not_found room=#{room_id} user=#{user_id}")
        {:reply, {:error, :room_not_found}, state}

      room ->
        if Map.has_key?(room.peers, peer_id) do
          Logger.warning("SignalingBroker: join failed duplicate_peer room=#{room_id} peer=#{peer_id}")
          {:reply, {:error, :duplicate_peer}, state}
        else
          ref = Process.monitor(pid)

          role =
            case room.topology do
              :mesh -> :peer
              :star -> if user_id == room.host_user_id, do: :host, else: :client
            end

          peer = %{
            pid: pid,
            user_id: user_id,
            role: role,
            metadata: metadata,
            joined_at: System.monotonic_time(:second)
          }

          peers = Map.put(room.peers, peer_id, peer)
          room = %{room | peers: peers}
          rooms = Map.put(state.rooms, room_id, room)
          refs = Map.put(state.refs, ref, {room_id, peer_id})

          peer_count = map_size(peers)
          Logger.info("SignalingBroker: peer joined room=#{room_id} peer=#{peer_id} user=#{user_id} role=#{role} total_peers=#{peer_count}")

          for {other_id, %{pid: other_pid}} <- room.peers, other_id != peer_id do
            Logger.debug("SignalingBroker: notifying peer=#{other_id} of peer_joined peer=#{peer_id}")
            send(other_pid, {:signaling_relay, :peer_joined, peer_id, %{
              peer_id: peer_id,
              role: role,
              user_id: user_id
            }})
          end

          {:reply, {:ok, role}, %{state | rooms: rooms, refs: refs}}
        end
    end
  end

  @impl true
  def handle_call({:leave, room_id, peer_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        Logger.warning("SignalingBroker: leave failed room_not_found room=#{room_id} peer=#{peer_id}")
        {:reply, {:error, :room_not_found}, state}

      room ->
        case Map.pop(room.peers, peer_id) do
          {nil, _} ->
            Logger.warning("SignalingBroker: leave failed peer_not_found room=#{room_id} peer=#{peer_id}")
            {:reply, {:error, :peer_not_found}, state}

          {peer, peers} ->
            peer_count = map_size(peers)
            Logger.info("SignalingBroker: peer leaving room=#{room_id} peer=#{peer_id} user=#{peer.user_id} role=#{peer.role} remaining_peers=#{peer_count}")

            for {other_id, %{pid: other_pid}} <- peers do
              send(other_pid, {:signaling_relay, :peer_left, peer_id, %{peer_id: peer_id}})
            end

            room = %{room | peers: peers}

            rooms =
              if map_size(peers) == 0 do
                Logger.info("SignalingBroker: room empty, removing room=#{room_id}")
                Map.delete(state.rooms, room_id)
              else
                Map.put(state.rooms, room_id, room)
              end

            ref_entry =
              Enum.find(state.refs, fn {_ref, {r, p}} -> r == room_id and p == peer_id end)

            refs =
              if ref_entry do
                Map.delete(state.refs, elem(ref_entry, 0))
              else
                state.refs
              end

            {:reply, :ok, %{state | rooms: rooms, refs: refs}}
        end
    end
  end

  @impl true
  def handle_call({:relay, room_id, from, to, type, payload}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        Logger.warning("SignalingBroker: relay failed room_not_found room=#{room_id} from=#{from} to=#{to} type=#{type}")
        {:reply, {:error, :room_not_found}, state}

      room ->
        from_peer = Map.get(room.peers, from)
        to_peer = Map.get(room.peers, to)

        cond do
          is_nil(from_peer) ->
            Logger.warning("SignalingBroker: relay failed peer_not_found room=#{room_id} from=#{from} to=#{to} type=#{type}")
            {:reply, {:error, :peer_not_found}, state}

          is_nil(to_peer) ->
            Logger.warning("SignalingBroker: relay failed peer_not_found room=#{room_id} from=#{from} to=#{to} type=#{type}")
            {:reply, {:error, :peer_not_found}, state}

          room.topology == :star and from_peer.role != :host and to_peer.role != :host ->
            Logger.warning("SignalingBroker: relay failed not_allowed room=#{room_id} from=#{from} role=#{from_peer.role} to=#{to} role=#{to_peer.role}")
            {:reply, {:error, :not_allowed}, state}

          true ->
            Logger.debug("SignalingBroker: relaying room=#{room_id} type=#{type} from=#{from} to=#{to}")
            send(to_peer.pid, {:signaling_relay, type, from, payload})
            {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:broadcast, room_id, from, type, payload}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        Logger.warning("SignalingBroker: broadcast failed room_not_found room=#{room_id} from=#{from} type=#{type}")
        {:reply, {:error, :room_not_found}, state}

      room ->
        from_peer = Map.get(room.peers, from)

        if is_nil(from_peer) do
          Logger.warning("SignalingBroker: broadcast failed peer_not_found room=#{room_id} from=#{from}")
          {:reply, {:error, :peer_not_found}, state}
        else
          if room.topology == :star and from_peer.role != :host do
            Logger.warning("SignalingBroker: broadcast failed not_allowed room=#{room_id} from=#{from} role=#{from_peer.role}")
            {:reply, {:error, :not_allowed}, state}
          else
            targets = Enum.filter(room.peers, fn {peer_id, _} -> peer_id != from end) |> Enum.map(fn {id, _} -> id end)
            Logger.debug("SignalingBroker: broadcasting room=#{room_id} type=#{type} from=#{from} targets=#{length(targets)}")
            for {peer_id, %{pid: pid}} <- room.peers, peer_id != from do
              send(pid, {:signaling_relay, type, from, payload})
            end

            {:reply, :ok, state}
          end
        end
    end
  end

  @impl true
  def handle_call({:list_peers, room_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        Logger.warning("SignalingBroker: list_peers failed room_not_found room=#{room_id}")
        {:reply, {:error, :room_not_found}, state}

      room ->
        peers =
          Map.new(room.peers, fn {id, peer} ->
            {id, %{user_id: peer.user_id, role: peer.role, metadata: peer.metadata}}
          end)

        {:reply, peers, state}
    end
  end

  def handle_call({:is_host, room_id, user_id}, _from, state) do
    case Map.get(state.rooms, room_id) do
      nil ->
        {:reply, false, state}

      room ->
        {:reply, room.host_user_id == user_id, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        Logger.debug("SignalingBroker: DOWN from unknown pid=#{inspect(pid)} reason=#{inspect(reason)}")
        {:noreply, state}

      {{room_id, peer_id}, refs} ->
        case Map.get(state.rooms, room_id) do
          nil ->
            Logger.warning("SignalingBroker: DOWN for removed room room=#{room_id} peer=#{peer_id} pid=#{inspect(pid)} reason=#{inspect(reason)}")
            {:noreply, %{state | refs: refs}}

          room ->
            {_peer, peers} = Map.pop(room.peers, peer_id)
            remaining = map_size(peers)
            Logger.info("SignalingBroker: peer DOWN room=#{room_id} peer=#{peer_id} pid=#{inspect(pid)} reason=#{inspect(reason)} remaining_peers=#{remaining}")

            for {other_id, %{pid: pid}} <- peers, other_id != peer_id do
              send(pid, {:signaling_relay, :peer_left, peer_id, %{peer_id: peer_id}})
            end

            room = %{room | peers: peers}

            rooms =
              if map_size(peers) == 0 do
                Logger.info("SignalingBroker: room empty after DOWN, removing room=#{room_id}")
                Map.delete(state.rooms, room_id)
              else
                Map.put(state.rooms, room_id, room)
              end

            {:noreply, %{state | rooms: rooms, refs: refs}}
        end
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
