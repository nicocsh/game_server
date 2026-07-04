defmodule GameServerWeb.PromEx.CachePlugin do
  @moduledoc """
  Custom PromEx plugin exporting cache-effectiveness and overload metrics.

  Tracks:

  - `game_server_cache_reads_total` — counter tagged by `prefix` (first
    element of the cache key tuple) and `outcome` (`hit`/`miss`), from
    Nebulex `[:game_server, :cache, :command, :stop]` events (`:fetch` only).
  - `game_server_rate_limit_denies_total` — counter tagged by `scope`
    (`auth`/`general`/`ws`/…), emitted by `GameServerWeb.RateLimit`.
  - `game_server_async_overload_total` — async tasks run inline because
    `GameServer.TaskSupervisor` was at capacity.
  """

  use PromEx.Plugin

  alias GameServer.Cache.Stats

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(
        :game_server_cache_metrics,
        [
          counter(
            [:game_server, :cache, :reads, :total],
            event_name: [:game_server, :cache, :command, :stop],
            measurement: :duration,
            description: "Cache reads by key prefix and hit/miss outcome.",
            keep: fn metadata ->
              metadata.command == :fetch and Stats.classify_result(metadata.result) != :ignore
            end,
            tags: [:prefix, :outcome],
            tag_values: fn metadata ->
              %{
                prefix: metadata.args |> hd() |> Stats.key_prefix(),
                outcome: Stats.classify_result(metadata.result)
              }
            end
          ),
          counter(
            [:game_server, :rate_limit, :denies, :total],
            event_name: [:game_server, :rate_limit, :deny],
            measurement: :count,
            description: "Rate limiter denials by scope.",
            tags: [:scope]
          ),
          counter(
            [:game_server, :async, :overload, :total],
            event_name: [:game_server, :async, :overload],
            measurement: :count,
            description: "Async tasks executed inline because the task supervisor was full."
          )
        ]
      )
    ]
  end
end
