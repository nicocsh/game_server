defmodule GameServer.Repo.Migrations.RemovePaymentWalletLedger do
  use Ecto.Migration

  def up do
    execute("UPDATE store_products SET kind = 'consumable' WHERE kind = 'currency'")
    drop_if_exists table(:wallet_ledger_entries)
  end

  def down do
    create table(:wallet_ledger_entries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :purchase_id, references(:purchases, on_delete: :nilify_all)
      add :currency_key, :string, null: false
      add :delta, :integer, null: false
      add :reason, :string, null: false, default: "purchase"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:wallet_ledger_entries, [:user_id, :currency_key])
    create index(:wallet_ledger_entries, [:purchase_id])

    create unique_index(:wallet_ledger_entries, [:purchase_id, :currency_key],
             where: "purchase_id IS NOT NULL",
             name: :wallet_ledger_unique_purchase_currency
           )
  end
end
