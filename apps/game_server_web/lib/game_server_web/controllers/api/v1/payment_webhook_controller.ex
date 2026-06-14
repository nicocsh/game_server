defmodule GameServerWeb.Api.V1.PaymentWebhookController do
  use GameServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GameServer.Payments

  tags(["Payments"])

  operation(:stripe,
    operation_id: "payments_stripe_webhook",
    summary: "Receive Stripe webhook events",
    request_body: {"Stripe event", "application/json", %OpenApiSpex.Schema{type: :object}},
    responses: [
      ok: {"Accepted", "application/json", %OpenApiSpex.Schema{type: :object}},
      bad_request: {"Invalid webhook", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def stripe(conn, _params) do
    raw_body = conn.private[:raw_body] || ""
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case Payments.handle_stripe_webhook(raw_body, signature) do
      {:ok, status} ->
        json(conn, %{ok: true, status: status})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: normalize_error(reason)})
    end
  end

  operation(:google,
    operation_id: "payments_google_webhook",
    summary: "Receive Google Play RTDN Pub/Sub push events",
    request_body: {"Google RTDN event", "application/json", %OpenApiSpex.Schema{type: :object}},
    responses: [
      ok: {"Accepted", "application/json", %OpenApiSpex.Schema{type: :object}},
      bad_request: {"Invalid webhook", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def google(conn, _params) do
    raw_body = conn.private[:raw_body] || ""
    authorization = conn |> get_req_header("authorization") |> List.first()

    case Payments.handle_google_webhook(raw_body, authorization) do
      {:ok, status} ->
        json(conn, %{ok: true, status: status})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: normalize_error(reason)})
    end
  end

  operation(:apple,
    operation_id: "payments_apple_webhook",
    summary: "Receive App Store Server Notification v2 events",
    request_body: {"Apple notification", "application/json", %OpenApiSpex.Schema{type: :object}},
    responses: [
      ok: {"Accepted", "application/json", %OpenApiSpex.Schema{type: :object}},
      bad_request: {"Invalid webhook", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def apple(conn, _params) do
    raw_body = conn.private[:raw_body] || ""

    case Payments.handle_apple_webhook(raw_body) do
      {:ok, status} ->
        json(conn, %{ok: true, status: status})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: normalize_error(reason)})
    end
  end

  defp normalize_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_error(reason), do: inspect(reason)
end
