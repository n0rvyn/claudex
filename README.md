# ModelBridge

ModelBridge is a macOS local gateway that lets `Claude Code CLI` run through `ANTHROPIC_BASE_URL` while the upstream execution path uses the authenticated ChatGPT/Codex subscription on the same machine.

The current verified path is:

`Claude Code CLI -> ANTHROPIC_BASE_URL -> local /v1/messages gateway -> chatgpt.com/backend-api/codex/responses`

## What It Does

- Exposes Anthropic-compatible endpoints for Claude Code:
  - `POST /v1/messages`
  - `POST /v1/messages/count_tokens`
  - `GET /health`
- Reuses the local Codex login state from `~/.codex/auth.json`
- Persists local gateway configuration in `~/Library/Application Support/ModelBridge/config.json`
- Ships a menu bar app for daemon control, doctor data, trace review, and Claude env copy

## Architecture Overview

- `Claude Code CLI` stays unmodified and points at the local daemon through `ANTHROPIC_BASE_URL`
- `GatewayDaemon` accepts Anthropic-style requests and enforces local gateway auth
- `ResponsesClient` forwards the translated execution path to `chatgpt.com/backend-api/codex/responses`
- `SubscriptionSession` reads the local ChatGPT/Codex login material from `~/.codex/auth.json`
- `TraceLogger` records runtime traces to `/tmp/modelbridge-trace.jsonl`
- The menu bar app surfaces daemon state, doctor information, connector diagnostics, and the exact Claude env snippet

## Repository Layout

- `ModelBridge/`: Xcode macOS app target
- `Sources/CCRouterCore/`: gateway, auth, trace, and protocol bridge code
- `Vendor/zstd/`: vendored zstd static archive used to avoid external Homebrew dylib runtime linkage
- `Sources/CCRouterDaemon/`: local daemon entry point
- `Sources/CCRouterApp/`: menu bar runtime used by the Swift package build
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
swift run modelbridge-daemon
```

Run the Xcode unit-test path:

```bash
xcodebuild test \
  -project ModelBridge.xcodeproj \
  -scheme ModelBridge \
  -destination 'platform=macOS' \
  -only-testing:ModelBridgeTests
```

## Claude Code Setup

ModelBridge is designed to be used through `ANTHROPIC_BASE_URL`.

Example:

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:4317
ANTHROPIC_AUTH_TOKEN=<gateway-token>
claude --bare -p --output-format json 'Reply exactly SMOKEOK.'
```

The app can copy the exact env snippet for the current local configuration. Internally, the daemon validates the incoming token through the configured `x-api-key` header.

## Local Configuration

Primary configuration file:

```text
~/Library/Application Support/ModelBridge/config.json
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

ModelBridge does not rely on `/usr/local/opt/zstd/lib/libzstd.1.dylib` at launch time.

- The repository vendors `libzstd.a` under `Vendor/zstd/lib/`
- The `CZstd` target exposes the vendored headers from `Sources/CZstd/include/`
- The packaged app and the Xcode Debug app are both verified to launch without a Homebrew zstd dylib dependency

## Current Verified State

- `swift build` passes
- `swift test` passes
- `scripts/build_app_bundle.sh` builds `dist/ModelBridge.app`
- `scripts/smoke_local_gateway.sh` passes against the real local daemon
- The local bundle is currently ad hoc signed for local use

## Distribution Notes

Local development works with ad hoc signing. Public distribution still needs:

- `Developer ID Application` signing identity on this machine
- `notarytool` profile setup
- notarization and stapling
- packaged `.app` launch-at-login verification

See:

- `docs/scheme3/README.md`
- `docs/06-plans/2026-04-21-modelbridge-distribution-followups.md`
- `docs/06-plans/2026-04-21-modelbridge-signing-notarization-runbook.md`
