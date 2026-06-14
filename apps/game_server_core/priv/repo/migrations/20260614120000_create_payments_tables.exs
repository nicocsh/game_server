defmodule GameServer.Repo.Migrations.CreatePaymentsTables do
  use Ecto.Migration

  def change do
    create table(:store_products) do
      add :sku, :string, null: false
      add :title, :string, null: false
      add :description, :string, null: false, default: ""
      add :kind, :string, null: false, default: "entitlement"
      add :active, :boolean, null: false, default: true
      add :grant_config, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:store_products, [:sku])
    create index(:store_products, [:active])
    create index(:store_products, [:kind])

    create table(:provider_products) do
      add :product_id, references(:store_products, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_id, :string, null: false
      add :currency, :string
      add :unit_amount, :integer
      add :active, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:provider_products, [:product_id])
    create index(:provider_products, [:provider])
    create index(:provider_products, [:active])
    create unique_index(:provider_products, [:provider, :external_id])

    create table(:purchases) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :product_id, references(:store_products, on_delete: :nilify_all)
      add :provider_product_id, references(:provider_products, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :order_id, :string, null: false
      add :provider_transaction_id, :string
      add :provider_original_transaction_id, :string
      add :status, :string, null: false, default: "pending"
      add :quantity, :integer, null: false, default: 1
      add :currency, :string
      add :amount, :integer
      add :environment, :string, null: false, default: "production"
      add :raw_provider_payload, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :purchased_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:purchases, [:user_id])
    create index(:purchases, [:product_id])
    create index(:purchases, [:provider_product_id])
    create index(:purchases, [:provider, :status])
    create index(:purchases, [:provider, :provider_original_transaction_id])
    create unique_index(:purchases, [:order_id])

    create unique_index(:purchases, [:provider, :provider_transaction_id],
             where: "provider_transaction_id IS NOT NULL",
             name: :purchases_unique_provider_transaction
           )

    create table(:entitlements) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :product_id, references(:store_products, on_delete: :nilify_all)
      add :source_purchase_id, references(:purchases, on_delete: :nilify_all)
      add :key, :string, null: false
      add :status, :string, null: false, default: "active"
      add :starts_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:entitlements, [:user_id])
    create index(:entitlements, [:product_id])
    create index(:entitlements, [:source_purchase_id])
    create index(:entitlements, [:status])
    create unique_index(:entitlements, [:user_id, :key])

    create table(:provider_events) do
      add :provider, :string, null: false
      add :event_id, :string, null: false
      add :event_type, :string, null: false
      add :processed_at, :utc_datetime
      add :payload, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:provider_events, [:provider])
    create index(:provider_events, [:event_type])
    create unique_index(:provider_events, [:provider, :event_id])

    create table(:reconciliation_cursors) do
      add :provider, :string, null: false
      add :name, :string, null: false
      add :cursor, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:reconciliation_cursors, [:provider, :name])
  end
end
