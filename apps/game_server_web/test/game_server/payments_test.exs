defmodule GameServer.PaymentsTest do
  use GameServer.DataCase

  alias GameServer.AccountsFixtures
  alias GameServer.Payments
  alias GameServer.Payments.Entitlement
  alias GameServer.Payments.ProviderEvent
  alias GameServer.Payments.Purchase
  alias GameServer.Payments.WalletLedgerEntry

  defmodule StoreAdapter do
    def validate_purchase(_user, attrs) do
      attrs = normalize(attrs)

      {:ok,
       %{
         "product_id" => attrs["product_id"],
         "transaction_id" => attrs["transaction_id"],
         "original_transaction_id" => attrs["original_transaction_id"],
         "status" => attrs["status"] || "completed",
         "quantity" => attrs["quantity"] || 1,
         "currency" => attrs["currency"],
         "amount" => attrs["amount"],
         "environment" => attrs["environment"] || "test",
         "raw_payload" => attrs
       }}
    end

    defp normalize(attrs) do
      Map.new(attrs, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)
    end
  end

  setup do
    original_adapters = Application.get_env(:game_server_core, :payment_provider_adapters)
    original_hooks = Application.get_env(:game_server_core, :hooks_module)

    Application.put_env(:game_server_core, :payment_provider_adapters,
      apple: StoreAdapter,
      google: StoreAdapter,
      steam: StoreAdapter
    )

    Application.put_env(:game_server_core, :hooks_module, GameServer.Hooks.Default)

    on_exit(fn ->
      restore_env(:payment_provider_adapters, original_adapters)
      restore_env(:hooks_module, original_hooks)
    end)

    :ok
  end

  describe "fulfillment" do
    test "currency purchases grant wallet balance once" do
      user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_currency_provider_product("stripe", "price_coins")

      assert {:ok, %Purchase{} = purchase} =
               Payments.create_purchase(user, provider_product, %{
                 "provider_transaction_id" => "cs_test_currency"
               })

      assert {:ok, %Purchase{status: "completed"} = completed} =
               Payments.fulfill_purchase(purchase, %{"provider" => "stripe"})

      assert Payments.wallet_balance(user.id, "coins") == 100

      assert {:ok, %Purchase{status: "completed"}} = Payments.fulfill_purchase(completed)
      assert Payments.wallet_balance(user.id, "coins") == 100

      assert Repo.aggregate(WalletLedgerEntry, :count, :id) == 1
    end

    test "entitlement purchases create one active entitlement and revoke cleanly" do
      user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_entitlement_provider_product("google", "battle_pass")

      {:ok, purchase} =
        Payments.create_purchase(user, provider_product, %{
          "provider_transaction_id" => "google_tx_entitlement"
        })

      assert {:ok, completed} = Payments.fulfill_purchase(purchase)
      assert Payments.has_entitlement?(user.id, "battle_pass") == true

      assert {:ok, _completed_again} = Payments.fulfill_purchase(completed)
      assert Repo.aggregate(Entitlement, :count, :id) == 1

      assert {:ok, revoked} = Payments.revoke_purchase(completed, %{"reason" => "refund"})
      assert revoked.status == "revoked"
      assert Payments.has_entitlement?(user.id, "battle_pass") == false
    end
  end

  describe "provider events" do
    test "provider events are deduped by provider and event id" do
      assert {:ok, %ProviderEvent{} = event, true} =
               Payments.record_provider_event(
                 "stripe",
                 "evt_1",
                 "checkout.session.completed",
                 %{}
               )

      assert {:ok, %ProviderEvent{} = duplicate, false} =
               Payments.record_provider_event(
                 "stripe",
                 "evt_1",
                 "checkout.session.completed",
                 %{}
               )

      assert duplicate.id == event.id
      assert Repo.aggregate(ProviderEvent, :count, :id) == 1
    end
  end

  describe "store validation" do
    test "validated receipts create fulfilled purchases and reject replay across users" do
      user = AccountsFixtures.user_fixture()
      other_user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_currency_provider_product("apple", "coins_pack")

      attrs = %{
        "product_id" => provider_product.external_id,
        "transaction_id" => "apple_tx_1",
        "currency" => "USD",
        "amount" => 199,
        "environment" => "test"
      }

      assert {:ok, %{purchase: %Purchase{} = purchase, seen_before: false}} =
               Payments.validate_store_purchase(user, "apple", attrs)

      assert purchase.status == "completed"
      assert purchase.provider_transaction_id == "apple_tx_1"
      assert Payments.wallet_balance(user.id, "coins") == 100

      assert {:ok, %{purchase: same_purchase, seen_before: true}} =
               Payments.validate_store_purchase(user, "apple", attrs)

      assert same_purchase.id == purchase.id
      assert Payments.wallet_balance(user.id, "coins") == 100

      assert {:error, :receipt_already_used} =
               Payments.validate_store_purchase(other_user, "apple", attrs)
    end
  end

  defp create_currency_provider_product(provider, external_id) do
    sku = unique_sku("coins")

    {:ok, product} =
      Payments.create_product(%{
        "sku" => sku,
        "title" => "100 Coins",
        "kind" => "currency",
        "grant_config" => %{"currency_key" => "coins", "amount" => 100}
      })

    {:ok, provider_product} =
      Payments.create_provider_product(%{
        "product_id" => product.id,
        "provider" => provider,
        "external_id" =>
          external_id <> "_" <> Integer.to_string(System.unique_integer([:positive])),
        "currency" => "USD",
        "unit_amount" => 199
      })

    {product, provider_product}
  end

  defp create_entitlement_provider_product(provider, external_id) do
    sku = unique_sku("battle_pass")

    {:ok, product} =
      Payments.create_product(%{
        "sku" => sku,
        "title" => "Battle Pass",
        "kind" => "entitlement",
        "grant_config" => %{"entitlement_key" => "battle_pass"}
      })

    {:ok, provider_product} =
      Payments.create_provider_product(%{
        "product_id" => product.id,
        "provider" => provider,
        "external_id" =>
          external_id <> "_" <> Integer.to_string(System.unique_integer([:positive])),
        "currency" => "USD",
        "unit_amount" => 999
      })

    {product, provider_product}
  end

  defp unique_sku(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp restore_env(key, nil), do: Application.delete_env(:game_server_core, key)
  defp restore_env(key, value), do: Application.put_env(:game_server_core, key, value)
end
