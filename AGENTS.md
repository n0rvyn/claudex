# Repository Guidelines

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
