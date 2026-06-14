defmodule GameServerWeb.Api.V1.PaymentControllerTest do
  use GameServerWeb.ConnCase

  alias GameServer.AccountsFixtures
  alias GameServer.Payments
  alias GameServerWeb.Auth.Guardian

  defmodule StripeAdapter do
    def create_checkout_session(purchase, _provider_product, _attrs) do
      {:ok,
       %{
         "id" => "cs_test_#{purchase.id}",
         "url" => "https://checkout.test/session/#{purchase.id}"
       }}
    end

    def verify_webhook(raw_body, _signature), do: Jason.decode(raw_body)
  end

  defmodule StoreAdapter do
    def validate_purchase(_user, attrs) do
      attrs = normalize(attrs)

      {:ok,
       %{
         "product_id" => attrs["product_id"],
         "transaction_id" => attrs["transaction_id"],
         "status" => attrs["status"] || "completed",
         "environment" => "test",
         "raw_payload" => attrs
       }}
    end

    def verify_webhook(raw_body, _authorization), do: Jason.decode(raw_body)
    def verify_notification(raw_body), do: Jason.decode(raw_body)

    def init_transaction(purchase, _provider_product, _attrs) do
      {:ok,
       %{
         "response" => %{
           "result" => "OK",
           "params" => %{
             "orderid" => purchase.order_id,
             "transid" => "steam_tx_#{purchase.id}",
             "steamurl" => "https://steam.test/checkout/#{purchase.order_id}"
           }
         }
       }}
    end

    def finalize_transaction(purchase, _attrs) do
      {:ok,
       %{
         "product_id" => purchase.provider_product.external_id,
         "transaction_id" => purchase.provider_transaction_id || "steam_tx_#{purchase.id}",
         "original_transaction_id" => purchase.order_id,
         "status" => "completed",
         "environment" => "test",
         "raw_payload" => %{"steam_finalize" => %{"ok" => true}}
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
    original_stripe = Application.get_env(:game_server_core, :stripe_adapter)
    original_adapters = Application.get_env(:game_server_core, :payment_provider_adapters)
    original_hooks = Application.get_env(:game_server_core, :hooks_module)

    Application.put_env(:game_server_core, :stripe_adapter, StripeAdapter)

    Application.put_env(:game_server_core, :payment_provider_adapters,
      apple: StoreAdapter,
      google: StoreAdapter,
      steam: StoreAdapter
    )

    Application.put_env(:game_server_core, :hooks_module, GameServer.Hooks.Default)

    on_exit(fn ->
      restore_env(:stripe_adapter, original_stripe)
      restore_env(:payment_provider_adapters, original_adapters)
      restore_env(:hooks_module, original_hooks)
    end)

    :ok
  end

  describe "GET /api/v1/payments/catalog" do
    test "lists active provider products", %{conn: conn} do
      {product, provider_product} = create_provider_product("stripe", "price_catalog")

      response =
        conn
        |> get("/api/v1/payments/catalog", %{provider: "stripe"})
        |> json_response(200)

      assert [
               %{
                 "provider" => "stripe",
                 "external_id" => external_id,
                 "product" => %{"sku" => sku}
               }
             ] = response["data"]

      assert external_id == provider_product.external_id
      assert sku == product.sku
    end
  end

  describe "GET /api/v1/payments/wallet" do
    test "requires auth and returns balances", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_provider_product("stripe", "price_wallet")
      {:ok, purchase} = Payments.create_purchase(user, provider_product)
      {:ok, _purchase} = Payments.fulfill_purchase(purchase)

      assert conn |> get("/api/v1/payments/wallet") |> response(401)

      response =
        conn
        |> auth_conn(user)
        |> get("/api/v1/payments/wallet")
        |> json_response(200)

      assert response["data"] == %{"coins" => 100}
    end
  end

  describe "POST /api/v1/payments/checkout/stripe" do
    test "creates a pending purchase and returns checkout session", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {product, _provider_product} = create_provider_product("stripe", "price_checkout")

      response =
        conn
        |> auth_conn(user)
        |> post("/api/v1/payments/checkout/stripe", %{
          "product_sku" => product.sku,
          "success_url" => "https://example.test/success",
          "cancel_url" => "https://example.test/cancel"
        })
        |> json_response(200)

      assert response["data"]["checkout_url"] =~ "https://checkout.test/session/"
      assert response["data"]["provider_session_id"] =~ "cs_test_"
      assert response["data"]["purchase"]["status"] == "requires_action"
    end
  end

  describe "POST /api/v1/payments/checkout/steam" do
    test "creates and finalizes a Steam MicroTxn purchase", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_provider_product("steam", "100")

      checkout =
        conn
        |> auth_conn(user)
        |> post("/api/v1/payments/checkout/steam", %{
          "provider_product_id" => provider_product.id,
          "steam_id" => "76561197972751825",
          "currency" => "USD"
        })
        |> json_response(200)

      assert checkout["data"]["steam_url"] =~ "https://steam.test/checkout/"
      assert checkout["data"]["purchase"]["status"] == "requires_action"

      order_id = checkout["data"]["purchase"]["order_id"]

      finalized =
        build_conn()
        |> auth_conn(user)
        |> post("/api/v1/payments/steam/finalize", %{"order_id" => order_id})
        |> json_response(200)

      assert finalized["data"]["purchase"]["status"] == "completed"
      assert Payments.wallet_balance(user.id, "coins") == 100
    end
  end

  describe "POST /api/v1/payments/webhooks/stripe" do
    test "fulfills checkout session and ignores duplicate event", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_provider_product("stripe", "price_webhook")

      {:ok, purchase} =
        Payments.create_purchase(user, provider_product, %{
          "status" => "requires_action",
          "provider_transaction_id" => "cs_paid"
        })

      body =
        Jason.encode!(%{
          "id" => "evt_checkout_paid",
          "type" => "checkout.session.completed",
          "data" => %{
            "object" => %{
              "id" => "cs_paid",
              "amount_total" => 199,
              "currency" => "usd",
              "metadata" => %{
                "purchase_id" => to_string(purchase.id),
                "order_id" => purchase.order_id
              }
            }
          }
        })

      response =
        conn
        |> json_webhook_conn()
        |> post("/api/v1/payments/webhooks/stripe", body)
        |> json_response(200)

      assert response == %{"ok" => true, "status" => "processed"}
      assert Payments.wallet_balance(user.id, "coins") == 100

      charge_body =
        Jason.encode!(%{
          "id" => "evt_charge_succeeded",
          "type" => "charge.succeeded",
          "data" => %{
            "object" => %{
              "id" => "ch_paid",
              "object" => "charge",
              "metadata" => %{"purchase_id" => to_string(purchase.id)}
            }
          }
        })

      charge_response =
        build_conn()
        |> json_webhook_conn()
        |> post("/api/v1/payments/webhooks/stripe", charge_body)
        |> json_response(200)

      assert charge_response == %{"ok" => true, "status" => "processed"}
      assert Payments.get_purchase(purchase.id).provider_original_transaction_id == "ch_paid"

      refund_body =
        Jason.encode!(%{
          "id" => "evt_refund_created",
          "type" => "refund.created",
          "data" => %{
            "object" => %{
              "id" => "re_paid",
              "object" => "refund",
              "charge" => "ch_paid"
            }
          }
        })

      refund_response =
        build_conn()
        |> json_webhook_conn()
        |> post("/api/v1/payments/webhooks/stripe", refund_body)
        |> json_response(200)

      assert refund_response == %{"ok" => true, "status" => "processed"}
      assert Payments.get_purchase(purchase.id).status == "refunded"
      assert Payments.wallet_balance(user.id, "coins") == 100

      duplicate_response =
        build_conn()
        |> json_webhook_conn()
        |> post("/api/v1/payments/webhooks/stripe", body)
        |> json_response(200)

      assert duplicate_response == %{"ok" => true, "status" => "duplicate"}
      assert Payments.wallet_balance(user.id, "coins") == 100
    end
  end

  describe "POST /api/v1/payments/webhooks/google" do
    test "revokes purchase from voided purchase notification", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_provider_product("google", "coins_google_webhook")

      {:ok, purchase} =
        Payments.create_purchase(user, provider_product, %{
          "provider_transaction_id" => "GPA.1",
          "provider_original_transaction_id" => "google_token_1"
        })

      {:ok, _purchase} = Payments.fulfill_purchase(purchase)

      body =
        Jason.encode!(%{
          "message_id" => "google_msg_1",
          "voidedPurchaseNotification" => %{
            "purchaseToken" => "google_token_1",
            "orderId" => "GPA.1",
            "productType" => 2,
            "refundType" => 1
          }
        })

      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/payments/webhooks/google", body)
        |> json_response(200)

      assert response == %{"ok" => true, "status" => "processed"}
      assert Payments.get_purchase(purchase.id).status == "refunded"
    end
  end

  describe "POST /api/v1/payments/webhooks/apple" do
    test "revokes purchase from App Store notification", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_provider_product("apple", "coins_apple_webhook")

      {:ok, purchase} =
        Payments.create_purchase(user, provider_product, %{
          "provider_transaction_id" => "apple_tx_1",
          "provider_original_transaction_id" => "apple_orig_1"
        })

      {:ok, _purchase} = Payments.fulfill_purchase(purchase)

      body =
        Jason.encode!(%{
          "notificationUUID" => "apple_note_1",
          "notificationType" => "REFUND",
          "decoded_transaction_info" => %{
            "transactionId" => "apple_tx_1",
            "originalTransactionId" => "apple_orig_1",
            "productId" => provider_product.external_id,
            "revocationDate" => "1700000000000"
          }
        })

      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/payments/webhooks/apple", body)
        |> json_response(200)

      assert response == %{"ok" => true, "status" => "processed"}
      assert Payments.get_purchase(purchase.id).status == "revoked"
    end
  end

  describe "POST /api/v1/payments/validate/:provider" do
    test "validates store purchase through provider adapter", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {_product, provider_product} = create_provider_product("google", "coins_google")

      response =
        conn
        |> auth_conn(user)
        |> post("/api/v1/payments/validate/google", %{
          "product_id" => provider_product.external_id,
          "transaction_id" => "google_tx_1"
        })
        |> json_response(200)

      assert response["data"]["seen_before"] == false
      assert response["data"]["purchase"]["status"] == "completed"
      assert Payments.wallet_balance(user.id, "coins") == 100
    end
  end

  defp create_provider_product(provider, external_id) do
    sku = "coins_#{System.unique_integer([:positive])}"

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

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp json_webhook_conn(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "test")
  end

  defp restore_env(key, nil), do: Application.delete_env(:game_server_core, key)
  defp restore_env(key, value), do: Application.put_env(:game_server_core, key, value)
end
