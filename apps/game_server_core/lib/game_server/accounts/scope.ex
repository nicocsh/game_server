defmodule GameServer.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The scope carries only the caller's `user_id`, never a cached `%User{}`
  snapshot: a scope can outlive the request that built it (a socket stays open
  for hours), so the user is always resolved fresh via `user/1`, which reads
  through `GameServer.Accounts.get_user/1`'s cache. This keeps mutable state
  (lobby_id, online, is_admin) current instead of frozen at connect time.

  A `%Scope{}` always represents an authenticated caller — `for_user/1` returns
  `nil` for an anonymous one — so a `%Scope{}` match implies a present user_id.

  `authenticated_at` is a session fact (from the session token, virtual on
  `User`) that cannot be re-derived from the DB row, so it is carried on the
  scope and merged back onto the freshly-resolved user by `user/1` — this is
  what `sudo_mode?` checks.
  """

  alias GameServer.Accounts.User

  defstruct user_id: nil, authenticated_at: nil

  @doc "Creates a scope for the given user, or nil when anonymous."
  def for_user(%User{} = user),
    do: %__MODULE__{user_id: user.id, authenticated_at: user.authenticated_at}

  def for_user(nil), do: nil

  @doc "The caller's id, or nil for a nil scope."
  def user_id(%__MODULE__{user_id: id}), do: id
  def user_id(_), do: nil

  @doc """
  Resolves the caller's user fresh (cached), with the session's
  `authenticated_at` merged back on. nil if the scope is nil or the user is gone.
  """
  def user(%__MODULE__{user_id: id, authenticated_at: at}) when is_binary(id) do
    case GameServer.Accounts.get_user(id) do
      %User{} = user -> %{user | authenticated_at: at}
      other -> other
    end
  end

  def user(_), do: nil
end
