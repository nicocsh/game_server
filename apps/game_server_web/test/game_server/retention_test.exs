defmodule GameServer.RetentionTest do
  use GameServer.DataCase, async: false

  alias GameServer.AccountsFixtures
  alias GameServer.Repo
  alias GameServer.Retention

  defp backdate(schema, id, days) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -days, :day)

    Repo.update_all(
      from(r in schema, where: r.id == ^id),
      set: [inserted_at: cutoff]
    )
  end

  setup do
    original = Application.get_env(:game_server_core, GameServer.Retention, [])

    on_exit(fn ->
      Application.put_env(:game_server_core, GameServer.Retention, original)
    end)

    :ok
  end

  test "prunes chat messages older than the configured retention" do
    Application.put_env(:game_server_core, GameServer.Retention, chat_messages_days: 30)

    a = AccountsFixtures.user_fixture()

    old =
      Repo.insert!(%GameServer.Chat.Message{
        sender_id: a.id,
        content: "old",
        chat_type: "lobby",
        chat_ref_id: Ecto.UUID.generate()
      })

    fresh =
      Repo.insert!(%GameServer.Chat.Message{
        sender_id: a.id,
        content: "fresh",
        chat_type: "lobby",
        chat_ref_id: Ecto.UUID.generate()
      })

    backdate(GameServer.Chat.Message, old.id, 31)

    results = Retention.prune_all()

    assert results.chat_messages == 1
    refute Repo.get(GameServer.Chat.Message, old.id)
    assert Repo.get(GameServer.Chat.Message, fresh.id)
  end

  test "retention of 0 keeps everything" do
    Application.put_env(:game_server_core, GameServer.Retention, chat_messages_days: 0)

    a = AccountsFixtures.user_fixture()

    old =
      Repo.insert!(%GameServer.Chat.Message{
        sender_id: a.id,
        content: "old",
        chat_type: "lobby",
        chat_ref_id: Ecto.UUID.generate()
      })

    backdate(GameServer.Chat.Message, old.id, 400)

    results = Retention.prune_all()

    assert results.chat_messages == 0
    assert Repo.get(GameServer.Chat.Message, old.id)
  end

  test "prunes expired ip bans but keeps permanent and future ones" do
    now = DateTime.utc_now(:second)

    expired =
      Repo.insert!(%GameServer.IpBans.IpBan{ip: "10.0.0.1", expires_at: DateTime.add(now, -60)})

    future =
      Repo.insert!(%GameServer.IpBans.IpBan{ip: "10.0.0.2", expires_at: DateTime.add(now, 3600)})

    permanent = Repo.insert!(%GameServer.IpBans.IpBan{ip: "10.0.0.3", expires_at: nil})

    results = Retention.prune_all()

    assert results.expired_ip_bans == 1
    refute Repo.get(GameServer.IpBans.IpBan, expired.id)
    assert Repo.get(GameServer.IpBans.IpBan, future.id)
    assert Repo.get(GameServer.IpBans.IpBan, permanent.id)
  end

  describe "lobby snapshots" do
    alias GameServer.LobbySnapshots.{Blob, Event, Snapshot}

    defp snapshot!(lobby_id, opts \\ []) do
      snapshot =
        Repo.insert!(%Snapshot{
          lobby_id: lobby_id,
          trigger: Keyword.get(opts, :trigger, "test"),
          flagged: Keyword.get(opts, :flagged, false),
          section_hashes: Keyword.get(opts, :section_hashes, %{}),
          inserted_at: DateTime.utc_now()
        })

      if days = opts[:days_old], do: backdate(Snapshot, snapshot.id, days)
      snapshot
    end

    defp event!(lobby_id, opts \\ []) do
      event =
        Repo.insert!(%Event{
          lobby_id: lobby_id,
          kind: "test.event",
          payload: %{},
          inserted_at: DateTime.utc_now()
        })

      if days = opts[:days_old], do: backdate(Event, event.id, days)
      event
    end

    defp blob!(hash, days_referenced_ago) do
      at = DateTime.add(DateTime.utc_now(), -days_referenced_ago, :day)

      Repo.insert!(%Blob{
        hash: hash,
        content: %{"v" => %{}},
        byte_size: 2,
        last_referenced_at: at,
        inserted_at: at
      })
    end

    setup do
      Application.put_env(:game_server_core, GameServer.Retention,
        lobby_snapshots_days: 30,
        lobby_snapshots_flagged_days: 90
      )

      :ok
    end

    test "prunes snapshots and events past the window, keeping recent ones" do
      lobby = Ecto.UUID.generate()

      old_snapshot = snapshot!(lobby, days_old: 40)
      old_event = event!(lobby, days_old: 40)
      fresh_snapshot = snapshot!(lobby)
      fresh_event = event!(lobby)

      Retention.prune_all()

      refute Repo.get(Snapshot, old_snapshot.id)
      refute Repo.get(Event, old_event.id)
      assert Repo.get(Snapshot, fresh_snapshot.id)
      assert Repo.get(Event, fresh_event.id)
    end

    test "a flagged run keeps its whole timeline, unflagged snapshots included" do
      flagged_lobby = Ecto.UUID.generate()
      plain_lobby = Ecto.UUID.generate()

      # Flagged is a property of the run, not the row: the unflagged snapshot
      # below is part of the same run and must survive with it.
      flagged = snapshot!(flagged_lobby, days_old: 40, flagged: true)
      alongside = snapshot!(flagged_lobby, days_old: 40)
      flagged_event = event!(flagged_lobby, days_old: 40)

      plain = snapshot!(plain_lobby, days_old: 40)
      plain_event = event!(plain_lobby, days_old: 40)

      Retention.prune_all()

      assert Repo.get(Snapshot, flagged.id)
      assert Repo.get(Snapshot, alongside.id)
      assert Repo.get(Event, flagged_event.id)
      refute Repo.get(Snapshot, plain.id)
      refute Repo.get(Event, plain_event.id)
    end

    test "flagged runs expire once past the longer window" do
      lobby = Ecto.UUID.generate()

      ancient = snapshot!(lobby, days_old: 100, flagged: true)
      ancient_event = event!(lobby, days_old: 100)

      Retention.prune_all()

      refute Repo.get(Snapshot, ancient.id)
      refute Repo.get(Event, ancient_event.id)
    end

    test "keeps a blob an old snapshot still references" do
      # The dedup hazard: this blob's content was first stored long ago, but a
      # recent snapshot reuses it. Pruning on age alone would delete live
      # content — last_referenced_at is what prevents that.
      reused = blob!("reused", 0)
      stale = blob!("stale", 100)

      _recent = snapshot!(Ecto.UUID.generate(), section_hashes: %{"lobby" => "reused"})

      Retention.prune_all()

      assert Repo.get(Blob, reused.hash)
      refute Repo.get(Blob, stale.hash)
    end

    test "keeps everything when the window is disabled" do
      Application.put_env(:game_server_core, GameServer.Retention, lobby_snapshots_days: 0)

      lobby = Ecto.UUID.generate()
      ancient = snapshot!(lobby, days_old: 500)
      ancient_blob = blob!("ancient", 500)

      Retention.prune_all()

      assert Repo.get(Snapshot, ancient.id)
      assert Repo.get(Blob, ancient_blob.hash)
    end

    test "a flagged window shorter than the normal one does not expire flagged runs first" do
      Application.put_env(:game_server_core, GameServer.Retention,
        lobby_snapshots_days: 30,
        lobby_snapshots_flagged_days: 1
      )

      lobby = Ecto.UUID.generate()
      flagged = snapshot!(lobby, days_old: 10, flagged: true)

      Retention.prune_all()

      assert Repo.get(Snapshot, flagged.id)
    end
  end
end
