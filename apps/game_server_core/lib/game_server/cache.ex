defmodule GameServer.Cache do
  @moduledoc """
  Application cache backed by Nebulex.

  This cache uses a 2-level (near-cache) topology via
  `Nebulex.Adapters.Multilevel`:

  - L1: local in-memory cache (`GameServer.Cache.L1`)
  - L2: either Redis (`GameServer.Cache.L2.Redis`) or a partitioned topology
    (`GameServer.Cache.L2.Partitioned`), selected via runtime config.
  """

  use Nebulex.Cache,
    otp_app: :game_server_core,
    adapter: Nebulex.Adapters.Multilevel

  @doc """
  Cache-through helper: returns the cached value for `key`, or computes and
  caches the result of `fun`.

  Cached `nil` results are honored — `fun` only runs on a real cache miss.

  ## Options

  - `:ttl` — time-to-live in milliseconds
  """
  @spec cached(term(), keyword(), (-> term())) :: term()
  def cached(key, opts \\ [], fun) when is_function(fun, 0) do
    case fetch(key) do
      {:ok, value} ->
        value

      {:error, _miss_or_error} ->
        result = fun.()
        _ = put(key, result, opts)
        result
    end
  end

  @invalidation_topic "cache:invalidate"

  @doc """
  Deletes `key` on this node (all cache levels) and broadcasts the deletion so
  every other app instance evicts the key from its local L1
  (see `GameServer.Cache.Sync`).

  Use this instead of `delete/1` whenever a stale read would be *incorrect*
  rather than merely briefly outdated — e.g. cached user structs that gate
  authentication (`token_version`) or account state (`is_activated`).
  """
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    _ = delete(key)

    Phoenix.PubSub.broadcast(
      GameServer.PubSub,
      @invalidation_topic,
      {:cache_invalidate, key, Node.self()}
    )

    :ok
  end

  @doc "PubSub topic that `invalidate/1` broadcasts on."
  @spec invalidation_topic() :: String.t()
  def invalidation_topic, do: @invalidation_topic
end
