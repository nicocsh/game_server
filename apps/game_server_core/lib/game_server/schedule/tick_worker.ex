defmodule GameServer.Schedule.TickWorker do
  @moduledoc false
  # Runs once per minute via Oban's Cron plugin (leader-elected, so exactly one
  # tick fires per minute cluster-wide). It fans out the plugin-registered cron
  # callbacks whose schedule matches the current minute — see
  # `GameServer.Schedule.enqueue_due/1`.

  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    GameServer.Schedule.enqueue_due(DateTime.utc_now())
  end
end
