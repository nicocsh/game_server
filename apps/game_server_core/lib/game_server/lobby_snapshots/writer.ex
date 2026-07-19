defmodule GameServer.LobbySnapshots.Writer do
  @moduledoc """
  Buffers snapshots and events and bulk-inserts them.

  Buffering is the point: `record_event/4` is called from inside the serialized
  game loop, where a synchronous DB round trip shows up as gameplay stutter. An
  enqueue is a `cast` and returns immediately.

  This is a plain per-node process, not a singleton. Ordering comes from
  `(inserted_at, id)` with UUIDv7 ids, so nothing has to be centrally assigned
  and two nodes writing for the same lobby interleave correctly on read.

  Durability is best-effort, deliberately. A run bad enough to take the node
  down is one worth keeping, so the buffer flushes on `terminate/2` and holds at
  most #{200}ms of work. A failed flush discards its batch and counts it — that
  is what keeps a DB outage from growing the buffer without bound, degrading
  into lost history rather than an OOM that takes the server with it. `stats/0`
  exposes the count so a silently-lossy writer stays visible.
  """

  use GenServer

  require Logger

  alias GameServer.LobbySnapshots.{Blob, Event, Snapshot}
  alias GameServer.Repo

  @flush_interval_ms 200
  @flush_at_rows 100

  ## Client

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Buffer a gathered snapshot. Sections arrive pre-hashed as `%{name => {hash, content}}`."
  @spec enqueue_snapshot(map()) :: :ok
  def enqueue_snapshot(attrs), do: cast({:snapshot, attrs})

  @doc "Buffer an event."
  @spec enqueue_event(map()) :: :ok
  def enqueue_event(attrs), do: cast({:event, attrs})

  @doc "Flush synchronously. Used by tests and by callers that need the write visible."
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush, 15_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Buffer depth and dropped-row count for *this node's* writer."
  @spec stats() :: %{buffered: non_neg_integer(), dropped: non_neg_integer()}
  def stats do
    GenServer.call(__MODULE__, :stats, 5_000)
  catch
    :exit, _ -> %{buffered: 0, dropped: 0}
  end

  @doc """
  Writer stats summed across the cluster.

  Each node buffers independently, so reading only the local process would
  under-report dropped rows — and a silently-lossy writer is the one thing the
  admin view most needs to show. Unreachable nodes are counted rather than
  failing the call, so the number is never quietly wrong without saying so.
  """
  @spec cluster_stats() :: %{
          buffered: non_neg_integer(),
          dropped: non_neg_integer(),
          nodes: pos_integer(),
          unreachable: non_neg_integer()
        }
  def cluster_stats do
    nodes = [node() | Node.list()]

    {results, bad} =
      nodes
      |> :erpc.multicall(__MODULE__, :stats, [], 5_000)
      |> Enum.split_with(&match?({:ok, %{}}, &1))

    Enum.reduce(
      results,
      %{buffered: 0, dropped: 0, nodes: length(nodes), unreachable: length(bad)},
      fn
        {:ok, stats}, acc ->
          %{acc | buffered: acc.buffered + stats.buffered, dropped: acc.dropped + stats.dropped}
      end
    )
  end

  defp cast(msg) do
    GenServer.cast(__MODULE__, msg)
  catch
    # Writer not running (tests, or a restart in flight). Losing debug telemetry
    # must never surface as an error to the caller's real work.
    :exit, _ -> :ok
  end

  ## Server

  @impl true
  def init(_opts) do
    # So a shutdown runs terminate/2 and flushes rather than dropping the
    # buffer, which would lose the tail of exactly the runs worth keeping.
    Process.flag(:trap_exit, true)

    {:ok, %{snapshots: [], events: [], blobs: %{}, rows: 0, dropped: 0, timer: nil}}
  end

  @impl true
  def handle_cast({:snapshot, attrs}, state) do
    now = DateTime.utc_now()

    section_hashes = Map.new(attrs.sections, fn {name, {hash, _content}} -> {name, hash} end)

    blobs =
      Enum.reduce(attrs.sections, state.blobs, fn {_name, {hash, content}}, acc ->
        Map.put_new_lazy(acc, hash, fn -> blob_row(hash, content, now) end)
      end)

    row = %{
      id: GameServer.UUIDv7.generate(),
      lobby_id: attrs.lobby_id,
      trigger: attrs.trigger,
      section_hashes: section_hashes,
      flagged: Map.get(attrs, :flagged, false),
      user_id: Map.get(attrs, :user_id),
      inserted_at: now
    }

    state
    |> Map.put(:blobs, blobs)
    |> Map.update!(:snapshots, &[row | &1])
    |> bump_rows()
    |> maybe_flush()
  end

  def handle_cast({:event, attrs}, state) do
    row = %{
      id: GameServer.UUIDv7.generate(),
      lobby_id: attrs.lobby_id,
      kind: attrs.kind,
      payload: Map.get(attrs, :payload, %{}),
      user_id: Map.get(attrs, :user_id),
      # Stamped at enqueue, not at flush, so buffering never distorts ordering.
      inserted_at: DateTime.utc_now()
    }

    state
    |> Map.update!(:events, &[row | &1])
    |> bump_rows()
    |> maybe_flush()
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

  def handle_call(:stats, _from, state) do
    {:reply, %{buffered: state.rows, dropped: state.dropped}, state}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, do_flush(%{state | timer: nil})}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = do_flush(state)
    :ok
  end

  ## Buffering

  defp bump_rows(state), do: %{state | rows: state.rows + 1}

  defp maybe_flush(state) when state.rows >= @flush_at_rows do
    {:noreply, do_flush(state)}
  end

  defp maybe_flush(state), do: {:noreply, schedule_flush(state)}

  defp schedule_flush(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :flush, @flush_interval_ms)}
  end

  defp schedule_flush(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    _ = Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  ## Flushing

  defp do_flush(%{rows: 0} = state), do: cancel_timer(state)

  defp do_flush(state) do
    state = cancel_timer(state)

    dropped =
      try do
        # Blobs first: a snapshot's section_hashes must never point at content
        # that is not there yet. On conflict this touches last_referenced_at
        # rather than doing nothing — that timestamp is what keeps retention
        # from collecting content an old snapshot still points at.
        insert_batch(Blob, Map.values(state.blobs),
          on_conflict: {:replace, [:last_referenced_at]},
          conflict_target: :hash
        )

        insert_batch(Snapshot, Enum.reverse(state.snapshots), [])
        insert_batch(Event, Enum.reverse(state.events), [])
        0
      rescue
        e ->
          Logger.warning(
            "lobby_snapshots: flush failed, dropping #{state.rows} rows: #{inspect(e)}"
          )

          state.rows
      end

    %{state | snapshots: [], events: [], blobs: %{}, rows: 0, dropped: state.dropped + dropped}
  end

  defp insert_batch(_schema, [], _opts), do: :ok

  defp insert_batch(schema, rows, opts) do
    # Chunked to stay under Postgres' 65535 bound parameter limit.
    rows
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(schema, &1, opts))
  end

  defp blob_row(hash, content, now) do
    %{
      hash: hash,
      # Wrapped because sections are not all maps — `members` and `kv_lobby` are
      # lists, and a jsonb-backed :map column rejects those. Unwrapped by
      # LobbySnapshots.load_blobs/1 so the rest of the system sees each section
      # in its natural shape.
      content: %{"v" => content},
      byte_size: :erlang.external_size(content),
      last_referenced_at: now,
      inserted_at: now
    }
  end
end
