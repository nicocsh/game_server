defmodule GameServerWeb.UserLive.Settings.Shared do
  @moduledoc false

  alias GameServer.Accounts.Scope

  @doc "Returns the current user from the socket's scope, or nil."
  def current_user(socket), do: Scope.user(socket.assigns[:current_scope])
end
