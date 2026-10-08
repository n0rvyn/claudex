# Claudex

Claudex is a macOS loopback gateway for Claude Code. Claude Code owns the UI, permissions, tool execution and agent loop. Claudex translates Anthropic Messages into model-only Responses requests authorized through official Sign in with ChatGPT (SIWC).

`Claude Code → authenticated loopback /v1/messages → https://api.openai.com/v1/responses`

## Authentication and boundaries

Continue with ChatGPT in Settings starts an app-owned browser authorization. Claudex validates PKCE, state, nonce, signed issuer/audience/expiry/subject and granted scopes before activating an account. Registrations are separate by issued client ID and subject, stored owner-only under `~/Library/Application Support/Claudex/SIWC`, with process-serialized rotating refresh. Codex credentials are never imported; no nested Codex agent or API-key billing fallback exists.

The gateway binds literal loopback and requires its local token for sensitive routes. `/health` contains only minimal service state. Model discovery is an explicit account action; availability alone does not establish subscription cost or supported effort.

## Conversation protocol

Each request sends full history and current instructions with `store:false`, `stream:true`. Client tools use the `claude` namespace and return to Claude Code for execution. Raw Responses items, including assistant phase and encrypted reasoning, are stored in owner-only sidecars indexed by account, session and transcript prefix. They are never disguised as Anthropic thinking signatures. Claude Code session metadata or `x-claude-code-session-id` is required.

Streaming emits independent parallel tool argument blocks, checks item/call identity and final arguments, and requires `response.completed`. Replay persistence precedes `message_stop`. Failed, incomplete, malformed or truncated streams never report successful completion. Inference is not automatically retried; reconnecting or repeating a request is a new user/client action.

Unsupported tool types and named forced tool choices return explicit errors. Nested advisor execution is retired. Existing routing rules are preserved, but their old model names/efforts are not certified for the newly authorized account.

## Validation

Offline: `bash scripts/smoke_local_gateway.sh`, or `swift test --scratch-path /tmp/ClaudexSIWCOffline --disable-sandbox` with module-cache environment paths in restricted environments.

macOS build: `xcodebuild -project Claudex.xcodeproj -scheme Claudex -destination 'platform=macOS' -derivedDataPath /tmp/ClaudexSIWCXcode CODE_SIGNING_ALLOWED=NO build`.

Compatibility target: local Claude Code **2.1.292**. Live compatibility is unverified. Before any live inference, the user must authorize browser login and account eligibility/capabilities must be checked. The approved future smoke budget is at most three tiny serial calls including retries, using the account-discovered lowest suitable subscription-cost model and minimum supported effort. Never infer cost from API pricing or model names, and never silently fall back to billed API access.

See [refactor guide](docs/06-plans/2026-10-08-siwc-refactor-dev-guide.md), [decision](docs/03-decisions/2026-10-08-siwc-model-only.md) and [validation record](docs/06-plans/2026-10-08-siwc-validation.md). Older `docs/scheme3` and private-backend probe scripts are historical experiments and must not be used as the current authentication workflow.
