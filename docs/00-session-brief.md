# ModelBridge Session Brief

Date: 2026-04-21

## 1. Project Goal

ModelBridge exists to preserve the `Claude Code CLI` user experience while routing requests through a local Anthropic-compatible gateway and using the authenticated local ChatGPT/Codex subscription as upstream execution.

Fixed product path:

`Claude Code CLI -> ANTHROPIC_BASE_URL -> local /v1/messages gateway -> chatgpt.com/backend-api/codex/responses`

## 2. Why This Exists

The hard constraints were fixed early and never changed:

- Frontend must remain `Claude Code CLI`
- Authentication and billing must come from `OpenAI subscription`
- The local product must be a macOS app, not just a terminal proxy

This ruled out:

- Anthropic-hosted backends
- plain OpenAI API billing
- replacing Claude Code with Codex CLI

## 3. Research Completed

The repository contains a full validation trail under `docs/research/` and `docs/scheme3/`.

Main outcomes:

- Claude Code can be driven through `ANTHROPIC_BASE_URL`
- the useful upstream is `chatgpt.com/backend-api/codex/responses`, not `api.openai.com/v1/responses`
- current Claude tool semantics can be translated to the observed `/responses` path
- `advisor` required a dedicated bridge instead of raw passthrough
- several app/product-side routes were observed under `/backend-api/...`
- `count_tokens` must exist for compatibility, but was not observed as a required hot-path request in the tested Claude entrypoints

Start with:

- `docs/scheme3/README.md`
- `docs/research/2026-04-20-claude-code-openai-subscription-router.md`

## 4. Current Verified Product State

What is already working:

- local daemon exposes `GET /health`, `POST /v1/messages`, and `POST /v1/messages/count_tokens`
- local gateway auth is enforced through `x-api-key`
- ChatGPT/Codex login state is read from `~/.codex/auth.json`
- the Xcode app now has a redesigned menu bar dashboard with hero state, metric cards, runtime activity cards, and a live trace feed
- the Settings window is now a single-window, multi-tab control center with `Overview`, `Gateway`, `Claude Code`, `Upstream`, `Diagnostics`, and `Advanced`
- `Claude Code CLI` has already completed real text, tool, and advisor paths through the local daemon
- `scripts/smoke_local_gateway.sh` is the current repeatable runtime check
- `dist/ModelBridge.app` builds locally

## 5. Important Runtime Fixes Already Landed

- `ModelBridge` no longer depends on Homebrew's dynamic `libzstd.1.dylib` at launch time
- zstd is now vendored as a static archive under `Vendor/zstd/lib/libzstd.a`
- this fixed the earlier app startup failure caused by unsigned external zstd dylibs

## 6. Current Progress

Current state is beyond research and prototype:

- repo exists and is pushed to `n0rvyn/model-bridge`
- macOS app target exists in Xcode
- Swift package build and tests pass
- the core forwarding path is implemented
- local packaging works
- the redesigned Xcode app compiles and launches without the earlier zstd startup failure
- the debug app no longer needs Homebrew zstd dylibs and no longer crashes on launch

Current UI status:

- Xcode build for the redesigned app passes
- launching the built app succeeds and recent logs show normal AppKit window activity instead of dyld startup failure
- `launch at login` remains packaged-app-only; debug builds return `ServiceManagement` status noise if older app processes are still running
- the current UI redesign is implemented on the Xcode app path under `ModelBridge/`, not yet duplicated into the separate SwiftPM utility target under `Sources/CCRouterApp/`

Current state is not yet public-distribution complete:

- no verified `Developer ID Application` identity is installed on this machine
- notarization and stapling are not done
- packaged app `launch at login` still needs full system-level validation

## 7. Best Next Entry Points

If the next session needs architecture context:

- read `docs/scheme3/20-implementation-blueprint.md`
- read `docs/scheme3/21-gateway-modules.md`
- read `docs/scheme3/22-execution-and-acceptance.md`

If the next session needs productization/distribution context:

- read `docs/06-plans/2026-04-21-modelbridge-productization-plan.md`
- read `docs/06-plans/2026-04-21-modelbridge-distribution-followups.md`
- read `docs/06-plans/2026-04-21-modelbridge-signing-notarization-runbook.md`

If the next session needs current UI context:

- read `docs/06-plans/2026-04-21-modelbridge-dashboard-design.md`
- inspect `ModelBridge/ContentView.swift`
- inspect `ModelBridge/ModelBridgeApp.swift`

If the next session needs a quick health check:

- run `swift test`
- run `bash scripts/build_app_bundle.sh`
- run `bash scripts/smoke_local_gateway.sh`

## 8. One-Line Status

ModelBridge is already a working local macOS gateway for `Claude Code CLI + ANTHROPIC_BASE_URL + OpenAI subscription`; the remaining work is distribution hardening, signing, notarization, and final product polish rather than protocol feasibility.
