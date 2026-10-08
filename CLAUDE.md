# Repository Guidelines

## Active Development Guide

Current guide: `docs/06-plans/2026-10-08-advisor-compatibility-plan.md`; the SIWC refactor guide remains architectural context.
The 2026-04 private-backend experiments are historical evidence. Never run their credential-reading/live probes during offline work.

## Project Structure & Module Organization

`Claudex` is a macOS menu bar app plus a local gateway runtime. Use the Xcode target in `Claudex/` for the shipping app shell (`ClaudexApp.swift`, `ContentView.swift`, assets). Keep shared runtime code in `Sources/CCRouterCore/`; this is the bridge that serves `/v1/messages` and forwards to the official SIWC-authorized public Responses endpoint. CLI helpers live in `Sources/CCRouterDaemon/` and `Sources/CCRouterApp/`. Swift package tests are in `Tests/CCRouterCoreTests/`. Project docs and validated research live under `docs/`, and repeatable workflows live under `scripts/`.

## Build, Test, and Development Commands

- `swift build --scratch-path /tmp/ClaudexSwiftBuild`: build the Swift package products.
- `swift test --scratch-path /tmp/ClaudexSwiftTest`: run Swift Testing suites in `Tests/CCRouterCoreTests`.
- `xcodebuild test -project Claudex.xcodeproj -scheme Claudex -destination 'platform=macOS' -only-testing:ClaudexTests`: run the Xcode unit-test target.
- `bash scripts/build_app_bundle.sh`: produce `dist/Claudex.app` with ad hoc signing.
- `bash scripts/smoke_local_gateway.sh`: run offline SIWC/loopback fixtures without sign-in or inference.

## Coding Style & Naming Conventions

Use Swift 6 style with 4-space indentation. Prefer small, focused types; keep protocol and JSON bridge logic in `CCRouterCore`, not in SwiftUI views. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and keep environment/config keys in their existing `CC_ROUTER_*` form for compatibility. Follow the repository’s existing Markdown style in `docs/`: short sections, explicit status, and evidence-backed statements only.

## Testing Guidelines

Use Swift Testing (`import Testing`, `@Test`, `#expect`); do not add XCTest to package tests. Name test files after the type under test, for example `RouterConfigurationStoreTests.swift`. Any change to runtime paths, auth, or trace behavior should keep both `swift test` and the smoke script green.

## Commit & Pull Request Guidelines

Use short, imperative commit subjects, preferably Conventional Commit style such as `feat(gateway): add health diagnostics`. PRs should include: purpose, affected paths, validation commands run, and screenshots for SwiftUI or menu bar changes.

## Security & Configuration Tips

Do not commit local auth material. The runtime owns SIWC registrations in `~/Library/Application Support/Claudex/SIWC/accounts.json`; it never imports Codex credentials. Local gateway config from `~/Library/Application Support/Claudex/config.json` (path derived from `com.90percent.Claudex` bundle ID) unless overridden by `CC_ROUTER_*`. Use `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` only against the local daemon during development.

Live validation is separately gated on explicit user browser consent. Use account-discovered eligible models and minimum supported effort; never infer subscription cost from API pricing or names. Preserve the acceptance ledger at `/tmp/claudex-acceptance-20261008/ledger.json`; do not reset it. User authorized limit 9 retaining count 7 and exactly two Read/continuation requests on Luna / low / Standard. Both succeeded; count is now 9/9 and gateway is paused. No further inference is authorized. No parallel probes or billing fallback. Claude Code compatibility target is installed version 2.1.294. See the current Advisor validation record for verified coverage.

## Current Advisor constraint
User: “Keep Advisor with its own explicitly configured model and effort. Do not automatically raise effort.” Use configuration.advisorRoute independently of the executor route and client effort. Preserve that route through tool continuation.

User UI choice: “a compact Advisor section in Account & model with just Model and Effort, rather than configuration-file-only controls.”

User: “Simplify Claudex’s menu-bar UI into a quick-access panel for everyday actions, not a second settings center.” Keep gateway status, Start/Pause, essential connection/error feedback and Activity/Settings shortcuts there. Account management, model/effort mapping, Advisor and advanced configuration live only in the settings window. Preserve the functions.

Advisor was explicitly selected as GPT-6 Luna / low. Current live boundary: the later two-request authorization is exhausted at 9/9; do not retry or reset the ledger.

User correction: “My request to move settings out was NOT a request to remove useful operational information.” The popover is a compact live status/traffic panel: compact Start/Pause, active requests, relevant errors, clearly labelled recorded request trend, measured latency/error summary, separately labelled token/Advisor/network-byte availability, and small Activity/Settings shortcuts. No quota claims or model calls to populate UI; forms remain in Settings.

## Normal-use restoration
After the user reported that manual Start still hit the acceptance cap, the agent-owned guarded process was gracefully replaced with the same final build without CC_ROUTER_ACCEPTANCE_* environment variables. The normal gateway was started through its UI; sole listener PID 15471 on 127.0.0.1:4317. The 9/9 acceptance ledger remains unchanged. This restores user operation; it does not authorize further agent-initiated live tests.

## Corrected traffic UI and measurement source
User: “the top half is fine” and “correct the count logic”. Preserve the status/Start/Pause area. Remove Recent log and unavailable-metric clutter from the popover bottom. The shipping SIWC bridge now records requests, separate model calls, provider input/output and Advisor usage, completed-request latency and errors. Popover counters use SIWCTraffic, not the legacy TraceDiagnostics tail. Five-minute totals and one-minute request buckets share the same measurement window. Do not invent missing historical counters or confuse tokens with quota. Detailed logs and latency diagnostics belong in Activity. Latest normal app: PID 18977, sole 4317 listener; no acceptance variables. No agent-initiated live inference during this refinement.

Activity success count, completed-request success rate, latest outcome and measured latency percentiles consume the same SIWCTraffic snapshot as the popover; do not leave them on the legacy diagnostic-tail counters.
