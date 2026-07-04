defmodule GameServerWeb.UserLive.Settings.Shared do
  @moduledoc false

  @doc "Returns the current user from the socket's scope, or nil."
  def current_user(socket) do
    case socket.assigns do
      %{current_scope: %{user: user}} -> user
      _ -> nil
    end
  end
end
