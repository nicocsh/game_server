defmodule GameServer.Repo.Migrations.CreateIpBans do
  use Ecto.Migration

  def change do
    create table(:ip_bans) do
      add :ip, :string, null: false
      # nil means a permanent ban
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ip_bans, [:ip])
  end
end
