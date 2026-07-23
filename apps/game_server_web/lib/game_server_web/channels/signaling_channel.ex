defmodule GameServerWeb.SignalingChannel do
  @moduledoc """
  Channel for WebRTC signaling relay.

  Topic: `signaling:<room_id>`

  Rooms are created by a worker process (e.g. a lobby worker) through
  `SignalingBroker.create_room/3`.  Clients may only join if the room exists
  and they are a member of the corresponding lobby.  The topology and host
  are fixed at room creation; clients cannot choose their role.

  ## Lifecycle

  On join a unique `peer_id` is generated.  The broker assigns the role
  (`:host` or `:client` for `:star`, `:peer` for `:mesh`) based on the
  room's configuration and the authenticated user id.

  ## Messages

  Inbound events (from client):

      push("offer", %{target: "peer-uuid", sdp: "..."})
      push("answer", %{target: "peer-uuid", sdp: "..."})
      push("ice", %{target: "peer-uuid", candidate: "..."})
      push("broadcast_offer", %{sdp: "..."})

  Outbound events (to client):

      "offer"        — %{sdp: "...", from_peer_id: "..."}
      "answer"       — %{sdp: "...", from_peer_id: "..."}
      "ice"          — %{candidate: "...", from_peer_id: "..."}
      "peer_joined"  — %{peer_id: "...", role: :host | :client | :peer, user_id: "..."}
      "peer_left"    — %{peer_id: "..."}
      "room_closed"  — %{}
  """

  use Phoenix.Channel

  import GameServerWeb.ChannelPush
  require Logger

  alias GameServerWeb.SignalingBroker

  # WebSocket message rate limits (per user) — defaults, overridden by config
  @default_ws_rate_limit 300
  @default_ws_rate_window :timer.seconds(10)

  # Separate ICE candidate budget — prevents ICE flooding from starving
  # other channel events.  A typical WebRTC session sends 5–30 candidates.
  @default_ice_rate_limit 150
  @default_ice_rate_window :timer.seconds(30)

  @impl true
  def join("signaling:" <> room_id, _payload, socket) do
    user_id = socket.assigns.current_scope.user_id

    if is_nil(user_id) do
      Logger.warning("SignalingChannel: unauthorized join attempt room=#{room_id} missing user_id")
      {:error, %{reason: "unauthorized"}}
    else
      user = GameServer.Accounts.get_user(user_id)
      is_host = SignalingBroker.is_host?(room_id, user_id)
      #Logger.warning(is_host)

      if not is_host and (is_nil(user.lobby_id) or user.lobby_id != room_id) do
        Logger.warning("SignalingChannel: join rejected not_lobby_member room=#{room_id} user=#{user_id} user_lobby=#{user.lobby_id || "nil"}")
        {:error, %{reason: "not_lobby_member"}}
      else
        peer_id = Ecto.UUID.generate()

        case SignalingBroker.join(room_id, peer_id, self(), user_id, %{}) do
          {:ok, role} ->
            Logger.info("SignalingChannel: join ok room=#{room_id} peer=#{peer_id} user=#{user_id} role=#{role}")
            {:ok, %{peer_id: peer_id, role: role},
            assign(socket,
              signaling_room: room_id,
              signaling_peer_id: peer_id,
              signaling_role: role
            )}

          {:error, :room_not_found} ->
            Logger.warning("SignalingChannel: join failed room_not_found room=#{room_id} user=#{user_id}")
            {:error, %{reason: "room_not_found"}}

          {:error, :duplicate_peer} ->
            Logger.warning("SignalingChannel: join failed duplicate_peer room=#{room_id} user=#{user_id}")
            {:error, %{reason: "duplicate_peer"}}
        end
      end
    end
  end

  # ── Signaling relay ──────────────────────────────────────────────────────

  @impl true
  def handle_in("offer", %{"target" => target, "sdp" => sdp}, socket) do
    with :ok <- check_ws_rate_limit(socket) do
      room = socket.assigns.signaling_room
      from = socket.assigns.signaling_peer_id

      case SignalingBroker.relay(room, from, target, :offer, %{sdp: sdp}) do
        :ok ->
          {:reply, {:ok, %{}}, socket}

        {:error, :peer_not_found} ->
          Logger.warning("SignalingChannel: offer failed peer_not_found room=#{room} from=#{from} target=#{target}")
          {:reply, {:error, %{error: "peer_not_found"}}, socket}

        {:error, :not_allowed} ->
          Logger.warning("SignalingChannel: offer failed not_allowed room=#{room} from=#{from} target=#{target}")
          {:reply, {:error, %{error: "not_allowed"}}, socket}

        {:error, :room_not_found} ->
          Logger.warning("SignalingChannel: offer failed room_not_found room=#{room} from=#{from}")
          {:stop, :normal, {:error, %{error: "room_not_found"}}, socket}
      end
    end
  end

  @impl true
  def handle_in("answer", %{"target" => target, "sdp" => sdp}, socket) do
    with :ok <- check_ws_rate_limit(socket) do
      room = socket.assigns.signaling_room
      from = socket.assigns.signaling_peer_id

      case SignalingBroker.relay(room, from, target, :answer, %{sdp: sdp}) do
        :ok ->
          {:reply, {:ok, %{}}, socket}

        {:error, :peer_not_found} ->
          Logger.warning("SignalingChannel: answer failed peer_not_found room=#{room} from=#{from} target=#{target}")
          {:reply, {:error, %{error: "peer_not_found"}}, socket}

        {:error, :not_allowed} ->
          Logger.warning("SignalingChannel: answer failed not_allowed room=#{room} from=#{from} target=#{target}")
          {:reply, {:error, %{error: "not_allowed"}}, socket}

        {:error, :room_not_found} ->
          Logger.warning("SignalingChannel: answer failed room_not_found room=#{room} from=#{from}")
          {:stop, :normal, {:error, %{error: "room_not_found"}}, socket}
      end
    end
  end

  @impl true
  def handle_in("ice", %{"target" => target, "candidate" => candidate}, socket) do
    with :ok <- check_ice_rate_limit(socket) do
      room = socket.assigns.signaling_room
      from = socket.assigns.signaling_peer_id

      case SignalingBroker.relay(room, from, target, :ice, %{candidate: candidate}) do
        :ok ->
          {:reply, {:ok, %{}}, socket}

        {:error, :peer_not_found} ->
          Logger.warning("SignalingChannel: ice failed peer_not_found room=#{room} from=#{from} target=#{target}")
          {:reply, {:error, %{error: "peer_not_found"}}, socket}

        {:error, :not_allowed} ->
          Logger.warning("SignalingChannel: ice failed not_allowed room=#{room} from=#{from} target=#{target}")
          {:reply, {:error, %{error: "not_allowed"}}, socket}

        {:error, :room_not_found} ->
          Logger.warning("SignalingChannel: ice failed room_not_found room=#{room} from=#{from}")
          {:stop, :normal, {:error, %{error: "room_not_found"}}, socket}
      end
    end
  end

  @impl true
  def handle_in("broadcast_offer", %{"sdp" => sdp}, socket) do
    with :ok <- check_ws_rate_limit(socket) do
      room = socket.assigns.signaling_room
      from = socket.assigns.signaling_peer_id

      case SignalingBroker.broadcast(room, from, :offer, %{sdp: sdp, from_peer_id: from}) do
        :ok ->
          {:reply, {:ok, %{}}, socket}

        {:error, :not_allowed} ->
          Logger.warning("SignalingChannel: broadcast_offer failed not_allowed room=#{room} from=#{from}")
          {:reply, {:error, %{error: "not_allowed"}}, socket}

        {:error, :room_not_found} ->
          Logger.warning("SignalingChannel: broadcast_offer failed room_not_found room=#{room} from=#{from}")
          {:stop, :normal, {:error, %{error: "room_not_found"}}, socket}
      end
    end
  end

  @impl true
  def handle_in("list_peers", _payload, socket) do
    with :ok <- check_ws_rate_limit(socket) do
      room = socket.assigns.signaling_room

      case SignalingBroker.list_peers(room) do
        peers when is_map(peers) ->
          {:reply, {:ok, %{peers: peers}}, socket}

        {:error, :room_not_found} ->
          Logger.warning("SignalingChannel: list_peers failed room_not_found room=#{room}")
          {:stop, :normal, {:error, %{error: "room_not_found"}}, socket}
      end
    end
  end

  @impl true
  def handle_in(event, _payload, socket) do
    Logger.warning("SignalingChannel: unknown event=#{event} room=#{socket.assigns[:signaling_room] || "nil"} peer=#{socket.assigns[:signaling_peer_id] || "nil"}")
    {:reply, {:error, %{error: "unknown_event"}}, socket}
  end

  # ── Broker relay messages ────────────────────────────────────────────────

  @impl true
  def handle_info({:signaling_relay, :room_closed, nil, payload}, socket) do
    Logger.info("SignalingChannel: room_closed received, stopping room=#{socket.assigns.signaling_room} peer=#{socket.assigns.signaling_peer_id}")
    push_event(socket, "room_closed", payload)
    {:stop, :normal, socket}
  end

  @impl true
  def handle_info({:signaling_relay, type, from_peer_id, payload}, socket) do
    event_name = relay_event_name(type)
    payload = if is_nil(from_peer_id), do: payload, else: Map.put(payload, :from_peer_id, from_peer_id)
    push_event(socket, event_name, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:channel_updates_flush, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("SignalingChannel: unexpected msg=#{inspect(msg)} room=#{socket.assigns[:signaling_room] || "nil"} peer=#{socket.assigns[:signaling_peer_id] || "nil"}")
    {:noreply, socket}
  end

  @impl true
  def terminate(reason, socket) do
    room_id = socket.assigns[:signaling_room]
    peer_id = socket.assigns[:signaling_peer_id]

    if room_id && peer_id do
      Logger.info("SignalingChannel: terminating reason=#{inspect(reason)} room=#{room_id} peer=#{peer_id}")
      SignalingBroker.leave(room_id, peer_id)
    else
      Logger.debug("SignalingChannel: terminating without room/peer reason=#{inspect(reason)}")
    end

    :ok
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp relay_event_name(:offer), do: "offer"
  defp relay_event_name(:answer), do: "answer"
  defp relay_event_name(:ice), do: "ice"
  defp relay_event_name(:peer_joined), do: "peer_joined"
  defp relay_event_name(:peer_left), do: "peer_left"
  defp relay_event_name(:room_closed), do: "room_closed"

  # ── WebSocket rate limiting ─────────────────────────────────────────────

  defp check_ws_rate_limit(socket) do
    config = Application.get_env(:game_server_web, GameServerWeb.Plugs.RateLimiter, [])

    if Keyword.get(config, :enabled, true) do
      user_id = socket.assigns.current_scope.user_id
      limit = Keyword.get(config, :signaling_ws_limit, @default_ws_rate_limit)
      window = Keyword.get(config, :signaling_ws_window, @default_ws_rate_window)

      case GameServerWeb.RateLimit.hit("signaling_ws:#{user_id}", window, limit) do
        {:allow, _count} ->
          :ok

        {:deny, _retry_after} ->
          Logger.warning("SignalingChannel: rate limit exceeded user=#{user_id} room=#{socket.assigns[:signaling_room] || "nil"}")
          {:stop, :normal, {:error, %{error: "rate_limited"}}, socket}
      end
    else
      :ok
    end
  end

  defp check_ice_rate_limit(socket) do
    config = Application.get_env(:game_server_web, GameServerWeb.Plugs.RateLimiter, [])

    if Keyword.get(config, :enabled, true) do
      user_id = socket.assigns.current_scope.user_id
      limit = Keyword.get(config, :signaling_ice_limit, @default_ice_rate_limit)
      window = Keyword.get(config, :signaling_ice_window, @default_ice_rate_window)

      case GameServerWeb.RateLimit.hit("signaling_ice:#{user_id}", window, limit) do
        {:allow, _count} ->
          :ok

        {:deny, _retry_after} ->
          Logger.warning("SignalingChannel: ICE rate limit exceeded user=#{user_id} room=#{socket.assigns[:signaling_room] || "nil"}")
          {:reply, {:error, %{error: "ice_rate_limited"}}, socket}
      end
    else
      :ok
    end
  end
end
