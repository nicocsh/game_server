defmodule GameServerWeb.UserSocket do
  use Phoenix.Socket

  alias GameServer.Accounts.Scope
  alias GameServerWeb.Auth.Guardian

  # A Socket handler
  #
  # It's possible to control the websocket connection and
  # assign values that can be accessed by your channel topics.

  ## Channels
  #
  # Declared as data so the list is enumerable (Phoenix's `channel` macro only
  # generates a `__channel__/1` dispatch head). The startup banner and the
  # admin runtime page read `__channels__/0`.
  @channels [
    {"user:*", GameServerWeb.UserChannel,
     "Per-user events: profile, notifications, invites, KV, matchmaking, tournaments"},
    {"lobby:*", GameServerWeb.LobbyChannel,
     "One lobby: state, membership, chat, WebRTC signalling"},
    {"lobbies", GameServerWeb.LobbiesChannel,
     "Global lobby list: created/updated/deleted, membership counts"},
    {"group:*", GameServerWeb.GroupChannel, "One group: state, members, join requests, chat"},
    {"groups", GameServerWeb.GroupsChannel, "Global group list: created/updated/deleted"},
    {"party:*", GameServerWeb.PartyChannel, "One party: state, members, chat, disband"},
    {"signaling:*", GameServerWeb.SignalingChannel, "Signaling channel for WebRTC"}
  ]

  for {pattern, module, _description} <- @channels do
    channel(pattern, module)
  end

  @doc "All channel routes as `{topic_pattern, module, description}`."
  def __channels__, do: @channels

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error` or `{:error, term}`. To control the
  # response the client receives in that case, [define an error handler in the
  # websocket
  # configuration](https://hexdocs.pm/phoenix/Phoenix.Endpoint.html#socket/3-websocket-configuration).
  #
  # See `Phoenix.Token` documentation for examples in
  # performing token verification on connect.
  @impl true
  # Generic connect that attempts to extract a token from a variety of
  # param shapes (plain map, nested under "params" or :params, etc.).
  # Unauthenticated connections are rejected (connection-exhaustion DoS
  # guard) — all channel functionality requires a valid JWT token — and
  # each user may hold at most :max_sockets_per_user concurrent sockets.
  def connect(params, socket, _connect_info) do
    with token when is_binary(token) <- extract_token(params),
         {:ok, claims} <- Guardian.decode_and_verify(token),
         {:ok, user} <- Guardian.resource_from_claims(claims),
         false <- socket_limit_reached?(user.id) do
      GameServerWeb.ConnectionTracker.register(:ws_socket, %{
        user_id: user.id,
        authenticated: true
      })

      socket =
        socket
        |> assign(:current_scope, Scope.for_user(user))
        |> assign(:ws_format, extract_format(params, socket))

      {:ok, socket}
    else
      _ -> :error
    end
  end

  # Server->client event payload format: "json" (default) or "protobuf".
  # Protobuf events are delivered as binary frames encoded per
  # proto/gamend_realtime.proto; client->server pushes remain JSON.
  defp extract_format(%{params: %{"format" => f}}, socket), do: normalize_format(f, socket)
  defp extract_format(%{"params" => %{"format" => f}}, socket), do: normalize_format(f, socket)
  defp extract_format(%{"format" => f}, socket), do: normalize_format(f, socket)
  defp extract_format(_, _socket), do: "json"

  # Binary frames require the V2 channel protocol; the V1 serializer (vsn
  # 1.x, the Phoenix default) cannot emit them, so "protobuf" is only
  # honored on sockets that negotiated a binary-capable serializer.
  defp normalize_format("protobuf", %{serializer: serializer})
       when serializer != Phoenix.Socket.V1.JSONSerializer,
       do: "protobuf"

  defp normalize_format(_, _), do: "json"

  # 0 disables; counted per app instance.
  defp socket_limit_reached?(user_id) do
    limit = GameServer.Limits.get(:max_sockets_per_user)

    is_integer(limit) and limit > 0 and
      GameServerWeb.ConnectionTracker.list_registered(:ws_socket)
      |> Enum.count(fn {_pid, meta} -> Map.get(meta, :user_id) == user_id end) >= limit
  end

  # Extract token from various parameter shapes:
  # - ChannelTest passes %{params: %{"token" => ...}, ...}
  # - Real WebSocket might pass %{"token" => ...} directly
  defp extract_token(%{params: %{"token" => token}}), do: token
  defp extract_token(%{"params" => %{"token" => token}}), do: token
  defp extract_token(%{"token" => token}), do: token
  defp extract_token(%{token: token}), do: token
  defp extract_token(_), do: nil

  # Return a user-scoped socket ID so we can force-disconnect a specific user:
  #
  #     GameServerWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  @impl true
  def id(socket) do
    case socket.assigns[:current_scope] do
      %{user_id: user_id} -> "user_socket:#{user_id}"
      _ -> nil
    end
  end
end
