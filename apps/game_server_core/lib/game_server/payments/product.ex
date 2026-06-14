defmodule GameServer.Payments.Product do
  @moduledoc """
  Internal product sold by one or more payment providers.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(entitlement consumable currency subscription)

  @derive {Jason.Encoder,
           only: [
             :id,
             :sku,
             :title,
             :description,
             :kind,
             :active,
             :grant_config,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "store_products" do
    field :sku, :string
    field :title, :string
    field :description, :string, default: ""
    field :kind, :string, default: "entitlement"
    field :active, :boolean, default: true
    field :grant_config, :map, default: %{}
    field :metadata, :map, default: %{}

    has_many :provider_products, GameServer.Payments.ProviderProduct
    has_many :purchases, GameServer.Payments.Purchase

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(sku title kind)a
  @optional_fields ~w(description active grant_config metadata)a

  def changeset(product, attrs) do
    product
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:sku, min: 1, max: 120)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_inclusion(:kind, @kinds)
    |> validate_grant_config()
    |> unique_constraint(:sku)
  end

  def kinds, do: @kinds

  defp validate_grant_config(changeset) do
    kind = get_field(changeset, :kind)
    config = get_field(changeset, :grant_config) || %{}

    cond do
      not is_map(config) ->
        add_error(changeset, :grant_config, "must be a map")

      kind == "currency" and not positive_integer?(config["amount"] || config[:amount]) ->
        add_error(changeset, :grant_config, "currency products require a positive amount")

      true ->
        changeset
    end
  end

  defp positive_integer?(value) when is_integer(value) and value > 0, do: true

  defp positive_integer?(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int > 0
      _ -> false
    end
  end

  defp positive_integer?(_value), do: false
end
