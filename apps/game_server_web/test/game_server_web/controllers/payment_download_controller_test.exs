defmodule GameServerWeb.PaymentDownloadControllerTest do
  use GameServerWeb.ConnCase, async: false

  alias GameServer.AccountsFixtures
  alias GameServer.Payments

  setup do
    original_dir = Application.get_env(:game_server_web, :payment_downloads_dir)

    downloads_dir =
      Path.join(System.tmp_dir!(), "payment-downloads-#{System.unique_integer([:positive])}")

    File.mkdir_p!(downloads_dir)
    Application.put_env(:game_server_web, :payment_downloads_dir, downloads_dir)

    on_exit(fn ->
      restore_env(:payment_downloads_dir, original_dir)
      File.rm_rf(downloads_dir)
    end)

    %{downloads_dir: downloads_dir}
  end

  test "serves downloadable entitlement owned by current user", %{
    conn: conn,
    downloads_dir: downloads_dir
  } do
    user = AccountsFixtures.user_fixture()
    File.write!(Path.join(downloads_dir, "soundtrack.zip"), "download bytes")
    entitlement = grant_downloadable_entitlement(user, "soundtrack.zip")

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/payments/downloads/#{entitlement.id}")

    assert response(conn, 200) == "download bytes"
    assert get_resp_header(conn, "content-disposition") |> Enum.join(";") =~ "soundtrack.zip"
  end

  test "does not serve another user's entitlement", %{conn: conn, downloads_dir: downloads_dir} do
    owner = AccountsFixtures.user_fixture()
    other = AccountsFixtures.user_fixture()
    File.write!(Path.join(downloads_dir, "starter_pack.zip"), "secret")
    entitlement = grant_downloadable_entitlement(owner, "starter_pack.zip")

    conn =
      conn
      |> log_in_user(other)
      |> get(~p"/payments/downloads/#{entitlement.id}")

    assert response(conn, 404) == "Not found"
  end

  defp grant_downloadable_entitlement(user, asset_key) do
    sku = "download_#{System.unique_integer([:positive])}"

    {:ok, product} =
      Payments.create_product(%{
        "sku" => sku,
        "title" => "Download",
        "kind" => "entitlement",
        "grant_config" => %{
          "entitlement_key" => sku,
          "download" => %{"asset_key" => asset_key, "filename" => asset_key}
        }
      })

    {:ok, provider_product} =
      Payments.create_provider_product(%{
        "product_id" => product.id,
        "provider" => "stripe",
        "external_id" => "price_#{sku}",
        "currency" => "USD",
        "unit_amount" => 199
      })

    {:ok, purchase} = Payments.create_purchase(user, provider_product)
    {:ok, _purchase} = Payments.fulfill_purchase(purchase)

    user.id
    |> Payments.list_user_entitlements()
    |> Enum.find(&(&1.key == sku))
  end

  defp restore_env(key, nil), do: Application.delete_env(:game_server_web, key)
  defp restore_env(key, value), do: Application.put_env(:game_server_web, key, value)
end
