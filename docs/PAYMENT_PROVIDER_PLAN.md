# Payment Provider Decision Plan

Reviewed: 2026-06-14

## Decision

Use Stripe as the default web payment provider.

Keep Google Play, App Store, and Steam as platform-specific providers for purchases made inside those ecosystems. Do not use Stripe to bypass platform billing rules for in-app digital goods.

## Why Stripe Is Default For Web

Stripe is the best default for this project because it gives the shortest reliable path from a web checkout to a server-authoritative purchase ledger.

Reasons:

- Hosted Checkout reduces frontend and PCI surface for normal web card/wallet purchases.
- Test mode and sandbox keys let us test without moving real money.
- Webhooks cover async success, failed payment, refund, and dispute flows, which matches the server-side ledger model.
- Stripe Billing can cover subscriptions later without replacing the provider.
- Stripe Tax can help calculate and report tax, though the seller still needs to understand registration, filing, and remittance obligations.
- Current implementation already has Stripe Checkout, signed webhook verification, refund/dispute revocation, provider events, admin visibility, and tests.

Stripe is not a Merchant of Record. If the product needs a provider to take over tax/compliance/legal merchant responsibilities, evaluate Xsolla, Paddle, Lemon Squeezy, or another MoR provider.

## Provider Boundaries

| Surface | Default provider | Reason |
| --- | --- | --- |
| Web checkout | Stripe | Best developer speed, strong webhooks, test mode, subscriptions path |
| Android app distributed on Play | Google Play Billing | Required for in-app digital goods on Google Play |
| iOS app distributed on App Store | App Store / StoreKit | Required default path for in-app digital goods; external-payment rules vary by region/app category |
| Steam build | Steam MicroTxn | Native Steam commerce, overlay, and Steam account context |
| Game-focused web shop at scale | Revisit Xsolla | Game-specific MoR, local payments, tax/compliance support |

## Alternatives

### Adyen

Good fit when the business is already enterprise-scale, needs broad local acquiring, many regional payment methods, negotiated payment operations, or unified online/in-person payment stack.

Why not default:

- Heavier onboarding and operational setup than Stripe for an open-source game server starter.
- More valuable after volume, country coverage, and payment-method needs are proven.

Keep adapter option open.

### Braintree / PayPal

Good fit when PayPal conversion is a major requirement or the target audience strongly prefers PayPal/Venmo-style wallets.

Why not default:

- Adds another gateway and account model before demand is proven.
- Stripe can already cover common web card/wallet checkout needs.

Add Braintree or PayPal adapter if analytics show PayPal matters.

### Paddle

Good fit for SaaS-style digital products when Merchant of Record support is more important than direct processor control.

Why not default:

- Product is game-server commerce, not only SaaS billing.
- MoR providers add product, refund, support, and compliance policy constraints.
- Platform stores still need native platform billing for in-app purchases.

Evaluate if tax/compliance operations become the main bottleneck.

### Lemon Squeezy

Good fit for simple software/digital-product sales where MoR, tax, and subscription convenience matter more than deep game commerce.

Why not default:

- Less game-specific than Xsolla.
- Less direct control than Stripe.
- Needs separate provider adapter and product-policy review.

Evaluate for small web subscriptions or license-style products.

### Xsolla

Good fit for game-specific web stores, global local payment methods, fraud/tax/compliance operations, and Merchant of Record support.

Why not default:

- Heavier commercial onboarding and vendor coupling than Stripe.
- Better as a scale-up choice when game commerce needs exceed simple web checkout.

Most likely second web provider if the project becomes a serious game commerce platform.

### Chargebee / Recurly

Good fit as subscription billing layers.

Why not default:

- They are not the core payment gateway decision.
- Stripe Billing is enough until billing complexity proves otherwise.

## Implementation Plan

### Phase 1: Keep Stripe As Default Web Provider

- Keep `/api/v1/payments/checkout/stripe`.
- Keep signed `/api/v1/payments/webhooks/stripe`.
- Keep provider SKU mapping in `/admin/payments`.
- Keep provider config visibility in `/admin/config`.
- Add more Stripe fixture tests as real product types emerge.

### Phase 2: Harden Stripe Ops

- Add optional Stripe Tax setup notes when tax collection is needed.
- Add subscription lifecycle tests if subscriptions are enabled.
- Add admin filters for disputed, refunded, and revoked purchases.
- Add alerting/log surfacing for failed webhook verification and disputes.
- Add reconciliation job if dashboard/manual provider checks become common.

### Phase 3: Add Second Web Provider Only When Triggered

Add Braintree/PayPal if:

- PayPal demand is visible from users or market.
- Stripe conversion is lower than expected in PayPal-heavy regions.

Add Xsolla if:

- Game web shop, MoR, local payment coverage, fraud operations, or global tax handling becomes central.

Add Paddle or Lemon Squeezy if:

- Web sales become mostly SaaS-style subscriptions or license purchases.
- Merchant of Record is more important than direct processor control.

Add Adyen if:

- Volume, regions, or enterprise payment operations justify heavier setup.

## Revisit Criteria

Revisit this decision when one of these happens:

- Web payment volume is high enough that fees, authorization rates, or local acquiring matter.
- Tax/compliance workload becomes bigger than integration workload.
- A game needs a full web shop with regional payment methods and MoR support.
- Subscription lifecycle becomes complex enough to need dedicated billing tooling.
- PayPal demand is clearly material.

## Sources

- Stripe webhooks: https://docs.stripe.com/webhooks
- Stripe test/sandbox mode: https://docs.stripe.com/testing-use-cases
- Stripe Checkout payment methods: https://stripe.com/payments/checkout
- Stripe Billing subscriptions: https://docs.stripe.com/billing
- Stripe Tax: https://docs.stripe.com/tax
- Stripe disputes: https://docs.stripe.com/disputes/api
- Adyen Checkout API: https://docs.adyen.com/api-explorer/Checkout/latest/overview
- Braintree docs: https://developer.paypal.com/braintree/docs/
- Paddle Merchant of Record: https://www.paddle.com/
- Lemon Squeezy Merchant of Record: https://www.lemonsqueezy.com/reporting/merchant-of-record
- Xsolla Merchant of Record: https://xsolla.com/merchant-of-record
- Google Play payments policy: https://support.google.com/googleplay/android-developer/answer/10281818
- Apple App Store Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
