# Repository Guidelines

## Active Development Guide

Current guide: `docs/06-plans/2026-10-08-siwc-refactor-dev-guide.md`.
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

Live validation is separately gated on explicit user browser consent. Use account-discovered eligible models and minimum supported effort; never infer subscription cost from API pricing or names. At most three tiny serial model calls, including retries, after approval. No parallel probes or billing fallback. Claude Code compatibility target is local version 2.1.292; live compatibility remains unverified.
