defmodule GameServer.Repo.Migrations.CreateLobbySnapshots do
  use Ecto.Migration

  def change do
    # Section content, keyed by hash. Shared across sections, snapshots and
    # lobbies: identical content stores one row.
    #
    # inserted_at here is when this content was FIRST seen, not when any given
    # snapshot captured it — dedup means a blob can predate the run referencing
    # it. Use the snapshot's own inserted_at for "when did this state exist".
    #
    # last_referenced_at is bumped by the writer's upsert every time a snapshot
    # references this content, and that is what makes GC both safe and portable.
    # Deleting by age alone would be WRONG — dedup means a day-1 blob can be
    # referenced by a day-29 snapshot — while scanning section_hashes for live
    # references needs adapter-specific JSON SQL and does not scale. Touching on
    # write reduces GC to an indexed range delete that Postgres and SQLite both
    # handle.
    create table(:lobby_snapshot_blobs, primary_key: false) do
      add :hash, :string, primary_key: true
      add :content, :map, null: false
      add :byte_size, :integer, null: false
      add :last_referenced_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:lobby_snapshot_blobs, [:last_referenced_at])

    # lobby_id is deliberately NOT a foreign key: lobbies are hard-deleted when
    # the last member leaves (lobbies.ex:1083), so a cascade would destroy the
    # record at exactly the moment the run ends, and nilify would sever the
    # correlation key. The column outliving its lobby is the intended state for
    # every completed run.
    #
    # Ordering is (inserted_at, id) rather than a stored sequence number. id is
    # UUIDv7, so it is itself time-ordered and breaks ties without a counter —
    # which means no writer has to be a cluster-wide singleton to hand out
    # sequence numbers. Display indices are derived at read time.
    create table(:lobby_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lobby_id, :binary_id, null: false
      add :trigger, :string, null: false
      add :section_hashes, :map, null: false, default: "{}"
      add :flagged, :boolean, null: false, default: false
      # Attribution only — the snapshot outlives the user, so deletion drops the
      # attribution rather than the record.
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:lobby_snapshots, [:lobby_id, :inserted_at])
    create index(:lobby_snapshots, [:inserted_at])
    create index(:lobby_snapshots, [:flagged, :inserted_at])

    # No snapshot_seq: an event belongs to the interval opened by the latest
    # snapshot at or before its inserted_at, which is a read-time lookup. Storing
    # it would freeze an answer derived from writer arrival order rather than
    # from when the event actually happened.
    create table(:lobby_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lobby_id, :binary_id, null: false
      add :kind, :string, null: false
      # Free-form structured fields explaining one decision, e.g.
      # %{from: 100, to: 50, gap: 78.39}. Not a list, though it may contain them.
      add :payload, :map, null: false, default: "{}"
      # Unlike snapshots, a user-attributed event carries that user's decisions,
      # so account deletion removes it. Lobby-scoped events (user_id nil) are
      # unaffected and expire with the retention window.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:lobby_events, [:lobby_id, :inserted_at])
    create index(:lobby_events, [:inserted_at])
  end
end
