defmodule GameServer.Payments.WalletLedgerEntry do
  @moduledoc """
  Append-only virtual currency delta.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @derive {Jason.Encoder,
           only: [
             :id,
             :user_id,
             :purchase_id,
             :currency_key,
             :delta,
             :reason,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "wallet_ledger_entries" do
    belongs_to :user, GameServer.Accounts.User
    belongs_to :purchase, GameServer.Payments.Purchase
    field :currency_key, :string
    field :delta, :integer
    field :reason, :string, default: "purchase"
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(user_id currency_key delta reason)a
  @optional_fields ~w(purchase_id metadata)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:currency_key, min: 1, max: 120)
    |> validate_length(:reason, min: 1, max: 120)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:purchase_id)
    |> unique_constraint(:purchase_id, name: :wallet_ledger_unique_purchase_currency)
  end
end
