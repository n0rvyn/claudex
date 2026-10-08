# Claudex

Claudex is a macOS loopback gateway for Claude Code. Claude Code owns the UI, permissions, tool execution and agent loop. Claudex translates Anthropic Messages into model-only Responses requests authorized through official Sign in with ChatGPT (SIWC).

`Claude Code → authenticated loopback /v1/messages → https://api.openai.com/v1/responses`

## Authentication and boundaries

Continue with ChatGPT in Settings starts an app-owned browser authorization. Claudex validates PKCE, state, nonce, signed issuer/audience/expiry/subject and granted scopes before activating an account. Registrations are separate by issued client ID and subject, stored owner-only under `~/Library/Application Support/Claudex/SIWC`, with process-serialized rotating refresh. Codex credentials are never imported; no nested Codex agent or API-key billing fallback exists.

The gateway binds literal loopback and requires its local token for sensitive routes. `/health` contains only minimal service state. Model discovery is an explicit account action; availability alone does not establish subscription cost or supported effort.

## Conversation protocol

Each request sends full history and current instructions with `store:false`, `stream:true`. Client tools use the `claude` namespace and return to Claude Code for execution. Raw Responses items, including assistant phase and encrypted reasoning, are stored in owner-only sidecars indexed by account, session and transcript prefix. They are never disguised as Anthropic thinking signatures. Claude Code session metadata or `x-claude-code-session-id` is required.

Streaming emits independent parallel tool argument blocks, checks item/call identity and final arguments, and requires `response.completed`. Replay persistence precedes `message_stop`. Failed, incomplete, malformed or truncated streams never report successful completion. Inference is not automatically retried; reconnecting or repeating a request is a new user/client action.

Unsupported tool types, native Anthropic web-search result conversion and named forced tool choices return explicit errors. Account-reported model details are preserved for capability review; no cost or effort is guessed. Advisor uses an independently configured Codex model and fixed effort under Account & model. The executor requests advice through an empty-argument tool; Claudex runs a tool-free review, emits native plaintext Advisor blocks, and resumes the executor. Both routes remain pinned through local tool continuation. Client effort never raises Advisor effort. Native max_uses is honored; max_tokens (SIWC rejects max_output_tokens), caching TTL, cache_control, programmatic callers and encrypted Anthropic Advisor results return explicit unsupported errors. defer_loading is accepted as a declaration hint; advice still runs only when invoked. Routing pickers use the selected account’s `/v1/models` catalog, and offered reasoning efforts come only from returned metadata. Login/account switches refresh once; startup can reuse an owner-only one-hour per-account cache; **Refresh account models** requests a fresh list. Failed or expired catalogs block saving/starting, and unavailable saved routes are labelled rather than silently replaced. Availability and metadata do not establish subscription cost.

## Live traffic panel

The popover reads actual SIWC request/Responses telemetry, independently of diagnostic log tails. Requests count Claude `/v1/messages` arrivals; model calls count executor, Advisor and executor-resume attempts separately. Tokens are provider-reported input + output, with Advisor identified separately; `+` marks partially reported usage, and `—` means unavailable. They never represent remaining plan quota. The five-minute window is labelled; initial measurements show their start time. Metadata persists under Replay/traffic.jsonl without prompts, tools, credentials or account identifiers. Detailed diagnostics remain in Activity.

## Validation

Offline: `bash scripts/smoke_local_gateway.sh`, or `swift test --scratch-path /tmp/ClaudexSIWCOffline --disable-sandbox` with module-cache environment paths in restricted environments.

macOS build: `xcodebuild -project Claudex.xcodeproj -scheme Claudex -destination 'platform=macOS' -derivedDataPath /tmp/ClaudexSIWCXcode CODE_SIGNING_ALLOWED=NO build`.

Compatibility target: installed Claude Code **2.1.294**. The actual failing declaration was `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-5-5","defer_loading":true}`. It now has an explicit Codex Advisor translation rather than being discarded. An opt-in offline test drives the installed client through Advisor → Read → real local tool result → final answer using the shipping bridge and fake upstream/account state: `CLAUDEX_CLAUDE_BIN=/absolute/path/to/claude swift test --filter installedClaudeOfflineAdvisorReadRoundtrip`.

Current verification and live acceptance are recorded in [Advisor validation](docs/06-plans/2026-10-08-advisor-validation.md). Tests use isolated replay/configuration/trace state and ephemeral credentials. Xcode unit-test hosts use an offline fixture; stock UI launch benchmarks are excluded from credential-safe validation.

See [refactor guide](docs/06-plans/2026-10-08-siwc-refactor-dev-guide.md), [decision](docs/03-decisions/2026-10-08-siwc-model-only.md) and [validation record](docs/06-plans/2026-10-08-siwc-validation.md). Older `docs/scheme3` and private-backend probe scripts are historical experiments and must not be used as the current authentication workflow.
