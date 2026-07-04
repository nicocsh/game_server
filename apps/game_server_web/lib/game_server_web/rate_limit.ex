defmodule GameServerWeb.RateLimit do
  @moduledoc """
  Rate limiter facade used by `GameServerWeb.Plugs.RateLimiter`, LiveView
  helpers, and channels.

  Delegates to one of two Hammer-powered backends:

  - `GameServerWeb.RateLimit.ETS` (default) — node-local counters.
  - `GameServerWeb.RateLimit.Redis` — counters shared across all app
    instances via Redis; use this for multi-instance deployments so limits
    hold cluster-wide.

  ## Configuration

      config :game_server_web, GameServerWeb.RateLimit,
        backend: :redis,
        redis: [url: "redis://localhost:6379"]

  Selected at runtime via the `RATE_LIMIT_BACKEND` env var (`"ets"` or
  `"redis"`); the Redis URL falls back to `RATE_LIMIT_REDIS_URL`,
  `CACHE_REDIS_URL`, then `REDIS_URL`.

  The configured backend is started in the host application supervision tree.
  """

  @spec hit(String.t(), pos_integer(), pos_integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(key, scale, limit) do
    case backend().hit(key, scale, limit) do
      {:allow, _count} = result ->
        result

      {:deny, _retry_after} = result ->
        :telemetry.execute(
          [:game_server, :rate_limit, :deny],
          %{count: 1},
          %{scope: scope_of(key)}
        )

        result
    end
  end

  # Bucket keys look like "auth:1.2.3.4" / "general:..." / "ws:..." — the
  # part before the first colon is the scope used for metrics.
  defp scope_of(key) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [scope, _rest] -> scope
      _ -> "unknown"
    end
  end

  defp scope_of(_key), do: "unknown"

  @doc "Returns the currently configured backend module."
  @spec backend() :: module()
  def backend do
    case Keyword.get(config(), :backend) do
      :redis -> GameServerWeb.RateLimit.Redis
      _ -> GameServerWeb.RateLimit.ETS
    end
  end

  @doc false
  def child_spec(opts) do
    case backend() do
      GameServerWeb.RateLimit.Redis = mod ->
        %{id: __MODULE__, start: {mod, :start_link, [Keyword.get(config(), :redis, [])]}}

      mod ->
        %{id: __MODULE__, start: {mod, :start_link, [opts]}}
    end
  end

  defp config do
    Application.get_env(:game_server_web, __MODULE__, [])
  end
end
