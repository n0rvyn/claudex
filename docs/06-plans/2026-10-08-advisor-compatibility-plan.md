---
type: plan
status: complete
contract_version: 2
tags: [siwc, advisor, claude-code]
---
# Claude Code Advisor compatibility

**Goal:** Complete Claude Code 2.1.294 tools and Advisor through app-owned Codex inference.
**Architecture:** Translate the actual advisor_20260301 declaration into a separate gateway-owned Responses function. Execute its tool-free Codex review with the full current transcript, return real plaintext advisor_result/server_tool_use blocks to Claude, and resume the executor with the real result. Claude continues to execute every client tool and permission check.
**Tech Stack:** Swift 6, Responses SSE, Anthropic SSE.
**Design doc:** docs/03-decisions/2026-10-08-siwc-model-only.md (advisor retirement superseded by current user authorization).
**Design analysis:** none
**Crystal file:** none
**Bug diagnosis:** SIWCBridge.effectiveTools rejects the captured advisor_20260301 declaration: name advisor, model claude-opus-5-5, defer_loading true, no function schema. Original failed session records Sonnet 5.5 and enabled Opus Advisor. Offline installed-client capture confirms shape. The new design adds serial inference and plan usage when the executor calls Advisor.
**Threat model:** Untrusted schemas, tool arguments and upstream streams; preserve cancellation and no retry; no forged encryption or imported credentials.
**Pre-flight risks:** Old advisor route fields remain in configuration and tests; reuse existing route mapping. Caller inventory uses rg, no available LSP tool. Test-only legacy bridge has many consumers; migrate useful tests before deletion.
**Project context contract:** missing

## Impact Map
**User path:** Claude terminal or headless → Advisor / Read → continuation → final answer.
**Data path:** native Advisor declaration → gateway function → tool-free Codex review → real plaintext advisor result → executor continuation → replay.
**Shared surfaces:** SIWCBridge, SSE encoder, replay, model routing, fixtures, docs.
**Existing consumers:** GatewayDaemon, app bridge, count-tokens path, SIWCBridgeTests, captured Claude fixtures.
**Must remain unchanged:** Claude interface, local tool execution, permissions, account authorization and production Activity isolation.
**Regression checks:** fixture roundtrip, route pinning, cache-marker replay, parallel calls, interruption, auth suite, Swift tests and macOS build.

### Task 1: Isolate tests and retain actual request evidence
**Files:**
- Modify: Tests/CCRouterCoreTests/SIWCBridgeTests.swift
- Modify: Sources/CCRouterCore/AcceptanceInferenceGuard.swift
- Create: Tests/CCRouterCoreTests/Fixtures/claude-code-2.1.294-advisor-tools.json
**Expected outcome:** Tests never write production Replay; safe diagnostics identify unsupported declarations.
**Steps:** Inject temporary replay stores; capture only declaration shape; retain stock installed-client schemas.
**Verify:**
Run: `swift test --scratch-path /tmp/ClaudexSwiftTest --disable-sandbox --filter 'SIWCBridge|AcceptanceInferenceGuard'`
Expected: green with fake credentials and temporary stores.

### Task 2: Execute Advisor while preserving the outer agent loop
**Depends on:** Task 1
**Files:**
- Modify: Sources/CCRouterCore/SIWCBridge.swift
- Create: Sources/CCRouterCore/SIWCAdvisor.swift
- Modify: Tests/CCRouterCoreTests/SIWCBridgeTests.swift
**Expected outcome:** Advisor runs only when requested by the executor; actual plaintext results are visible; Claude owns Read and other local tools.
**Steps:** Validate all supported native declaration fields, reject unsupported semantics explicitly. Use explicitly configured configuration.advisorRoute model and effort; never raise effort or inherit executor effort. Pin both routes on client-tool continuation. Add a serial event transformer: forward executor text/client tools immediately, intercept advisor function, run tool-free review, emit server blocks, append raw function result, continue executor only when no client tool result is outstanding. Honor declared max_uses; reject max_tokens explicitly because SIWC rejects max_output_tokens; never add an implicit cap. Preserve raw executor reasoning and advice in replay; verify exact continuation prefix and reject orphaned server result. Cancel every child transport on outer cancellation; do not retry. Include all inference token usage. Reject native caching TTL and cache_control explicitly because Responses cannot represent them. Accept defer_loading as a declaration hint; infer only on an explicit Advisor invocation.
**Verify:**
Run: `swift test --scratch-path /tmp/ClaudexSwiftTest --disable-sandbox --filter 'SIWC|Streaming'`
Expected: Advisor-only, mixed Advisor/client tools, max_uses, malformed declarations, cancellation, replay, usage and error fixtures pass.

### Task 3: Validate actual client and clean obsolete implementations
**Depends on:** Task 2
**Files:**
- Modify: README.md
- Modify: CLAUDE.md
- Modify: docs/06-plans/2026-10-08-siwc-validation.md
- Remove only verified obsolete tracked scripts/implementations after consumer audit; preserve useful coverage on shipping bridge.
**Expected outcome:** Installed Claude executes Read, submits result and answers; intended instance alone serves 4317; obsolete private-backend implementations are removed without backups.
**Steps:** Offline actual Claude loopback fixtures with fake local auth and isolated config; inspect unchanged acceptance ledger before any live request. Use existing Luna/low route and minimal serial real Read calls. Keep Activity trace isolated; never reset ledger or read credentials into tests. Verify build and final diff/status; no push or commit.
**Verify:**
Run: `swift test --scratch-path /tmp/ClaudexSwiftTest --disable-sandbox`; `xcodebuild -project Claudex.xcodeproj -scheme Claudex -destination 'platform=macOS' -derivedDataPath /tmp/ClaudexGoalXcode CODE_SIGNING_ALLOWED=NO build`
Expected: full suite/build green and recorded real Read completion.

## Decisions
**Chosen:** User: “新增 Codex 顾问推理，保留 Advisor 的可见行为（扩大现有架构）”. Execution is authorized by the active finish goal. The user subsequently selected a compact Advisor section in Account & model with Model and Effort. No account permissions change.

User constraint: “Keep Advisor with its own explicitly configured model and effort. Do not automatically raise effort.”

Plan verified: .claude/reviews/plan-verifier-advisor-compatibility-20261008.md; zero blockers. Advisor routing advisory superseded by this explicit user constraint.

## Latest steering
User: “Stop live retries. The upstream rejects ‘system messages are not allowed’; mid-conversation system text is currently encoded as input role: system. Verify and fix the supported instruction mapping offline, preserving semantics. The acceptance ledger is 7/8; do not reset it. Report the minimal additional test budget needed afterward.” Offline red/green fixtures established that mid-conversation text must remain in position as a developer message; top-level system remains instructions.

User later authorized: “Raise the limit to 9, retain count 7, and run exactly two Read/continuation requests on Luna / low / Standard. No additional retries.” Installed Claude Code 2.1.294 completed Read → actual local result → final READ_OK in exactly two new requests. Ledger 9/9, gateway paused, no further inference authorized.

User corrected the UI scope to a compact live status and traffic panel, preserving useful read-only operational information. Account, routing, Advisor and advanced forms remain in Settings. Eight native light/dark status fixtures and the actual paused popover were rendered and inspected; both shortcuts and Start/Pause were exercised in the shipping app. Existing SIWC telemetry does not supply request trend timestamps, token/Advisor throughput or network bytes; unavailable measurements remain explicitly unavailable. See the validation record for evidence and limitations.

## Follow-up: actual traffic counters and bottom-panel refinement
User requested checking their successful session logs, preserving the top half, removing Recent log from the bottom, and correcting all-zero counters. Their Siphon transcript and saved gateway replay confirm Advisor → final response on independently configured Luna/low routes. The earlier telemetry-unavailable UI did not fulfill the requested operational counters. SIWCTraffic now measures the shipping path directly, separates Claude requests from model calls, attributes Advisor/provider usage, persists safe metadata, counts gateway failures once and excludes cancellations. The bottom shows Requests/Tokens/Errors, a short model-call/Advisor summary, and shortcuts. Obsolete log-based trend tests were replaced by equivalent window/expiry tests against the actual recorder. Final verification: 330 core tests, 30 macOS tests, 63 offline smoke tests, macOS build; native eight-state light/dark renders and actual running popover inspected. No further live model calls.
