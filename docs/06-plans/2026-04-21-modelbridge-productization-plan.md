---
type: plan
status: completed
tags: [macos, gateway, productization, swift]
refs:
  - docs/scheme3/20-implementation-blueprint.md
  - docs/scheme3/22-execution-and-acceptance.md
---

# ModelBridge Productization Plan

**Goal:** Turn the current working local gateway into a distributable macOS app with repeatable validation and hardened local runtime behavior.

**Architecture:** Keep the current `ANTHROPIC_BASE_URL -> local daemon -> /responses` runtime as the product core. Productization work focuses on hardening the loopback boundary, adding a distributable app bundle path, and making validation reproducible without depending on ad hoc terminal sessions.

**Tech Stack:** Swift 6.2, SwiftUI MenuBarExtra, Swift Package Manager, local loopback HTTP, shell packaging scripts

**Design doc:** [docs/scheme3/20-implementation-blueprint.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/20-implementation-blueprint.md)

**Crystal file:** none

**Threat model:** included

**Recommended additions (not in scope):**
- Notarization and Developer ID signing
- Auto-launch on login
- Rich connector diagnostics beyond the current trace view

## Threat Model

### Attack surface

- Loopback `POST /v1/messages` and `POST /v1/messages/count_tokens`
  - Risk: unauthorized local process uses the gateway
- Local auth file `~/.codex/auth.json`
  - Risk: invalid or stale ChatGPT credentials lead to ambiguous runtime failures
- Trace log `/tmp/modelbridge-trace.jsonl`
  - Risk: sensitive request metadata persists without visibility or cleanup strategy
- Packaging output `dist/ModelBridge.app`
  - Risk: users run an unsigned or stale binary without understanding provenance

### Failure modes

- Local gateway token validation failure
  - Safe default: deny request with explicit local auth error
- ChatGPT auth load failure
  - Safe default: surface doctor/auth error, do not proxy upstream
- App bundle packaging failure
  - Safe default: abort build script and emit a non-zero exit code
- Smoke validation failure
  - Safe default: stop script and surface failing step immediately

### Resource lifecycle

- Local daemon process started by smoke script
  - Success: stop on script exit
  - Error: stop in shell trap
  - Signal: stop in shell trap
- Trace file reads
  - Success: read only, no cleanup needed
  - Error: report missing file, no temp state left behind
  - Signal: no persistent child process involved
- App bundle output under `dist/`
  - Success: overwritten atomically by removing prior bundle first
  - Error: partial bundle remains under `dist/` and is safe to rebuild over
  - Signal: next packaging run recreates the bundle from scratch

<!-- section: task-1 keywords: runtime, auth, trace, gateway -->
### Task 1: Harden local runtime boundaries

**Files:**
- Modify: `Sources/CCRouterCore/RouterConfiguration.swift`
- Modify: `Sources/CCRouterCore/GatewayDaemon.swift`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift`
- Modify: `Sources/CCRouterCore/DoctorSnapshot.swift`
- Modify: `Sources/CCRouterApp/CCRouterApp.swift`

**Steps:**
1. Add explicit local gateway auth configuration so the daemon can validate incoming Claude requests instead of implicitly accepting any loopback caller.
2. Surface local auth state and configuration path in the doctor snapshot and menu bar UI.
3. Keep current trace visibility, but make runtime diagnostics explicit enough that auth/config failures are actionable from the app UI.

**Verify:**
Run: `swift build`
Expected: Build succeeds with no errors
<!-- /section -->

<!-- section: task-2 keywords: bundle, app, packaging, dist -->
### Task 2: Add distributable macOS app bundle packaging

**Files:**
- Create: `scripts/build_app_bundle.sh`
- Create: `dist/.gitkeep`

**Steps:**
1. Build the release `modelbridge-app` binary from SwiftPM.
2. Wrap the binary into `dist/ModelBridge.app/Contents/MacOS/`.
3. Generate a minimal `Info.plist` with bundle identifier, display name, executable name, and version metadata.
4. Ensure the script recreates the bundle cleanly on repeated runs.

**Verify:**
Run: `bash scripts/build_app_bundle.sh`
Expected: `dist/ModelBridge.app/Contents/Info.plist` and `dist/ModelBridge.app/Contents/MacOS/ModelBridge` both exist
<!-- /section -->

<!-- section: task-3 keywords: smoke, validation, cli, anthropic_base_url -->
### Task 3: Add repeatable smoke validation

**Files:**
- Create: `scripts/smoke_local_gateway.sh`
- Modify: `docs/scheme3/22-execution-and-acceptance.md`
- Modify: `docs/scheme3/README.md`

**Steps:**
1. Add a shell script that starts the local daemon, waits for `/health`, then runs the minimum validated `Claude Code CLI` path through `ANTHROPIC_BASE_URL`.
2. Keep the smoke script narrow: health check plus one real text-path Claude command.
3. Document the smoke script as the baseline runtime validation entry point.

**Verify:**
Run: `bash -n scripts/smoke_local_gateway.sh`
Expected: Shell syntax check passes with zero errors
<!-- /section -->

<!-- section: task-4 keywords: sidecar, product-surface, acceptance, docs -->
### Task 4: Lock product boundary and acceptance language

**Files:**
- Modify: `docs/scheme3/20-implementation-blueprint.md`
- Modify: `docs/scheme3/22-execution-and-acceptance.md`
- Modify: `docs/scheme3/README.md`

**Steps:**
1. State clearly which parts are already product core and which remain extension points.
2. Keep the research-side sidecar conclusions, but separate them from the current shipping runtime boundary.
3. Update the acceptance language so future work is measured against the actual product surface, not the older research probe surface.

**Verify:**
Run: `rg -n "sidecar|product core|smoke" docs/scheme3/README.md docs/scheme3/20-implementation-blueprint.md docs/scheme3/22-execution-and-acceptance.md`
Expected: Updated product boundary language is present in all three docs
<!-- /section -->

<!-- section: task-5 keywords: full, verification, swift, scripts -->
### Task 5: Full verification

**Files:**
- Verify only

**Steps:**
1. Rebuild the project after all changes.
2. Package the `.app` bundle.
3. Run the smoke validation script or its syntax gate, depending on current environment permissions.

**Verify:**
Run: `swift build`
Run: `bash scripts/build_app_bundle.sh`
Run: `bash -n scripts/smoke_local_gateway.sh`
Expected: Build succeeds, app bundle is created, and smoke script passes syntax validation
<!-- /section -->

## Execution Result

- `swift build` passed after local config persistence and ingress auth changes.
- `swift test` passed with `5` Swift Testing cases across:
  - `RouterConfigurationStoreTests`
  - `LocalGatewayAuthorizationTests`
- `bash scripts/build_app_bundle.sh` created `dist/ModelBridge.app`.
- `bash scripts/smoke_local_gateway.sh` passed through a dedicated `ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN` path.
- Real ingress auth check passed:
  - wrong `x-api-key` -> `401 Unauthorized`
  - correct `x-api-key` -> `200 OK` + `{"input_tokens":1}`
- Product docs were updated to remove the old fixed-token assumption and to describe the persisted gateway token flow.
