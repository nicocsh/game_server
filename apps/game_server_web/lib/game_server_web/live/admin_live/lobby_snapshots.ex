defmodule GameServerWeb.AdminLive.LobbySnapshots do
  @moduledoc """
  Browse the durable per-run record of lobby state.

  Complements `AdminLive.Logs` rather than replacing it: logs are a live tail of
  an in-memory ring buffer, this is history you can still read tomorrow.

  Diffs are computed only for the snapshot the reader expanded. Reconstructing
  state walks every snapshot up to that point, so diffing the whole timeline
  eagerly would be quadratic in a run's length for a view where one row is
  usually the interesting one.
  """
  use GameServerWeb, :live_view

  alias GameServer.LobbySnapshots

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="space-y-4">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/admin"} class="btn btn-outline btn-sm">&larr; Admin</.link>
            <h1 class="text-xl font-bold">Lobby snapshots</h1>
          </div>

          <div class="flex items-center gap-2 text-xs text-base-content/60">
            <span :if={not @enabled} class="badge badge-warning badge-sm">capture disabled</span>
            <span>Buffered: {@writer.buffered}</span>
            <span :if={@writer.dropped > 0} class="text-error font-semibold">
              &middot; {@writer.dropped} dropped
            </span>
            <span :if={@writer.nodes > 1}>&middot; {@writer.nodes} nodes</span>
            <span :if={@writer.unreachable > 0} class="text-warning">
              &middot; {@writer.unreachable} unreachable
            </span>
          </div>
        </div>

        <%!-- Coverage gaps: mutations that bypassed a capture chokepoint, so the
              snapshots around them are known to be incomplete. --%>
        <div :if={@gaps != []} class="alert alert-warning items-start text-sm">
          <div class="space-y-2 w-full">
            <div class="font-semibold">
              {length(@gaps)} coverage gap{if length(@gaps) == 1, do: "", else: "s"}
            </div>
            <div class="text-xs opacity-80">
              State was written outside a capture chokepoint, so snapshots around these
              are missing a mutation.
            </div>
            <div :for={gap <- Enum.take(@gaps, 5)} class="flex items-baseline gap-2 text-xs">
              <span class="font-mono">{gap.kind}</span>
              <.link
                patch={~p"/admin/lobby-snapshots?lobby_id=#{gap.lobby_id}"}
                class="link font-mono truncate"
              >
                {gap.lobby_id}
              </.link>
              <span class="opacity-60">{format_time(gap.inserted_at)}</span>
            </div>
          </div>
        </div>

        <div :if={not @enabled} class="alert alert-warning text-sm">
          <span>
            Capture is off. Set <code class="font-mono">LOBBY_SNAPSHOTS_ENABLED=true</code>
            to record runs. Existing records stay readable either way.
          </span>
        </div>

        <%!-- Lobby list --%>
        <div :if={is_nil(@lobby_id)} class="space-y-3">
          <div class="flex items-center gap-2">
            <button
              phx-click="toggle_flagged"
              class={[
                "badge badge-sm cursor-pointer",
                (@flagged_only && "badge-error") || "badge-ghost"
              ]}
            >
              flagged only
            </button>
            <span class="text-xs text-base-content/60">{length(@lobbies)} runs</span>
          </div>

          <div :if={@lobbies == []} class="text-sm text-base-content/60 py-8 text-center">
            No runs recorded yet.
          </div>

          <div class="overflow-x-auto">
            <table :if={@lobbies != []} class="table table-sm">
              <thead>
                <tr>
                  <th>Lobby</th>
                  <th>Snapshots</th>
                  <th>Started</th>
                  <th>Ended</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={run <- @lobbies} class="hover">
                  <td class="font-mono text-xs">
                    {run.lobby_id}
                    <span :if={run.flagged} class="badge badge-error badge-xs ml-1">flagged</span>
                  </td>
                  <td>{run.snapshots}</td>
                  <td class="text-xs">{format_time(run.started_at)}</td>
                  <td class="text-xs">{format_time(run.ended_at)}</td>
                  <td>
                    <.link
                      patch={~p"/admin/lobby-snapshots?lobby_id=#{run.lobby_id}"}
                      class="link link-primary text-xs"
                    >
                      Timeline →
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Timeline for one lobby --%>
        <div :if={@lobby_id} class="space-y-3">
          <div class="flex items-center gap-3">
            <.link patch={~p"/admin/lobby-snapshots"} class="btn btn-ghost btn-xs">
              &larr; All runs
            </.link>
            <span class="font-mono text-sm">{@lobby_id}</span>
          </div>

          <div :if={@timeline.prologue != []} class="pl-4 border-l-2 border-base-300 space-y-1">
            <div class="text-xs text-base-content/50">before first snapshot</div>
            <.event :for={event <- @timeline.prologue} event={event} />
          </div>

          <div :for={interval <- @timeline.intervals} class="space-y-1">
            <div class="card bg-base-100 p-3">
              <button
                phx-click="toggle_snapshot"
                phx-value-id={interval.snapshot.id}
                class="flex items-center justify-between w-full text-left"
              >
                <div class="flex items-center gap-2">
                  <span class="badge badge-neutral badge-sm">#{interval.index}</span>
                  <span class="font-mono text-sm">{interval.snapshot.trigger}</span>
                  <span :if={interval.snapshot.flagged} class="badge badge-error badge-xs">
                    flagged
                  </span>
                </div>
                <span class="text-xs text-base-content/50">
                  {format_time(interval.snapshot.inserted_at)}
                </span>
              </button>

              <div :if={@expanded == interval.snapshot.id} class="mt-3 space-y-3">
                <div :if={@diff == %{} and interval.index == 1} class="text-xs text-base-content/60">
                  First snapshot of the run — nothing to compare against. Full state below.
                </div>
                <div :if={@diff == %{} and interval.index > 1} class="text-xs text-base-content/60">
                  No changes from the previous snapshot.
                </div>

                <div :for={{section, changes} <- @diff} class="space-y-1">
                  <div class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                    {section}
                  </div>
                  <div class="overflow-x-auto">
                    <table class="table table-xs">
                      <tbody>
                        <tr :for={change <- changes}>
                          <td class="font-mono text-xs whitespace-nowrap">
                            {Enum.join(change.path, ".")}
                          </td>
                          <td class="font-mono text-xs text-error">{preview(change.from)}</td>
                          <td class="font-mono text-xs text-success">{preview(change.to)}</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </div>

                <details class="text-xs">
                  <summary class="cursor-pointer text-base-content/60">Raw sections</summary>
                  <pre class="mt-2 p-2 bg-base-200 rounded overflow-x-auto text-xs">{@raw}</pre>
                </details>
              </div>
            </div>

            <div :if={interval.events != []} class="pl-4 border-l-2 border-base-300 space-y-1">
              <.event :for={event <- interval.events} event={event} />
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :event, :map, required: true

  defp event(assigns) do
    assigns = assign(assigns, :gap?, LobbySnapshots.coverage_gap?(assigns.event))

    ~H"""
    <div class="flex items-baseline gap-2 text-xs">
      <span class={["font-mono", (@gap? && "text-warning font-semibold") || "text-primary"]}>
        {@event.kind}
      </span>
      <span class="font-mono text-base-content/60 truncate">{preview(@event.payload)}</span>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Lobby snapshots")
     |> assign(:flagged_only, false)
     |> assign(:enabled, LobbySnapshots.enabled?())
     |> assign(:gaps, LobbySnapshots.list_coverage_gaps(limit: 25))
     # Cluster-wide: each node buffers independently, so a local read would
     # under-report exactly the dropped rows this is here to expose.
     |> assign(:writer, LobbySnapshots.Writer.cluster_stats())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    lobby_id = params["lobby_id"]

    socket =
      socket
      |> assign(:lobby_id, lobby_id)
      |> assign(:expanded, nil)
      |> assign(:diff, %{})
      |> assign(:raw, "")

    {:noreply, if(lobby_id, do: load_timeline(socket), else: load_lobbies(socket))}
  end

  @impl true
  def handle_event("toggle_flagged", _params, socket) do
    {:noreply,
     socket
     |> assign(:flagged_only, not socket.assigns.flagged_only)
     |> load_lobbies()}
  end

  # Collapsing only needs to drop the assigns; expanding is what costs a read.
  def handle_event("toggle_snapshot", %{"id" => id}, socket)
      when id == socket.assigns.expanded do
    {:noreply, assign(socket, expanded: nil, diff: %{}, raw: "")}
  end

  def handle_event("toggle_snapshot", %{"id" => id}, socket) do
    snapshots = Enum.map(socket.assigns.timeline.intervals, & &1.snapshot)

    case Enum.find_index(snapshots, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      index ->
        snapshot = Enum.at(snapshots, index)
        state = LobbySnapshots.state_at(snapshot)

        # The first snapshot has nothing to diff against; the raw view below is
        # the whole answer for it.
        diff =
          if index == 0,
            do: %{},
            else: LobbySnapshots.diff(Enum.at(snapshots, index - 1), snapshot)

        {:noreply,
         assign(socket, expanded: id, diff: diff, raw: Jason.encode!(state, pretty: true))}
    end
  end

  defp load_lobbies(socket) do
    assign(
      socket,
      :lobbies,
      LobbySnapshots.list_lobbies(flagged_only: socket.assigns.flagged_only)
    )
  end

  defp load_timeline(socket) do
    assign(socket, :timeline, LobbySnapshots.timeline(socket.assigns.lobby_id))
  end

  # Shown in full rather than truncated: ids are UUIDv7, so the leading hex is a
  # millisecond timestamp and every lobby from the same ~65s window shares it.
  # The full id is also what correlates a run with the client's own records.

  defp format_time(nil), do: "—"
  defp format_time(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

  defp preview(value) do
    value |> inspect(limit: 8, printable_limit: 120) |> String.slice(0, 160)
  end
end
