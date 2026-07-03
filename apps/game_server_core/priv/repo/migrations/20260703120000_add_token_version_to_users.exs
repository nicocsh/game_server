defmodule GameServer.Repo.Migrations.AddTokenVersionToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :token_version, :integer, default: 0, null: false
    end
  end
end
