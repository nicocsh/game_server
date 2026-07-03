# July 2026

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
