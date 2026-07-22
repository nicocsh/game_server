defmodule GameServer.Repo.Migrations.DropScheduleLocks do
  use Ecto.Migration

  # Distributed dedup of scheduled jobs now relies on Oban's job uniqueness
  # (see GameServer.Schedule); the schedule_locks table is no longer used.
  def up do
    drop_if_exists table(:schedule_locks)
  end

  def down do
    create table(:schedule_locks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_name, :string
      add :period_key, :string
      add :executed_at, :utc_datetime
    end

    create unique_index(:schedule_locks, [:job_name, :period_key])
  end
end
