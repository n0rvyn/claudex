# Claudex

Claudex is a macOS local gateway that lets `Claude Code CLI` run through `ANTHROPIC_BASE_URL` while the upstream execution path uses the authenticated ChatGPT/Codex subscription on the same machine.

The current verified path is:

`Claude Code CLI -> ANTHROPIC_BASE_URL -> local /v1/messages gateway -> chatgpt.com/backend-api/codex/responses`

## What It Does

- Exposes Anthropic-compatible endpoints for Claude Code:
  - `POST /v1/messages`
  - `POST /v1/messages/count_tokens`
  - `GET /health`
- Reuses the local Codex login state from `~/.codex/auth.json`
- Persists local gateway configuration in `~/Library/Application Support/Claudex/config.json` (path derived from `com.90percent.Claudex` bundle ID)
- Ships a menu bar app for daemon control, doctor data, trace review, and Claude env copy

## Architecture Overview

- `Claude Code CLI` stays unmodified and points at the local daemon through `ANTHROPIC_BASE_URL`
- `GatewayDaemon` accepts Anthropic-style requests and enforces local gateway auth
- `ResponsesClient` forwards the translated execution path to `chatgpt.com/backend-api/codex/responses`
- `SubscriptionSession` reads the local ChatGPT/Codex login material from `~/.codex/auth.json`
- `TraceLogger` records runtime traces to `/tmp/modelbridge-trace.jsonl`
- The Xcode app shell surfaces daemon state, dashboard metrics, connector diagnostics, and the exact Claude env snippet

## Start Here

If a new Codex or Claude session needs immediate context, start with:

- `docs/00-session-brief.md`
- `docs/scheme3/README.md`

## Repository Layout

- `Claudex/`: active Xcode macOS app target and shipped UI shell
- `Sources/CCRouterCore/`: gateway, auth, trace, and protocol bridge code
- `Sources/CZstd/`: vendored zstd 1.5.7 source (compress + common) compiled as part of the SwiftPM build
- `Sources/CCRouterDaemon/`: local daemon entry point
- `Sources/CCRouterApp/`: legacy SwiftPM utility shell retained for package-local development; not the shipped app path
- `Tests/CCRouterCoreTests/`: Swift Testing coverage for config, auth, and trace diagnostics
- `scripts/`: bundle, smoke, signing, and notarization scripts
- `docs/`: validated research, execution notes, and productization plans

## Development

Build and test:

```bash
swift build
swift test
```

Build the macOS app bundle:

```bash
bash scripts/build_app_bundle.sh
```

Run the verified smoke path:

```bash
bash scripts/smoke_local_gateway.sh
```

Start the daemon directly during local debugging:

```bash
swift run claudex-daemon
```

Run the Xcode unit-test path:

```bash
xcodebuild test \
  -project Claudex.xcodeproj \
  -scheme Claudex \
  -destination 'platform=macOS' \
  -only-testing:ClaudexTests
```

## Claude Code Setup

Claudex is designed to be used through `ANTHROPIC_BASE_URL`.

Example:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:4317
export ANTHROPIC_AUTH_TOKEN=<gateway-token>
claude
```

In the Claude TUI, enter: `Reply exactly SMOKEOK.`

The app can copy the exact env snippet for the current local configuration. Internally, the daemon validates the incoming token through the configured `x-api-key` header.

## Local Configuration

Primary configuration file:

```text
~/Library/Application Support/Claudex/config.json
```

Fallback path when Application Support is unavailable:

```text
/tmp/modelbridge/config.json
```

Useful local overrides:

- `CC_ROUTER_HOST`
- `CC_ROUTER_PORT`
- `CC_ROUTER_GATEWAY_TOKEN`
- `CC_ROUTER_CONFIG_PATH`
- `CC_ROUTER_SUBSCRIPTION_AUTH_FILE`
- `CC_ROUTER_EXECUTOR_MODEL`
- `CC_ROUTER_ADVISOR_MODEL`

## Runtime Linking

Claudex does not rely on `/usr/local/opt/zstd/lib/libzstd.1.dylib` at launch time.

- The `CZstd` SwiftPM target compiles zstd 1.5.7 from source (`Sources/CZstd/lib/common` + `lib/compress`)
- Public headers exposed to Swift live at `Sources/CZstd/include/`
- SwiftPM/Xcode builds zstd per target architecture, so universal (arm64 + x86_64) Archive builds link cleanly without a Homebrew zstd dylib dependency

## Current Verified State

- `swift build` passes
- `swift test` passes
- `scripts/build_app_bundle.sh` builds `dist/Claudex.app`
- `scripts/smoke_local_gateway.sh` passes against the real local daemon
- The local bundle is currently ad hoc signed for local use
- The active Xcode app exposes a real-time dashboard plus a tabbed Settings window with `General`, `Gateway`, `Claude Code`, `Upstream`, and `Diagnostics`
- Settings can persist gateway configuration changes and regenerate the local ingress token

## Distribution Notes

Local development works with ad hoc signing. Public distribution still needs:

- `Developer ID Application` signing identity on this machine
- `notarytool` profile setup
- notarization and stapling
- packaged `.app` launch-at-login verification

See:

- `docs/00-session-brief.md`
- `docs/scheme3/README.md`
- `docs/06-plans/2026-04-21-modelbridge-distribution-followups.md`
- `docs/06-plans/2026-04-21-modelbridge-signing-notarization-runbook.md`
