---
type: research
date: 2026-04-23
phase: 5
source: github.com/openai/codex
---

# Codex CLI Refresh Endpoint Probe

## Source Files Examined

| File | SHA / Branch | Purpose |
|------|-------------|---------|
| `codex-rs/login/src/auth/manager.rs` | main | `request_chatgpt_token_refresh`, `RefreshRequest`, `RefreshResponse` structs |
| `codex-rs/login/src/auth/storage.rs` | main | `AuthDotJson` structure, `persist_tokens`, file write with 0600 mode |
| `codex-rs/login/src/token_data.rs` | main | `TokenData` struct fields |
| `codex-rs/login/tests/suite/auth_refresh.rs` | main | Integration test confirms rotating behavior |

Endpoint confirmed: `https://auth.openai.com/oauth/token`

Request shape: `POST application/json` with fields `client_id` (`"app_EMoamEEZ73f0CkXaXp7hrann"`), `grant_type` (`"refresh_token"`), `refresh_token`.

Response shape: JSON with `access_token`, `refresh_token` (rotating), `id_token` (optional).

Refresh_token rotating: `true` — each successful refresh issues a new refresh_token and invalidates the previous one (one-time-use). Confirmed via `RefreshResponse` struct, `persist_tokens` overwrite, and integration test `auth_refresh.rs`.

## Endpoint confirmed (detail)

`https://auth.openai.com/oauth/token`

Overridable via `CODEX_REFRESH_TOKEN_URL_OVERRIDE` env var.

## Request shape (detail)

**HTTP method:** `POST`
**Content-Type:** `application/json` (not `application/x-www-form-urlencoded`)

```json
{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
  "grant_type": "refresh_token",
  "refresh_token": "<current refresh_token from auth.json>"
}
```

Response shape: JSON with `access_token`, `refresh_token` (rotating), `id_token` (optional).

Refresh_token rotating: `true`

## Response shape (detail)
interface RefreshResponse {
    id_token?:      string | null;
    access_token?:  string | null;
    refresh_token?: string | null;  // NEW refresh token (rotating — see below)
}
```

Note: The actual `RefreshResponse` Rust struct (manager.rs) includes all three fields. The integration test (`auth_refresh.rs`) confirms the response contains both `access_token` and `refresh_token`.

## last_refresh format

`last_refresh` is a top-level field in `auth.json`, stored as `DateTime<Utc>` (ISO 8601: `"2026-04-23T10:00:00Z"`). The `persist_tokens` function sets `last_refresh = Some(Utc::now())` after every successful refresh.

## Refresh_token rotating

**Status: `rotating: true`**

Evidence (codex-rs/main):

1. `RefreshResponse` struct in `manager.rs`:
   ```rust
   struct RefreshResponse {
       id_token: Option<String>,
       access_token: Option<String>,
       refresh_token: Option<String>,  // upstream returns a NEW refresh_token
   }
   ```

2. `persist_tokens` writes the new token back:
   ```rust
   if let Some(refresh_token) = refresh_token {
       tokens.refresh_token = refresh_token;  // overwrites old with new
   }
   ```

3. Integration test `auth_refresh.rs` (`refresh_token_succeeds_updates_storage`):
   ```rust
   .respond_with(ResponseTemplate::new(200).set_body_json(json!({
       "access_token": "new-access-token",
       "refresh_token": "new-refresh-token"  // new refresh_token returned
   })))
   assert_eq!(tokens, &refreshed_tokens);  // new refresh_token written to disk
   ```

4. Error classifier distinguishes `refresh_token_expired` from `refresh_token_reused`:
   - `refresh_token_reused` → `RefreshTokenFailedReason::Exhausted` — server-side enforcement of one-time-use.

**Conclusion:** OAuth refresh is rotating. Each successful refresh issues a new `refresh_token` and invalidates the previous one. Concurrent double-refresh with the same token results in `invalid_grant`. The actor-based serialization in `SubscriptionSessionLoader` is the correct mitigation.

## auth.json Structure

```json
{
  "auth_mode": "Chatgpt" | "ApiKey" | "ChatgptAuthTokens" | "AgentIdentity" | null,
  "OPENAI_API_KEY": "sk-..." | null,
  "tokens": {
    "id_token": "eyJ...",       // JWT (serialized IdTokenInfo)
    "access_token": "eyJ...",   // JWT bearer token
    "refresh_token": "...",
    "account_id": "..." | null
  },
  "last_refresh": "2026-04-23T10:00:00Z",
  "agent_identity": { ... } | null
}
```

## Key Design Implications for ModelBridge

1. **Endpoint URL:** Hardcode `https://auth.openai.com/oauth/token` in `AuthTokenRefresher`. Do NOT read from `auth.json`.
2. **Request body:** `application/json`, fields: `client_id` (`"app_EMoamEEZ73f0CkXaXp7hrann"`), `grant_type` (`"refresh_token"`), `refresh_token` (value from `auth.json`).
3. **Response:** `access_token` and `refresh_token` are both returned. Always write the new `refresh_token` back (rotating = true).
4. **last_refresh:** Parse response and write ISO 8601 UTC back to `auth.json` top-level field.
5. **id_token:** The response may include `id_token`; write it to `tokens.id_token` in auth.json (it is parsed as JWT claims).
6. **Error handling:** 401 on refresh means `refresh_token` is invalid/expired/exhausted. Return 503 to client. Do not retry refresh.
7. **client_id constant:** `"app_EMoamEEZ73f0CkXaXp7hrann"` — from `pub const CLIENT_ID` in `manager.rs`.

## Endpoint Diff: main vs. Latest Tag (rust-v0.0.2508241142)

No structural differences found in the refresh flow between `main` and the latest dated tag. The `RefreshRequest` / `RefreshResponse` shapes and `REFRESH_TOKEN_URL` constant were consistent across all examined commits. The latest tag uses the same `auth.openai.com` endpoint and same `CLIENT_ID`.
