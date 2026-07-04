# July 2026

- [fixed] Application boot no longer depends on the database being reachable/migrated: the persisted IP-ban load runs after startup and retries with error logging instead of crash-looping the app (e.g. during rolling restarts); CI spec-generation jobs also migrate before booting.

- [added] **Data retention**: old chat messages, notifications, and payment provider events are pruned periodically, configurable via `RETENTION_CHAT_DAYS` / `RETENTION_NOTIFICATIONS_DAYS` / `RETENTION_PAYMENT_EVENTS_DAYS` (unset keeps forever); expired IP bans are always cleaned up.
- [added] **Cache & limits observability**: hit/miss counters per cache prefix, rate-limit denials, and async overloads on the admin dashboard and as Prometheus metrics (`game_server_cache_reads_total`, `game_server_rate_limit_denies_total`, `game_server_async_overload_total`).
- [changed] Presence writes only on real online/offline transitions — reconnects and extra tabs no longer write to the `users` table, and `after_user_online`/`after_user_offline` hooks fire once per session instead of once per socket.
- [changed] `GameServer.TaskSupervisor` is bounded (`max_children: 200`); at capacity, async side effects run inline in the caller (back-pressure) instead of spawning unsupervised processes.
- [changed] `GameServer.Groups` split into `Groups.Invites`, `Groups.JoinRequests`, and an internal `Groups.Shared` — the public `GameServer.Groups` API is unchanged (delegations).
- [changed] `has_more` in pagination meta is now exact (`page < total_pages`) instead of the `count == page_size` heuristic.
- [changed] CI now runs credo (strict), dependency audit, and dialyzer (advisory) in addition to formatting and tests.

- [breaking] **Context APIs take a single input shape**: `Friends` list/count functions and `Accounts.set_user_online/offline` accept user ids only; `Payments.create_purchase/3` accepts a `%User{}`; `Payments.reconcile_stripe_purchase/1` accepts a `%Purchase{}` (no more struct-or-id unions).
- [changed] Friend notifications are created at the event source in `GameServer.Friends`; the `FriendNotifier` GenServer was removed (it duplicated writes per app instance and serialized all friend events).
- [changed] `AdminLogBuffer` is now an ETS ring buffer — log writes no longer serialize through a GenServer.
- [changed] The user settings LiveView was split into per-tab modules (`Settings.AccountTab`/`FriendsTab`/`GroupsTab`/`PaymentsTab`/`DataTab`); friends and KV lists use LiveView streams.

- [fixed] **Cache API misuse after Nebulex 3 upgrade**: manual `Cache.get` calls treated the v3 `{:ok, value}` result as a raw value — the KV read/list/count caches never hit (every read went to the DB), version-key defaults were dead code, and the plugin-facing `GameServer.Cache.cached/3` returned `{:ok, nil}` instead of computing on a miss. All call sites now use `get!`/`fetch`.
- [added] **Cross-instance cache invalidation**: `GameServer.Cache.invalidate/1` broadcasts deletions via PubSub and `GameServer.Cache.Sync` evicts the key from every node's L1. Used for cached users, sessions, tokens, and KV entries.
- [changed] Cached user structs now carry a 60s TTL and are evicted cluster-wide on change, so credential revocation and account deactivation apply immediately on all instances.

- [added] **JWT revocation**: tokens carry a `token_version` claim; password/email changes and `Accounts.revoke_all_tokens/1` invalidate all previously issued access and refresh tokens.
- [breaking] Tokens issued before this release (without the `token_version` claim) are rejected — all API clients must log in again after upgrading.
- [added] **Redis rate-limit backend** (`RATE_LIMIT_BACKEND=redis`) so limits are shared across app instances; ETS remains the default.
- [added] **Persistent IP bans**: bans are stored in the database, survive restarts, and propagate to all instances via PubSub.
- [fixed] Search queries now escape `LIKE` wildcards (`%`, `_`) consistently across users, lobbies, groups, KV, chat, notifications, and payments filters.

# April 2026

- [changed] Root host app restructure.
- [added] Browser theme color, sitemap.xml, robots.txt.
- [added] **Native HTTPS**
- [added] **Account Activation** beta mode.
- [added] Translations: Spanish, French, Romanian.
- [added] Roadmap page.
- [added] Security: RealIp, IP bans, OAuth CSRF, rate limiting, WebRTC - limits, security headers.
- [added] **OPENAPI_ENABLED** feature gate.

# March 2026

- [changed] Make Leaderboards accept label instead of user_id.
- [added] Initial version of **Achievements**.
- [added] Initial version of **Rate Limiting**.
- [changed] Self-hosted Inter font and eliminated all inline scripts.
- [added] Initial version of **WebSocket** updates.
- [added] Initial version of **WebRTC** updates.
- [changed] Admin interface with realtime connections view.

# Feb 2026

- [added] Initial version of **CHANGELOG** and **Blog**.
- [added] Initial version of **Groups**.
- [added] Initial version of **Parties**.
- [added] Initial version of **Notifications**.
- [added] Initial version of **Chat**.
