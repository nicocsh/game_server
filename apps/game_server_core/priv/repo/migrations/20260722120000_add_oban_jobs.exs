defmodule GameServer.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  # Oban picks the DDL for the Repo's adapter automatically (Postgres or
  # SQLite/Lite), so this migration works on both.
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down(version: 1)
end
