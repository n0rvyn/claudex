---
type: plan
status: active
tags: [anthropic-bridge, tool-continuation, preflight, streaming]
refs:
  - docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
  - docs/06-plans/2026-04-22-phase1-streaming-ir-plan.md
  - docs/11-crystals/2026-04-22-phase-3-protocol-completeness-crystal.md
---

# Tool Continuation Preflight Validation Plan

**Goal:** Eliminate the continuation-ownership gap that lets a wrong `tool_result` reach upstream after the SSE response has already started, so Claude Code sees a clean local `400` instead of an interrupted-looking agent loop.

**Architecture:** Keep the verified `session_id -> single active pending tool turn` model. Move continuation ownership checks fully into `AnthropicBridge.prepareTurn`: extract incoming `tool_result.tool_use_id` values from the Anthropic request, compare them against the pending turn's replayed `tool_use` ids, and fail closed before any streaming response is created. Remove the current same-session "fresh fallback while preserving pending" branch; if a pending tool turn exists, the next request must be its matching continuation or it is rejected locally.

**Tech Stack:** Swift 6 actor isolation in `AnthropicBridge`, Foundation JSON decoding, existing IR codecs (`IRAnthropicCodec`, `IRResponsesCodec`), Swift Testing (`@Test`, `#expect`).

**Design doc:** `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md` §3c and `docs/06-plans/2026-04-22-phase1-streaming-ir-plan.md` §§540-541 (current fallback behavior to replace).

**Design analysis:** none

**Crystal file:** `docs/11-crystals/2026-04-22-phase-3-protocol-completeness-crystal.md`

**Threat model:** included

---

## Threat Model

### Attack surface

- Incoming Anthropic continuation requests carry client-controlled `tool_result.tool_use_id` values. If the gateway accepts ids that do not belong to the active pending turn, it can construct an invalid `/responses` payload with mismatched `function_call` and `function_call_output`.
- Same-session requests that arrive while a pending tool turn exists can currently take the fallback fresh-turn path and mutate or overwrite pending state. That creates protocol drift inside one Claude Code session.
- Trace output is the only durable evidence for these failures. If rejection reasons and compared ids are not logged, production diagnosis falls back to inference.

### Failure modes

- If a pending turn exists and the request is not its matching continuation, the gateway must fail closed with one buffered `400 invalid_request_error` JSON response. It must not open SSE and must not delete the pending entry.
- If no pending turn exists but the request contains `tool_result`, the gateway must fail closed with one buffered `400 invalid_request_error` JSON response. It must not fabricate a fresh turn from invalid continuation input.
- Valid continuations still reuse the stored route and stored tool contract. This plan does not change streaming semantics for accepted turns.

### Resource lifecycle

- `PendingToolTurn` entries continue to live only in actor memory and are still cleaned by success-path removal or TTL eviction. New preflight rejects leave the entry untouched so the correct continuation can still arrive later.
- No temp files, sockets, or child processes are added.
- Trace rows added by this plan are append-only and follow the existing logger lifecycle.

## Acceptance Criteria

- A request with `tool_result.tool_use_id` that does not belong to the active pending turn returns a local buffered `400 invalid_request_error` before any `.stream` response is created.
- A same-session fresh request received while a pending tool turn exists returns a local buffered `400 invalid_request_error`, and the original pending turn remains available.
- A request with `tool_result` but no pending turn returns a local buffered `400 invalid_request_error`.
- The valid Bash two-round continuation path still streams successfully and still sends only `reasoning + function_call + function_call_output` upstream on round two.
- Route continuity and stored tool contract reuse regressions remain green.

<!-- section: task-1 keywords: AnthropicBridge, preflight, tool_result, pending -->
### Task 1: Replace fallback continuation handling with authoritative preflight validation

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:44-142`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:173-308`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:351-360`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:934-980`

**Design ref:** `docs/scheme3/03-anthropic-edge.md` §§4-6 and `docs/scheme3/01-validated-baseline.md` §3.13

**Replaces:** the current `readPending(sessionID:)` branch that falls back to a fresh initial turn when `toolResultInput.isEmpty` at `AnthropicBridge.swift:192-217`

**Data flow:** Anthropic request -> `requestIR` -> incoming `tool_result.tool_use_id` set -> active pending turn `replayIR` -> pending `tool_use` id set -> local preflight reject or continuation payload build

**Quality markers:** no `.stream` response is produced on reject; no invalid continuation reaches `responsesClient.streamEvents`; rejected requests preserve pending state; trace rows include both incoming tool-result ids and pending replay ids.

**Steps:**
1. Replace `PreparedTurnResult.response(HTTPResponse)` with a typed preflight-rejection payload that carries the `HTTPResponse`, rejection message, and any trace fields needed for `handleMessages` to log the right failure instead of the current hardcoded `"tool contract changed during pending tool turn"`.
2. In `prepareTurn`, extract incoming continuation ids from decoded IR before building the upstream payload:
   - collect every `.toolResult(toolUseID: ...)` from `requestIR`
   - collect every pending replay `.toolUse(id: ...)` from `pending.replayIR`
   - keep the existing tool-contract fingerprint check, but only after continuation ownership is known to be valid
3. Change pending-session semantics to fail closed:
   - if a pending turn exists and the request has no `tool_result`, return `anthropicError(statusCode: 400, errorType: "invalid_request_error", message: "pending tool turn requires matching tool_result continuation")`
   - if a pending turn exists and any incoming `tool_use_id` is absent from the pending replay id set, return `anthropicError(statusCode: 400, errorType: "invalid_request_error", message: "tool_result does not match current pending tool turn")`
   - if a pending turn exists and `request.tools` is absent or empty, reuse `pending.convertedTools` exactly as today
   - if a pending turn exists and `request.tools` is non-empty, fingerprint the converted tools and reject on drift with the existing `"tool contract changed during pending tool turn"` error
4. Change no-pending semantics to fail closed:
   - if no pending turn exists and the request contains any `tool_result`, return `anthropicError(statusCode: 400, errorType: "invalid_request_error", message: "no pending tool turn for tool_result continuation")`
   - remove `preservedPendingOnFreshFallback` from `PreparedTurn`, `handleOutputBlocks`, and the stream-abort cleanup path; once a pending tool turn exists, this bridge no longer treats a same-session fresh request as a valid new turn
5. Extend trace output in `AnthropicBridge.swift`:
   - add `incoming_tool_result_ids` and `pending_replay_call_ids` to the existing `responses_out_continuation` row
   - add a new deterministic preflight rejection row before returning a local `400`, for example `stage: "continuation_preflight_rejected"` plus `reason`, `incoming_tool_result_ids`, and `pending_replay_call_ids`

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests/bashToolTurnTwoRoundsStillClosesViaStreaming`
Expected: the verified two-round Bash continuation still streams and finishes with `stop_reason == "end_turn"`.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests/continuationToolContractMismatchReturns400BeforeStreaming`
Expected: the existing contract-drift preflight reject still returns buffered `400` JSON and preserves the pending entry.
<!-- /section -->

<!-- section: task-2 keywords: BridgeRegressionTests, continuation, stale-session, tool-use-id -->
### Task 2: Add regression coverage for stale and out-of-order continuation requests

**Files:**
- Modify: `Tests/CCRouterCoreTests/BridgeRegressionTests.swift:34-300`
- Test: `Tests/CCRouterCoreTests/ModelRoutingBridgeIntegrationTests.swift`

**Design ref:** `docs/scheme3/01-validated-baseline.md` §3.13 and `docs/scheme3/03-anthropic-edge.md` §5

**User interaction:** Claude Code either gets a normal streaming tool continuation or an immediate JSON `400`; it no longer receives a started SSE stream that later turns into `[upstream error: ...]` for this class of mistake.

**Steps:**
1. Extend the test helpers in `BridgeRegressionTests.swift` so a test can build:
   - a request with an arbitrary `tool_use_id`
   - a request with `tool_result` and no prior pending turn
   - a same-session fresh request that intentionally omits `tool_result`
   - a request that omits `tools` on continuation so stored-contract reuse still stays covered
2. Add a regression test for stale/unknown continuation ownership:
   - round 1 creates a pending Bash tool turn
   - round 2 sends `tool_result` with a different `tool_use_id`
   - assert `statusCode == 400`
   - assert `response.body` is `.data`, not `.stream`
   - decode `AnthropicErrorEnvelope` and assert `error.message == "tool_result does not match current pending tool turn"`
   - assert `await bridge.pendingToolTurnsCount() == 1`
   - assert `await mock.capturedRequests.count == 1` so no invalid continuation was sent upstream
3. Add a regression test for same-session out-of-order fresh requests:
   - round 1 creates a pending Bash tool turn
   - round 2 sends another same-session request without `tool_result`
   - assert buffered `400` JSON with `error.message == "pending tool turn requires matching tool_result continuation"`
   - assert the original pending entry remains and `mock.capturedRequests.count` did not increase
4. Add a regression test for orphaned `tool_result`:
   - send a request with `tool_result` but no stored pending turn
   - assert buffered `400` JSON with `error.message == "no pending tool turn for tool_result continuation"`
   - assert `mock.capturedRequests.count == 0`
5. Re-run the existing valid continuation coverage and one routing regression:
   - keep `bashToolTurnTwoRoundsStillClosesViaStreaming` green
   - run `ModelRoutingBridgeIntegrationTests/pendingToolTurnSecondSegmentKeepsSameRoute` to prove route continuity and stored tool reuse still hold after the preflight rewrite

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests`
Expected: existing Bash/advisor regressions plus the new stale/out-of-order continuation cases all pass.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ModelRoutingBridgeIntegrationTests/pendingToolTurnSecondSegmentKeepsSameRoute`
Expected: the continuation still uses the stored route and stored tool definition on the accepted path.
<!-- /section -->

<!-- section: task-3 keywords: swift-build, swift-test, full-verification -->
### Task 3: Full verification

**Files:**
- Verify against: `Package.swift:1-58`

**Steps:**
1. Run the full Swift package build.
2. Run the full Swift package test suite.
3. If any failures appear, stop execution and report the blocking failure against the plan instead of silently narrowing scope.

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild`
Expected: the package builds successfully.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest`
Expected: all tests pass with zero failures.
<!-- /section -->

[自检-表面] 本次任务最容易违反哪条规则？
答：证据先于声称；因为 continuation 问题很容易只盯上游 `400` 文本，而忽略本地是否真的在开流前挡住了错误请求。

[自检-隐蔽] 本次任务中，哪个“看起来已完成”的步骤最容易实际未生效？
答：本地 `400` preflight 拒绝；如果只断言 `statusCode == 400`，却没断言 `response.body` 是 `.data` 且 `mock.capturedRequests.count` 没增加，错误请求仍然可能已经打到上游。

[自检-造轮子] 本次方案中是否有手写逻辑在解决平台 API 已覆盖的问题？
答：没有；这次改动是网关协议状态校验，已查当前仓库现有 `IRAnthropicCodec`、`IRResponsesCodec` 和 `AnthropicBridge` 路径，没有现成平台 API 可以替代。

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-04-23
- **Pass 1:** 结构校验，补齐了 frontmatter `refs` 与 `Design doc` 的对应关系。
- **Pass 2:** 已验证计划内现有过滤命令可执行：
  - `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests/bashToolTurnTwoRoundsStillClosesViaStreaming`
  - `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests/continuationToolContractMismatchReturns400BeforeStreaming`
  - `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ModelRoutingBridgeIntegrationTests/pendingToolTurnSecondSegmentKeepsSameRoute`
