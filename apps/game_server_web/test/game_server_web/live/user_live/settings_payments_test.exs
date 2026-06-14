defmodule GameServerWeb.UserLive.SettingsPaymentsTest do
  use GameServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GameServer.AccountsFixtures
  alias GameServer.Payments

  test "regular user can view purchases and owned entitlements", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {_coins_product, coins_provider_product} = create_consumable_provider_product("stripe")
    {_pass_product, pass_provider_product} = create_downloadable_provider_product("stripe")

    {:ok, coins_purchase} = Payments.create_purchase(user, coins_provider_product)
    {:ok, _coins_purchase} = Payments.fulfill_purchase(coins_purchase)

    {:ok, pass_purchase} = Payments.create_purchase(user, pass_provider_product)
    {:ok, _pass_purchase} = Payments.fulfill_purchase(pass_purchase)

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/users/settings")

    assert html =~ "Payments"

    view
    |> element(~s(button[phx-click="settings_tab"][phx-value-tab="payments"]))
    |> render_click()

    rendered = render(view)
    assert rendered =~ coins_purchase.order_id
    assert rendered =~ pass_purchase.order_id
    assert rendered =~ "completed"
    assert rendered =~ "Starter Pack"
    assert rendered =~ "starter_pack"
    assert rendered =~ "Download"
    refute rendered =~ "Game Wallet"
  end

  defp create_consumable_provider_product(provider) do
    sku = "coins_#{System.unique_integer([:positive])}"

    {:ok, product} =
      Payments.create_product(%{
        "sku" => sku,
        "title" => "250 Coins",
        "kind" => "consumable",
        "grant_config" => %{"hook_payload" => %{"coins" => 250}}
      })

    {:ok, provider_product} =
      Payments.create_provider_product(%{
        "product_id" => product.id,
        "provider" => provider,
        "external_id" => "price_#{sku}",
        "currency" => "USD",
        "unit_amount" => 299
      })

    {product, provider_product}
  end

  defp create_downloadable_provider_product(provider) do
    sku = "starter_pack_#{System.unique_integer([:positive])}"

    {:ok, product} =
      Payments.create_product(%{
        "sku" => sku,
        "title" => "Starter Pack",
        "kind" => "entitlement",
        "grant_config" => %{
          "entitlement_key" => "starter_pack",
          "download" => %{"asset_key" => "starter_pack.zip", "filename" => "starter_pack.zip"}
        }
      })

    {:ok, provider_product} =
      Payments.create_provider_product(%{
        "product_id" => product.id,
        "provider" => provider,
        "external_id" => "price_#{sku}",
        "currency" => "USD",
        "unit_amount" => 499
      })

    {product, provider_product}
  end
end
