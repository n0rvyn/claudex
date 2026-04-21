---
type: plan
status: partial
tags: [macos, distribution, diagnostics, launch-at-login]
refs:
  - docs/scheme3/20-implementation-blueprint.md
  - docs/scheme3/22-execution-and-acceptance.md
---

# ModelBridge Distribution Follow-ups

## Goal

Split the remaining post-productization work into three tracks:

1. `launch at login`
2. richer connector diagnostics
3. signing and notarization

## Current verified facts

- `SMAppService.mainApp` compiles on the current toolchain.
- `SMAppService.Status` cases `notRegistered / enabled / requiresApproval / notFound` compile and expose raw values.
- `register()` and `unregister()` compile as throwing sync calls.
- Rebuilt `/health` now returns `traceDiagnostics` with:
  - `recentStageCounts`
  - `recentFunctionCallNames`
  - `recentConnectorNames`
  - `recentRejectedPaths`
- `security find-identity -v -p codesigning` currently returns `0 valid identities found`.
- `bash scripts/build_app_bundle.sh` now succeeds in `ModelBridge` and produces `dist/ModelBridge.app`.
- `codesign -dv --verbose=4 dist/ModelBridge.app` now shows `Signature=adhoc`.
- `codesign --verify --deep --strict --verbose=2 dist/ModelBridge.app` passes.
- `bash scripts/smoke_local_gateway.sh` passes from the `ModelBridge` root.

## Track 1. Launch at login

### What is in scope

- Show current `SMAppService.mainApp.status` in the app UI
- Provide enable / disable actions
- Explain `requiresApproval` and `notFound` directly in the UI

### What is not yet verified

- Real register / unregister behavior from the packaged `.app` bundle

### Reason

- Toggling a login item mutates user system state
- This machine currently has no signing identity, so runtime behavior must be treated as packaged-app validation, not as a bare executable assumption

## Track 2. Connector diagnostics

### What is in scope

- Summarize recent trace stages
- Summarize recent function call names
- Surface recent connector names
- Surface recent local auth rejects

### Why this matters

- Current trace lines are raw and useful for debugging, but not sufficient for fast product-level diagnosis

### Current status

- Completed in code and verified through:
  - `swift build`
  - `swift test`
  - rebuilt `/health` sample on a fresh daemon instance

## Track 3. Signing and notarization

### Current blocker

- `security find-identity -v -p codesigning` -> `0 valid identities found`
- login keychain searches for `Developer ID Application / Apple Development / Apple Distribution / Developer ID Installer` all returned no output
- local packaging now succeeds with `Signature=adhoc`, but there is still no Developer ID identity for public distribution

### Correction to the previous flow

The missing piece was not "Developer subscription vs no subscription".

The missing piece was:

- local packaging should have produced an `ad hoc` signed `.app`
- Developer ID is only needed for public distribution

### What can still be delivered now

- exact signing prerequisites
- exact notarization prerequisites
- build and release checklist

### What cannot be verified on this machine now

- actual Developer ID `codesign`
- actual notarization submission
- stapling

## Delivered now

- `launch at login` status + toggle wiring in the menu bar app
- connector diagnostics summary in `/health` and the app UI
- signing and notarization scripts:
  - [sign_app_bundle.sh](/Users/norvyn/Code/Projects/ModelBridge/scripts/sign_app_bundle.sh)
  - [notarize_app_bundle.sh](/Users/norvyn/Code/Projects/ModelBridge/scripts/notarize_app_bundle.sh)
- signing runbook:
  - [2026-04-21-modelbridge-signing-notarization-runbook.md](/Users/norvyn/Code/Projects/ModelBridge/docs/06-plans/2026-04-21-modelbridge-signing-notarization-runbook.md)

## Remaining blockers

1. Install a usable `Developer ID Application` identity into the login keychain.
2. Configure a `notarytool` keychain profile on this machine.
3. Run real packaged-app `launch at login` register / unregister validation from `dist/ModelBridge.app`.
