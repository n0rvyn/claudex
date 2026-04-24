# Repository Guidelines

## Active Development Guide

**当前在进行的重构:** `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md`

- Status: `active`，7 phases，Phase 1 未开工
- 进入方式: `/run-phase`（从 Phase 1 开始，skill 自管 `.claude/dev-workflow-state.yml`）
- 所有 DP-001..005 已 auto-resolved 按 Recommendation，用户可在 Phase 1 启动前推翻
- 设计证据基座: `docs/scheme3/01-validated-baseline.md` + `10-tool-mapping-v1.md` + `08-responses-http-contract.md` + `09-real-upstream-capture.md` + `16-request-shape-comparison-v1.md`
- 需要验证的 probe 任务（Phase 2/3/5）统一参考 `scripts/probe_responses_advisor_bridge.py` 的认证 + zstd + SSE 解析模板

## Project Structure & Module Organization

`ModelBridge` is a macOS menu bar app plus a local gateway runtime. Use the Xcode target in `ModelBridge/` for the shipping app shell (`ModelBridgeApp.swift`, `ContentView.swift`, assets). Keep shared runtime code in `Sources/CCRouterCore/`; this is the bridge that serves `/v1/messages` and forwards to Codex subscription endpoints. CLI helpers live in `Sources/CCRouterDaemon/` and `Sources/CCRouterApp/`. Swift package tests are in `Tests/CCRouterCoreTests/`. Project docs and validated research live under `docs/`, and repeatable workflows live under `scripts/`.

## Build, Test, and Development Commands

- `swift build --scratch-path /tmp/ModelBridgeSwiftBuild`: build the Swift package products.
- `swift test --scratch-path /tmp/ModelBridgeSwiftTest`: run Swift Testing suites in `Tests/CCRouterCoreTests`.
- `xcodebuild test -project ModelBridge.xcodeproj -scheme ModelBridge -destination 'platform=macOS' -only-testing:ModelBridgeTests`: run the Xcode unit-test target.
- `bash scripts/build_app_bundle.sh`: produce `dist/ModelBridge.app` with ad hoc signing.
- `bash scripts/smoke_local_gateway.sh`: start the local daemon and verify the real `Claude Code CLI -> ANTHROPIC_BASE_URL` path.

## Coding Style & Naming Conventions

Use Swift 6 style with 4-space indentation. Prefer small, focused types; keep protocol and JSON bridge logic in `CCRouterCore`, not in SwiftUI views. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and keep environment/config keys in their existing `CC_ROUTER_*` form for compatibility. Follow the repository’s existing Markdown style in `docs/`: short sections, explicit status, and evidence-backed statements only.

## Testing Guidelines

Use Swift Testing (`import Testing`, `@Test`, `#expect`); do not add XCTest to package tests. Name test files after the type under test, for example `RouterConfigurationStoreTests.swift`. Any change to runtime paths, auth, or trace behavior should keep both `swift test` and the smoke script green.

## Commit & Pull Request Guidelines

This workspace snapshot does not include `.git`, so no local commit history is available to infer conventions. Use short, imperative commit subjects, preferably Conventional Commit style such as `feat(gateway): add health diagnostics`. PRs should include: purpose, affected paths, validation commands run, and screenshots for SwiftUI or menu bar changes.

## Security & Configuration Tips

Do not commit local auth material. The runtime reads subscription state from `~/.codex/auth.json` and local gateway config from `~/Library/Application Support/ModelBridge/config.json` unless overridden by `CC_ROUTER_*`. Use `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` only against the local daemon during development.
