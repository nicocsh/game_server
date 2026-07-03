defmodule GameServer.IpBans do
  @moduledoc """
  Persistence for IP bans.

  `GameServerWeb.Plugs.IpBan` keeps the hot-path check in ETS; this context
  is the durable source of truth so bans survive restarts and can be shared
  across instances (each instance loads them at boot and applies PubSub
  updates).
  """

  import Ecto.Query

  alias GameServer.IpBans.IpBan
  alias GameServer.Repo

  @doc """
  Creates or updates a ban for `ip`. `expires_at` is `nil` for a permanent ban.
  """
  @spec upsert_ban(String.t(), DateTime.t() | nil) ::
          {:ok, IpBan.t()} | {:error, Ecto.Changeset.t()}
  def upsert_ban(ip, expires_at) when is_binary(ip) do
    %IpBan{}
    |> IpBan.changeset(%{ip: ip, expires_at: expires_at})
    |> Repo.insert(
      on_conflict: {:replace, [:expires_at, :updated_at]},
      conflict_target: :ip
    )
  end

  @doc "Deletes the ban for `ip` (no-op if none exists)."
  @spec delete_ban(String.t()) :: :ok
  def delete_ban(ip) when is_binary(ip) do
    Repo.delete_all(from(b in IpBan, where: b.ip == ^ip))
    :ok
  end

  @doc "Lists all bans that are permanent or not yet expired."
  @spec list_active() :: [IpBan.t()]
  def list_active do
    now = DateTime.utc_now()

    Repo.all(from(b in IpBan, where: is_nil(b.expires_at) or b.expires_at > ^now))
  end

  @doc "Deletes expired bans. Returns the number of rows removed."
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    now = DateTime.utc_now()

    {count, _} =
      Repo.delete_all(from(b in IpBan, where: not is_nil(b.expires_at) and b.expires_at <= ^now))

    count
  end
end
