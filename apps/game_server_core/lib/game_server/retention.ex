defmodule GameServer.Retention do
  @moduledoc """
  Periodically prunes old rows from unbounded tables.

  Retention is configured per table in days via env vars (see
  `config/host_runtime.exs`); `0` or unset keeps data forever:

  - `RETENTION_CHAT_DAYS` — `chat_messages` older than N days
  - `RETENTION_NOTIFICATIONS_DAYS` — `notifications` older than N days
  - `RETENTION_PAYMENT_EVENTS_DAYS` — payment provider webhook events older
    than N days (purchases/entitlements are never pruned)
  - `RETENTION_LOBBY_SNAPSHOTS_DAYS` — lobby snapshots, events and their
    content blobs. Unlike the others this defaults to 30 rather than "keep
    forever": snapshots hold user metadata, and the window is what bounds that
    exposure. Runs flagged anomalous keep
    `RETENTION_LOBBY_SNAPSHOTS_FLAGGED_DAYS` instead (default 90).

  Expired IP bans and OAuth sessions older than a day are always removed
  (independent of the env vars above). Deletes are idempotent, so running on
  several instances at once is harmless.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias GameServer.LobbySnapshots.{Blob, Event, Snapshot}
  alias GameServer.Repo

  # First run shortly after boot, then every 6 hours.
  @initial_delay_ms :timer.minutes(5)
  @interval_ms :timer.hours(6)

  # OAuth sessions are ephemeral handshake state (seconds-to-minutes of use);
  # always prune stale rows so the table can't grow unbounded.
  @oauth_session_ttl_days 1

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :prune, @initial_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    _ = prune_all()
    Process.send_after(self(), :prune, @interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Runs all configured pruning steps once. Returns a map of deleted row
  counts per table.
  """
  @spec prune_all() :: %{atom() => non_neg_integer()}
  def prune_all do
    results = %{
      chat_messages: prune_older_than(GameServer.Chat.Message, config(:chat_messages_days)),
      notifications:
        prune_older_than(GameServer.Notifications.Notification, config(:notifications_days)),
      payment_events:
        prune_older_than(GameServer.Payments.ProviderEvent, config(:payment_events_days)),
      oauth_sessions: prune_older_than(GameServer.OAuthSession, @oauth_session_ttl_days),
      expired_ip_bans: prune_expired_ip_bans(),
      lobby_snapshots: prune_lobby_snapshots(),
      lobby_snapshot_blobs: prune_lobby_snapshot_blobs()
    }

    pruned = results |> Map.values() |> Enum.sum()

    if pruned > 0 do
      Logger.info("retention pruned rows: #{inspect(results)}")
    end

    results
  end

  defp prune_older_than(_schema, days) when not is_integer(days) or days <= 0, do: 0

  defp prune_older_than(schema, days) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -days, :day)

    {count, _} = Repo.delete_all(from(r in schema, where: r.inserted_at < ^cutoff))
    count
  end

  # Lobby snapshots and events expire together, per run rather than per row: a
  # run is flagged if *any* of its snapshots is, and a flagged run keeps its
  # events too. Retention is not just housekeeping here — snapshots hold user
  # metadata and KV, and an account deletion cannot reach data embedded in
  # JSONB, so this window is the mechanism that actually bounds that exposure.
  defp prune_lobby_snapshots do
    days = config(:lobby_snapshots_days)

    if is_integer(days) and days > 0 do
      # Never shorter than the normal window, or flagged runs would expire first
      # — the opposite of the point.
      flagged_days = max(config(:lobby_snapshots_flagged_days), days)

      cutoff = cutoff(days)
      flagged_cutoff = cutoff(flagged_days)

      # Outer window first: it applies to every run, flagged included.
      prune_snapshots_before(flagged_cutoff, :all) +
        prune_snapshots_before(cutoff, :unflagged_runs)
    else
      0
    end
  end

  defp prune_snapshots_before(cutoff, scope) do
    events = from(e in Event, where: e.inserted_at < ^cutoff)
    snapshots = from(s in Snapshot, where: s.inserted_at < ^cutoff)

    {event_count, _} = Repo.delete_all(scope_to_unflagged(events, scope))
    {snapshot_count, _} = Repo.delete_all(scope_to_unflagged(snapshots, scope))

    event_count + snapshot_count
  end

  defp scope_to_unflagged(query, :all), do: query

  defp scope_to_unflagged(query, :unflagged_runs) do
    from r in query,
      as: :row,
      where:
        not exists(
          from s in Snapshot,
            where: s.lobby_id == parent_as(:row).lobby_id and s.flagged,
            select: 1
        )
  end

  # Safe to prune by age only because the writer touches last_referenced_at on
  # every reference. The window is the flagged one, so a blob outlives the
  # longest-lived snapshot that could still point at it.
  defp prune_lobby_snapshot_blobs do
    days = config(:lobby_snapshots_days)

    if is_integer(days) and days > 0 do
      cutoff = cutoff(max(config(:lobby_snapshots_flagged_days), days))

      {count, _} = Repo.delete_all(from(b in Blob, where: b.last_referenced_at < ^cutoff))
      count
    else
      0
    end
  end

  defp cutoff(days), do: DateTime.add(DateTime.utc_now(:second), -days, :day)

  defp prune_expired_ip_bans do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.delete_all(
        from(b in GameServer.IpBans.IpBan,
          where: not is_nil(b.expires_at) and b.expires_at < ^now
        )
      )

    count
  end

  defp config(key) do
    :game_server_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, 0)
  end
end
