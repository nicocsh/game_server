defmodule GameServerWeb.RateLimit.ETS do
  @moduledoc """
  Node-local rate limiter backend powered by Hammer's ETS backend.

  Fast and dependency-free, but each app instance keeps its own counters —
  in multi-instance deployments the effective limit is multiplied by the
  number of instances. Use `GameServerWeb.RateLimit.Redis` there instead.
  """
  use Hammer, backend: :ets
end
