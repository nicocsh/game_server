defmodule GameServerWeb.PlayLive do
  @moduledoc """
  LiveView wrapper that embeds the Godot web export (`/game/index.html`)
  inside the app layout so the navbar is visible.

  The game itself runs in an iframe with its own COOP/COEP headers
  (set by `GameServerWeb.Plugs.GameHeaders`) so `SharedArrayBuffer` works.

  When the user is session-authenticated, this LiveView mints a short-lived
  JWT access-token (and a refresh-token) so the Godot game can call the API.
  Tokens are delivered in two ways:

    1. **URL fragment** – the iframe `src` becomes
       `/game/index.html#access_token=…&refresh_token=…`
       (fragment never leaves the browser).
    2. **localStorage** – a JS hook writes `gamend_access_token` and
       `gamend_refresh_token` so the game can also read them with
       `JavaScriptBridge.eval("localStorage.getItem('gamend_access_token')")`.
  """
  use GameServerWeb, :live_view

  alias GameServerWeb.Auth.Guardian

  @impl true
  def mount(_params, _session, socket) do
    {game_src, token_data} = build_game_url(socket.assigns.current_scope)

    {:ok,
     assign(socket,
       game_src: game_src,
       token_data: token_data
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      flush
    >
      <div
        id="game-container"
        phx-hook="GameViewport"
        class="relative w-full h-full overflow-hidden"
        style="touch-action: manipulation;"
      >
        <div
          id="game-auth"
          phx-hook="GameAuth"
          phx-update="ignore"
          data-access-token={@token_data[:access_token] || ""}
          data-refresh-token={@token_data[:refresh_token] || ""}
        >
        </div>

        <iframe
          id="game-frame"
          src={@game_src}
          class="w-full h-full border-0"
          allow="autoplay; fullscreen"
          allowfullscreen
          phx-update="ignore"
        ></iframe>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_game_url(nil), do: {"/game/index.html", %{}}
  defp build_game_url(%{user: nil}), do: {"/game/index.html", %{}}

  defp build_game_url(%{user: user}) do
    with {:ok, access_token, _claims} <-
           Guardian.encode_and_sign(user, %{}, token_type: "access"),
         {:ok, refresh_token, _claims} <-
           Guardian.encode_and_sign(user, %{}, token_type: "refresh", ttl: {30, :days}) do
      fragment =
        URI.encode_query(%{
          "access_token" => access_token,
          "refresh_token" => refresh_token
        })

      {"/game/index.html##{fragment}",
       %{access_token: access_token, refresh_token: refresh_token}}
    else
      _error ->
        {"/game/index.html", %{}}
    end
  end
end
