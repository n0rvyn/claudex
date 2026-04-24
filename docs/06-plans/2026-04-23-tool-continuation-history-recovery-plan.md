---
type: plan
status: active
tags: [anthropic-bridge, tool-continuation, history-recovery, agent-loop]
refs:
  - docs/06-plans/2026-04-23-tool-continuation-preflight-plan.md
  - docs/scheme3/01-validated-baseline.md
  - docs/scheme3/03-anthropic-edge.md
---

# Tool Continuation History Recovery Plan

**Goal:** Fix the real Claude Code agent-loop breakage where continuation requests carrying full history mix old completed `tool_result` blocks into the current pending turn, and make the gateway recoverable when in-memory pending state is missing or stale.

**Architecture:** Move tool-continuation truth from `pendingToolTurns` alone to a dual-source model: the Anthropic request history is the authoritative source for "which `tool_result` blocks belong to the active continuation", while `pendingToolTurns` becomes a cache for route continuity, stored tools, and fast-path fingerprint checks. Every request with `tool_result` is analyzed as a trailing continuation slice; accepted continuations use only the active slice's `tool_result` blocks, while missing/stale pending state is reconstructed from history instead of hard-failing whenever the request already contains the needed replay context.

**Tech Stack:** Swift 6 actor isolation in `AnthropicBridge`, Foundation JSON decoding, typed IR (`IRMessage`, `IRBlock`), existing `/responses` codecs, Swift Testing (`@Test`, `#expect`), and one real Claude Code runtime validation via `co`.

**Design doc:** none; this plan supersedes the narrower fail-closed approach in `docs/06-plans/2026-04-23-tool-continuation-preflight-plan.md` using validated trace evidence from the real session `a6164dc3-295e-4a8e-b178-a7207caa4ff1`.

**Design analysis:** none

**Crystal file:** none

**Threat model:** included

---

## Threat Model

### Attack surface

- Anthropic continuation requests are client-controlled and may contain a full multi-turn history with many old `tool_result` blocks. If the bridge scans the whole history instead of the active continuation slice, it can construct an invalid `/responses` payload with mismatched `function_call` and `function_call_output`.
- `pendingToolTurns` is process-local actor memory. Daemon restart, TTL eviction, or prior stream failure can remove the cached pending turn even while Claude Code still holds a valid continuation in request history.
- A stale cache entry can be more dangerous than no cache entry if the bridge trusts it over the current request history and routes a fresh turn into the wrong continuation branch.

### Failure modes

- If request history proves an active continuation, the bridge must use only that slice's `tool_result` blocks. Old completed `tool_result` history must not be forwarded as current `function_call_output`.
- If request history proves a valid continuation but the cache is missing, the bridge must recover from history and continue, not fail with `no pending tool turn`.
- If request history does not prove a valid continuation and the request still contains `tool_result`, the bridge must fail closed with one buffered `400 invalid_request_error` JSON response before any SSE body is created.
- Stream aborts during an accepted continuation must not blindly delete the previous pending entry; otherwise a retryable transport failure turns into a permanent `no pending tool turn` error.

### Resource lifecycle

- The new history analyzer is pure and allocates only in-memory IR slices.
- `PendingToolTurn` stays actor-owned. Success-path completion and TTL eviction remain the long-term cleanup mechanisms.
- On accepted continuation failures, old pending state is preserved unless the current request history proves it is stale and superseded.
- No new sockets or temp files are introduced by the runtime code path. The only runtime side effects added are trace rows.

### Input validation requirements

- `tool_result.tool_use_id` values are accepted only if they belong to the trailing continuation slice derived from request history.
- Recovered continuations without cache support require a usable tool surface. If request history proves a continuation but `request.tools` is absent or empty, the bridge must reject rather than silently continue with an empty tool set.
- Stale pending clearing requires concrete history evidence; the bridge must not drop cached pending state based on session id alone.

## Acceptance Criteria

- A continuation request that contains old completed `tool_result` history plus one current `tool_result` forwards only the current turn's `function_call_output` items upstream.
- A continuation request with no in-memory pending cache but with a reconstructable trailing assistant `tool_use` + user `tool_result` slice succeeds locally and reaches `/responses`.
- A same-session fresh request after a legitimately completed prior tool round does not get trapped by stale cached pending state.
- A same-session fresh request that truly arrives while a pending tool turn is still unresolved still returns a local buffered `400 invalid_request_error`.
- Stream abort during an accepted continuation preserves enough state for immediate retry; it no longer converts the very next retry into `no pending tool turn` by deletion alone.
- The real `co` path no longer produces `stream_aborted` followed by `no pending tool turn for tool_result continuation` for the reproduced session shape.

<!-- section: task-1 keywords: ToolContinuationHistory, AnthropicBridge, IRMessage, tool_result -->
### Task 1: Add a pure history analyzer for active tool continuations

**Files:**
- Create: `Sources/CCRouterCore/ToolContinuationHistory.swift`
- Test: `Tests/CCRouterCoreTests/ToolContinuationHistoryTests.swift`

**Data flow:** Anthropic `messages[]` -> `IRMessage[]` -> trailing continuation slice -> active `replayIR` + active `toolResultIR` + active call ids -> bridge reconciliation

**Quality markers:** the analyzer never scans "all `tool_result` in the whole request" as the current continuation; it can distinguish:
- no active continuation
- orphaned trailing `tool_result`
- valid active continuation
- resolved historical tool rounds that must stay in history but not re-enter the active continuation payload

**Steps:**
1. Create a pure helper that analyzes `requestIR` and returns a typed result, for example:
   - `activeContinuation: ContinuationSlice?`
   - `trailingToolResultIDs: [String]`
   - `containsAnyToolResultHistory: Bool`
   - `historyShowsResolvedTurns: Bool`
   - a cached-pending relation helper for a given cached call-id set, e.g. `matchesActiveTail / resolvedInHistory / absentFromTail`
2. Implement backward tail analysis instead of whole-history flattening:
   - walk backward from the end of `requestIR`
   - collect the trailing user-side `tool_result` blocks that belong to the current request tail
   - stop at the nearest preceding assistant message
   - collect only that assistant message's `.thinking` and `.toolUse` blocks as the candidate replay slice
   - accept the slice only when trailing `tool_result.tool_use_id` values are a non-empty subset of that assistant replay slice's `tool_use` ids
3. Explicitly reject false positives:
   - old completed tool rounds earlier in history do not become the active continuation slice
   - assistant messages with no `tool_use` do not create a continuation candidate
   - trailing `tool_result` without a matching immediate preceding assistant `tool_use` becomes orphaned/invalid
4. Add unit tests that lock the real bug shape:
   - old completed tool round + later fresh tool round + current continuation returns only the current call ids
   - multiple current `tool_result` blocks in one continuation are preserved in order
   - orphaned trailing `tool_result` returns no active continuation
   - fully resolved prior tool round followed by a fresh user text turn returns no active continuation

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ToolContinuationHistoryTests`
Expected: all history-analyzer cases pass, including the "old and current tool_result in one request history" regression.
<!-- /section -->

<!-- section: task-2 keywords: AnthropicBridge, pendingToolTurns, history-recovery, stream-abort -->
### Task 2: Rebuild `AnthropicBridge` continuation handling around history truth and cache reconciliation

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:44-142`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:173-308`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:325-380`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:1017-1042`

**Replaces:** the current continuation path that derives `toolResultInput` from `requestIR.flatMap(\\.content)` and the current no-pending fail-closed behavior from `2026-04-23-tool-continuation-preflight-plan.md`

**Data flow:** request history analysis -> pending/cache reconciliation -> continuation context -> `/responses` payload -> stream result -> pending preservation or success-path state transition

**Quality markers:** pending state is no longer the only source of truth; accepted continuation retries do not lose state on transport abort; stale cache can be cleared when current request history proves it is obsolete.

**Steps:**
1. Replace the current whole-history continuation extraction in `prepareTurn`:
   - remove `requestIR.flatMap(\\.content)` as the source of current `toolResultInput`
   - call the new history analyzer and derive `activeToolResultIR`, `activeToolResultIDs`, `activeReplayIR`, and `activeCallIDs` from it
2. Implement an explicit reconciliation matrix:
   - if history proves an active continuation and pending cache exists with the same call-id set, use pending route/tools/fingerprint as the fast path
   - if history proves an active continuation and pending cache is missing, recover from history using `request.tools` + current route resolution; reject only when the request omitted tools and no safe recovery context exists
   - if history proves an active continuation and pending cache exists but disagrees on call ids, trust history, clear the stale cached entry, and continue only if `request.tools` provides a fresh tool surface
   - if history proves no active continuation and the request contains trailing `tool_result`, reject as orphaned/invalid
   - if history proves no active continuation and pending cache exists, distinguish "stale cached pending" from "real unresolved pending"; only the latter stays fail-closed
3. Change trace semantics so diagnosis reflects the real branch taken:
   - add a continuation resolution source such as `pending_cache_match`, `history_recovered`, `pending_cache_stale_cleared`, `preflight_rejected`
   - log both `active_tool_result_ids` and `active_replay_call_ids`
   - log stale-cache healing explicitly when the request history overrides the actor cache
4. Preserve retryability on stream abort without leaving corrupted state behind:
   - remove the unconditional `removePending(sessionID:)` from the generic stream error catch
   - thread an explicit "state mutation committed" result through `runPreparedTurn` / `handleOutputBlocks` so the catch path knows whether this request only read cached pending, cleared stale cache, or stored a brand-new pending entry
   - keep or clear pending state based on committed mutation state, not on the fact that an upstream error happened
   - ensure a recovered continuation with no prior cache does not accidentally delete unrelated state, and ensure a later-stage failure cannot leave a half-updated pending entry behind
5. Keep existing continuity guarantees on the accepted path:
   - matching pending cache still preserves route continuity across the turn
   - matching pending cache still enforces tool-contract fingerprint checks
   - recovered continuation without cache uses current `request.tools` as the authoritative tool surface for the next upstream pass

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests/continuationIgnoresHistoricalToolResultsAndSendsOnlyActiveOutputs`
Expected: the outgoing continuation payload contains only the active turn's `function_call` and `function_call_output` ids.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests/historyRecoveredContinuationSucceedsWithoutPendingCache`
Expected: a reconstructable continuation succeeds even when no pending cache exists.
<!-- /section -->

<!-- section: task-3 keywords: BridgeRegressionTests, StreamingBridgeIntegrationTests, stale-pending, retry -->
### Task 3: Lock the real bug and the retry semantics with bridge-level regressions

**Files:**
- Modify: `Tests/CCRouterCoreTests/BridgeRegressionTests.swift`
- Modify: `Tests/CCRouterCoreTests/StreamingBridgeIntegrationTests.swift`
- Modify: `Tests/CCRouterCoreTests/ModelRoutingBridgeIntegrationTests.swift`

**User interaction:** Claude Code either gets a correct streaming continuation or a local JSON error before streaming starts; it no longer sees a wrong continuation start, upstream 400 mid-stream, and then a later `no pending tool turn` on retry.

**Steps:**
1. Add a regression that reproduces the validated real trace shape:
   - request history includes one completed older tool round and one current pending tool round
   - the current continuation request includes both the old completed `tool_result` history and the current trailing `tool_result`
   - assert the second upstream payload uses only the current active call id(s)
2. Add a no-pending recovery regression:
   - do not seed pending cache
   - send a reconstructable continuation request with assistant `tool_use` history + trailing user `tool_result`
   - assert buffered success path reaches upstream and streams normally
3. Add a stale-pending-clearing regression:
   - seed a stale pending cache entry
   - send a fresh request whose history proves the earlier tool round is already resolved
   - assert the bridge clears the stale cache and treats the request as an initial turn instead of returning `pending tool turn requires matching tool_result continuation`
4. Replace the current stream-error expectation:
   - update `StreamingBridgeIntegrationTests` so stream abort during an accepted continuation preserves enough state for retry
   - add a two-attempt test where the first continuation aborts upstream and the second retry succeeds under the same session
5. Re-run route/tool continuity coverage so the full fix does not regress the previously-correct fast path.

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests`
Expected: stale-history, stale-cache, orphaned, and recovered-continuation regressions all pass.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter StreamingBridgeIntegrationTests`
Expected: accepted continuation stream-abort tests prove retry no longer degrades into `no pending tool turn`.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ModelRoutingBridgeIntegrationTests/pendingToolTurnSecondSegmentKeepsSameRoute`
Expected: matching cache still preserves the original route on the accepted continuation fast path.
<!-- /section -->

<!-- section: task-4 keywords: changelog, co, runtime-validation, trace -->
### Task 4: Update runtime validation notes and verify the real `co` path

**Files:**
- Create: `docs/07-changelog/2026-04-23-tool-continuation-history-recovery.md`
- Modify: `docs/06-plans/execution-report.md`

**Expected values:** the reproduced session shape must no longer show:
- `stream_aborted` with upstream `No tool call found for function call output`
- later `continuation_preflight_rejected` with `no pending tool turn for tool_result continuation`

**Steps:**
1. Document the root-cause shift in the changelog:
   - previous fail-closed preflight fix blocked orphaned continuations but still treated cache as truth
   - the shipped fix now treats request history as truth and cache as recoverable state
2. Record the validated reproduction evidence in the execution report:
   - session shape with old completed `tool_result` history plus current continuation
   - cache-missing/stale-cache recovery behavior
   - retry behavior after a continuation stream abort
3. Perform the real-path runtime check on the actual CLI route:
   - ensure `curl -sS http://127.0.0.1:4317/health` reports `daemonState = running`
   - launch `co`
   - reproduce the interactive tool path that previously failed, starting with `/domain-intel:intel 来个简讯`
   - after the run, inspect `/health` or the trace file and confirm the latest session does not contain `stream_aborted` or `continuation_preflight_rejected`

**Verify:**
Run: `curl -sS http://127.0.0.1:4317/health`
Expected: daemon is running and recent trace diagnostics are readable.
⚠️ 需本机交互验证：
1. Run `co`
2. In Claude Code, send `/domain-intel:intel 来个简讯`
3. After the run, inspect `/health` or `trace.jsonl`
Expected: the latest session completes without `stream_aborted` and without `no pending tool turn for tool_result continuation`.
Run: `curl -sS http://127.0.0.1:4317/health | rg -n "stream_aborted|continuation_preflight_rejected|recentTraceLines"`
Expected: health JSON is returned; after the interactive repro, the latest session does not add new `stream_aborted` or `continuation_preflight_rejected` rows.
<!-- /section -->

<!-- section: task-5 keywords: swift-build, swift-test, full-verification -->
### Task 5: Full verification

**Files:**
- Verify against: `Package.swift:1-58`

**Steps:**
1. Run the full Swift package build.
2. Run the full Swift package test suite.
3. Complete the real-path `co` validation from Task 4 before claiming the fix is done.

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild`
Expected: the package builds successfully.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest`
Expected: all tests pass with zero failures.
<!-- /section -->

## Decisions
None.

[自检-表面] 本次任务最容易违反哪条规则？
答：先验证再结论；因为这类问题最容易在 unit test 绿了之后，继续拿旧的非交互 probe 或 mock 推断交互 Agent Loop 已修好。

[自检-隐蔽] 本次任务中，哪个“看起来已完成”的步骤最容易实际未生效？
答：history recovery。只要代码还在任何位置从 `requestIR.flatMap(\\.content)` 提取当前 continuation 的 `tool_result`，旧历史 `tool_result` 混入 bug 就没有真正消失。

[自检-造轮子] 本次方案中是否有手写逻辑在解决平台 API 已覆盖的问题？
答：没有；问题在本地桥接状态机与 Anthropic request history 的对应关系，现有平台 API 不会替我们恢复这个语义。

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-04-23
- **Pass 1:** 补齐了 cache-truth 与 history-truth 的边界，明确 stream abort 不能再做无条件 `removePending(sessionID:)`。
- **Pass 2:** 复核了计划中的文件、测试入口、`docs/07-changelog` 目录和 `Package.swift` 都在当前仓库存在；无失效路径。
