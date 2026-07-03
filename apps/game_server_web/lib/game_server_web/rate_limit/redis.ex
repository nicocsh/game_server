defmodule GameServerWeb.RateLimit.Redis do
  @moduledoc """
  Redis-backed rate limiter backend powered by Hammer + Redix.

  Counters live in Redis, so limits are enforced across all app instances
  sharing the same Redis — the right choice for multi-instance deployments.
  """
  use Hammer, backend: Hammer.Redis, prefix: "game_server:rate_limit:"
end
