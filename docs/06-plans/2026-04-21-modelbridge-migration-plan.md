# ModelBridge Migration Plan

Status: completed on 2026-04-21

## Goal

Move the `cc-router` source tree into `../ModelBridge` so that `ModelBridge` becomes the only project root, while keeping the verified runtime path intact:

- `Claude Code CLI`
- `ANTHROPIC_BASE_URL`
- local gateway
- `chatgpt.com/backend-api/codex/responses`

## Verified Starting Point

- `../ModelBridge` is a default Xcode macOS App template with one app target, one unit-test target, and one UI-test target.
- `cc-router` already contains the working gateway runtime, scripts, tests, and docs.
- `ModelBridge` must become the host root for:
  - `Package.swift`
  - `Sources/`
  - `Tests/`
  - `docs/`
  - `scripts/`
  - root config files such as `.gitignore`

## Migration Shape

### 1. Root move

Move the project-owned tree from `cc-router` into `../ModelBridge`:

- `.gitignore`
- `.swiftpm`
- `Package.swift`
- `Sources`
- `Tests`
- `docs`
- `scripts`
- `dist`
- `tmp-edit-check.txt`

Generated build cache `.build/` is not part of the source tree and will not be migrated.

### 2. Xcode app target adaptation

Keep the Xcode project created by the user.

Replace the default SwiftData template code in:

- `ModelBridge/ModelBridgeApp.swift`
- `ModelBridge/ContentView.swift`
- `ModelBridge/Item.swift`

with the app shell that currently lives in `Sources/CCRouterApp`.

### 3. Local package integration

After the root move, `../ModelBridge/Package.swift` becomes the local Swift package manifest.

The Xcode project must add the local package at `.` and link:

- app target -> `CCRouterCore`
- unit-test target -> `CCRouterCore`

The CLI daemon executable target remains in the package.

### 4. Validation

Run these validations from `../ModelBridge`:

1. `xcodebuild -project ModelBridge.xcodeproj -scheme ModelBridge -destination 'platform=macOS' build`
2. `xcodebuild test -project ModelBridge.xcodeproj -scheme ModelBridge -destination 'platform=macOS'`
3. `swift build`
4. `swift test`
5. `bash scripts/smoke_local_gateway.sh`

## Expected End State

- `ModelBridge` is the only active project root.
- The Xcode app target hosts the macOS app shell.
- The package inside the same root continues to host:
  - `CCRouterCore`
  - daemon executable
  - package tests
- Docs and scripts move with the project instead of staying behind in `cc-router`.

## Verified Completion State

- `../ModelBridge` now contains the migrated:
  - `Package.swift`
  - `Sources/`
  - `Tests/`
  - `docs/`
  - `scripts/`
  - `dist/`
- `../cc-router` now only contains `.build/`, which is build cache and not part of the source tree.
- `xcodebuild -project ModelBridge.xcodeproj -scheme ModelBridge -destination 'platform=macOS' -derivedDataPath /tmp/ModelBridgeDerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` passed.
- `xcodebuild test -project ModelBridge.xcodeproj -scheme ModelBridge -destination 'platform=macOS' -derivedDataPath /tmp/ModelBridgeDerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:ModelBridgeTests` passed.
- `swift build --scratch-path /tmp/ModelBridgeSwiftBuild` passed.
- `swift test --scratch-path /tmp/ModelBridgeSwiftTest` passed.
- `bash scripts/build_app_bundle.sh` passed and produced `dist/ModelBridge.app`.
- `bash scripts/smoke_local_gateway.sh` passed from the `ModelBridge` root.
