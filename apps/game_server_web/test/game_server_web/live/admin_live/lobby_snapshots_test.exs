defmodule GameServerWeb.AdminLive.LobbySnapshotsTest do
  # async: false — the writer is a named process shared across tests.
  use GameServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias GameServer.Accounts.User
  alias GameServer.AccountsFixtures
  alias GameServer.Lobbies
  alias GameServer.LobbySnapshots
  alias GameServer.LobbySnapshots.Writer
  alias GameServer.Repo

  setup %{conn: conn} do
    previous = Application.get_env(:game_server_core, LobbySnapshots, [])
    Application.put_env(:game_server_core, LobbySnapshots, enabled: true, user_kv_keys: [])
    on_exit(fn -> Application.put_env(:game_server_core, LobbySnapshots, previous) end)

    {:ok, _writer} = Writer.start_link([])

    admin = AccountsFixtures.user_fixture()
    {:ok, admin} = admin |> User.admin_changeset(%{"is_admin" => true}) |> Repo.update()

    {:ok, lobby} = Lobbies.create_lobby(%{title: "snapshot-room", host_id: admin.id})

    capture = fn trigger ->
      :ok = LobbySnapshots.capture_lobby(lobby.id, trigger, sync: true)
      :ok = Writer.flush()
    end

    capture.("test:first")

    {:ok, _} =
      Lobbies.update_lobby(Repo.get!(Lobbies.Lobby, lobby.id), %{title: "renamed-mid-run"})

    capture.("test:second")

    %{conn: log_in_user(conn, admin), lobby: lobby}
  end

  test "lists recorded runs", %{conn: conn, lobby: lobby} do
    {:ok, _live, html} = live(conn, ~p"/admin/lobby-snapshots")

    assert html =~ "Lobby snapshots"
    assert html =~ lobby.id
  end

  test "shows a run's timeline with its triggers and events", %{conn: conn, lobby: lobby} do
    :ok = LobbySnapshots.record_event(lobby.id, "boat.speed", %{from: 100, to: 50})
    :ok = Writer.flush()

    {:ok, _live, html} = live(conn, ~p"/admin/lobby-snapshots?lobby_id=#{lobby.id}")

    assert html =~ "test:first"
    assert html =~ "test:second"
    assert html =~ "boat.speed"
  end

  test "expanding a snapshot shows the field that changed", %{conn: conn, lobby: lobby} do
    {:ok, live, _html} = live(conn, ~p"/admin/lobby-snapshots?lobby_id=#{lobby.id}")

    [_first, second] = LobbySnapshots.list_snapshots(lobby.id)

    html =
      live
      |> element("button[phx-value-id='#{second.id}']")
      |> render_click()

    # The diff is the point of the page: the changed field, both values, and
    # the section it lives in.
    assert html =~ "title"
    assert html =~ "snapshot-room"
    assert html =~ "renamed-mid-run"
  end

  test "the first snapshot says there is nothing to compare against", %{
    conn: conn,
    lobby: lobby
  } do
    {:ok, live, _html} = live(conn, ~p"/admin/lobby-snapshots?lobby_id=#{lobby.id}")

    [first, _second] = LobbySnapshots.list_snapshots(lobby.id)

    html =
      live
      |> element("button[phx-value-id='#{first.id}']")
      |> render_click()

    assert html =~ "nothing to compare against"
  end

  test "coverage gaps are surfaced as a warning with a link to the run", %{
    conn: conn,
    lobby: lobby
  } do
    :ok =
      LobbySnapshots.record_coverage_gap(lobby.id, "unserialized_write", %{
        "section" => "boat_adventure"
      })

    :ok = Writer.flush()

    {:ok, _live, html} = live(conn, ~p"/admin/lobby-snapshots")

    assert html =~ "coverage gap"
    assert html =~ "coverage:unserialized_write"
    assert html =~ lobby.id
  end

  test "flagged filter narrows the list to anomalous runs", %{conn: conn, lobby: lobby} do
    other = AccountsFixtures.user_fixture()
    {:ok, flagged_lobby} = Lobbies.create_lobby(%{title: "bad-run", host_id: other.id})
    :ok = LobbySnapshots.capture_lobby(flagged_lobby.id, "hook:boom", sync: true, flagged: true)
    :ok = Writer.flush()

    {:ok, live, _html} = live(conn, ~p"/admin/lobby-snapshots")

    html = live |> element("button[phx-click='toggle_flagged']") |> render_click()

    assert html =~ flagged_lobby.id
    refute html =~ lobby.id
  end
end
