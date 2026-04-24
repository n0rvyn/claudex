## Implementation Review Summary
**Status:** complete
**Plan:** docs/06-plans/2026-04-22-phase1-streaming-ir-plan.md
**Design doc:** docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md (Phase 1 section)
**Started:** 2026-04-22-130156

---

## Part 1: Plan-vs-Code Verification

### 1. Deletion Verification

Plan Step 10 (Task 5) lists helpers to delete from `AnthropicBridge.swift`. Grep confirms all deletions:

```
grep -nE 'func finalizeResponse|func buildAnthropicSSE|func makeTextSSE|func makeToolUseSSE|func makeAdvisorSSE|func convertContentBlocks|func convertMessages|func stringifyToolResultContent|func outputItemsInOrder|func replayItemsForContinuation|func finalUsage|func buildInitialPayload|func buildContinuationPayload|func functionCallOutputs' Sources/CCRouterCore/AnthropicBridge.swift
→ (no match)

grep -nE "sse\(event|ResponsesContentPart" Sources/CCRouterCore/AnthropicBridge.swift
→ (no match)
```

All 14 removal targets from plan Step 10 are gone. [C:95] ✅

### 2. Struct/Interface Field Comparison

**IRBlock** (IRBlock.swift:6-14) — 7 cases match plan exactly:
- `.text(String)`, `.image(data:mediaType:)`, `.toolUse(id:name:input:)`, `.toolResult(toolUseID:content:)`, `.thinking(encryptedContent:summary:)`, `.serverToolUse(id:name:input:)`, `.advisorToolResult(toolUseID:text:)`. [C:95] ✅

**IRMessage** (IRMessage.swift:7-15) — `role: String` + `content: [IRBlock]`. Matches plan. [C:95] ✅

**AnthropicSSEEncoder** (AnthropicSSEEncoder.swift:14-218):
- `BlockKind` enum has 5 cases (plan specified 5: text, toolUse, serverToolUse, advisorToolResult, thinking) ✅
- `StopReasonHint` enum has 3 cases (endTurn, toolUse, advisor) ✅
- All 9 public methods present and match plan signatures: `startMessage`, `emitTextDelta`, `emitToolUseBlock`, `emitServerToolUseBlock`, `emitAdvisorToolResultBlock`, `emitThinkingBlock`, `closeOpenBlock`, `updateFinalOutputTokens`, `finish`. [C:95] ✅

**PendingToolTurn** (AnthropicBridge.swift:783-788) — `replayIR: [IRBlock]` as required by S6. [C:95] ✅

**HTTPResponse.Body** (LocalHTTPServer.swift:20-23) — `case data(Data)` + `case stream(...)`. [C:95] ✅

### 3. UI Element Verification

Not applicable — Phase 1 has no UI changes.

### 4-5. "No matches" Red Flag & Integration Point Verification

All plan-specified verify greps pass (Task 3/4/5 verification section):
- `URLSession...bytes(for:)` — ResponsesClient.swift:45 ✅
- `AsyncThrowingStream<JSONObject` — ResponsesClient.swift:42, 82 ✅
- `continuation.onTermination` — ResponsesClient.swift:108 ✅
- `for try await byte in bytes` — ResponsesClient.swift:55 ✅
- `Transfer-Encoding: chunked` — LocalHTTPServer.swift:350 ✅
- `noDelay` — LocalHTTPServer.swift:151 ✅
- `streamEvents|AnthropicSSEEncoder` count in AnthropicBridge = 9 (plan ≥3) ✅
- `replayIR:|.replayIR` count = 4 (plan ≥3) ✅
- `encodeReplayBlocks|encodeToolResultOutputs` count = 3 (plan ≥2) ✅

[C:95] All pass.

### 6. Never Trust Existing Code

Read the 4 key source files (IR/* + ResponsesClient + LocalHTTPServer + AnthropicBridge + AnthropicSSEEncoder). File-by-file spot checks confirm behavior matches the plan (per-event emit, chunked writer, error catch wiring). [C:90] ✅

### 7. Unauthorized Deferral Detection

**❌ Critical Gap [C:90]: Task 8 — two plan-specified tests silently omitted via pivot**

Plan Task 8 Step 2 lists 7 tests; two of them explicitly cover the HTTP response status / error-body drain path, which corresponds to a plan-verifier-approved gap-fix (`S1 #5 修订` + `S3 Gap #1 修订`):

- `non200StatusThrowsResponsesHTTPError` — plan line 1040
- `errorBodyReadWithoutAssumingUTF8Lines` — plan line 1041

Actual `ResponsesClientStreamingTests.swift` (7 @Test) replaces these two with `emptyDataLineIsIgnored` + `upstreamErrorPropagatesToStream`. Grep confirms zero coverage of these paths anywhere in the test suite:

```
grep -rnE "statusCode.*[45][0-9][0-9]|ResponsesHTTPError|HTTPError" Tests/CCRouterCoreTests/
→ (no match)
```

The implementer's claim in session brief (*"HTTP status handling (non-200 error body raw-byte drain) + URL-level cancellation are covered by integration tests in StreamingBridgeIntegrationTests"*) is **falsified by grep**: no integration test exercises a non-200 upstream response either.

Untested code: `ResponsesClient.swift:51-65` (the raw-byte error body drain — a fix for S1 #5 that addresses real behavior: zstd / non-UTF-8 body handling on 4xx/5xx).

**Severity:** Blocking. The whole purpose of S1 #5 and S3 Gap #1 was to close a latent bug where error bodies would crash via UTF-8 decode, and URL-level cancellation would leak connections. Removing these tests re-opens both gaps without evidence the behavior works.

**Fix Recommendation:** Add the two missing tests. Even if `URLSession.bytes(for:)` is hard to mock directly, the HTTP status path is reachable by:
- Extracting the error-body-drain helper similarly to `parseSSELines` (takes an `AsyncSequence` of `UInt8`), OR
- Using a real local `NWListener` stub that returns a 4xx response (the existing InMemoryBodyWriter + LocalHTTPServer code paths show loopback is feasible), OR
- Using `URLProtocol` for non-200 cases only (URLProtocol DOES cooperate with standard URLSession fetches — only `.bytes(for:)` has the known incompatibility).

Pivot is acceptable for the parse-only branch; but the status-code + error-body branch needs coverage since the plan-verifier cycle-1 explicitly added these fixes.

### 8. Conditional Branch Verification

Plan Step 3 branch A fallback: "if `toolResultInput.isEmpty` → fallback to initial turn but **keep** pendingToolTurns entry." Implementation: AnthropicBridge.swift:175-189 calls `runInitialTurn` without `pendingToolTurns.removeValue`. [C:95] ✅

Plan Step 5 second-pass advisor detection: `advisorEnabled=false` on second pass to avoid loop. Implementation: AnthropicBridge.swift:578 passes `advisorEnabled: false`. [C:95] ✅

### 9. Removal-Replacement Reachability

`finalizeResponse` removed → replaced by `runStreamingTurn + handleOutputBlocks + AnthropicSSEEncoder`. Replacement is reachable: entrypoint at `handleMessages` line 62-75 returns `.stream` response that invokes `runStreamingTurn`. Tests exercise both the `.data` (error path) and `.stream` (success path) branches. [C:90] ✅

### 10. Term Consistency After Rename

Plan renames `replayItems: [JSONValue]` → `replayIR: [IRBlock]`. Grep:
```
grep -nE "replayItems\b" Sources/CCRouterCore/
→ (no match)
```
[C:95] ✅

### 11. ADR Action Completeness

Plan includes a complete Step 10 deletion checklist. All items verified deleted (section 1 above).

### 12. Reverse Regression Reasoning

**Hypothetical regression #1 — Error body crash on upstream 4xx/5xx:**
- User action: Subscription token expires → upstream returns 401 with zstd-compressed body
- Code path: `/v1/messages` → `handleMessages` → try `loadCurrent()` → streamEvents → non-200 branch (ResponsesClient.swift:51-65)
- Failure: `String(data:encoding:.utf8)` returns nil; code handles it via fallback `"<non-utf8 body, N bytes>"` ✅ code is correct
- **Covered by forward check:** ❌ NOT COVERED BY ANY TEST (see §7). Correct code, unverified at runtime. **Action Required:** add tests.

**Hypothetical regression #2 — Continuation payload leaks user text to upstream:**
- User action: CLI sends second turn with tool_result + full message history
- Code path: `handleMessages` → continuation branch → `encodeReplayBlocks(pending.replayIR) + encodeToolResultOutputs(requestIR.flatMap(\.content))`
- Failure point: if replayIR filter is wrong, text messages leak back upstream (violates scheme3/09 §4.4 observation)
- **Covered by forward check:** ✅ `BridgeRegressionTests.bashToolTurnTwoRoundsStillClosesViaStreaming` line 230-236 asserts `allowedTypes = {reasoning, function_call, function_call_output}`. Good.

**Hypothetical regression #3 — MitM via SubscriptionSessionLoader thread race:**
- Covered in §13 R9 audit below. Code is production-safe since class has no mutable state, but semantic downgrade (actor→class) is unauthorized.

### 13. Rules Compliance Audit

**R6 (Evidence before claims)**
- Session brief claim: "52/52 Swift Testing tests pass + 2/2 Xcode tests pass + build clean" — verified by swift test run (52/52 ✅) + swift build (clean ✅) + xcodebuild (clean ✅).
- Session brief claim: "HTTP status handling... covered by integration tests" — **falsified** (see §7).

```
[R6 Audit] Completion claims: 2 ✅ verified, 1 ❌ unverified/false
```

**R9 (Fix obstacles, don't bypass)**
- `git diff HEAD -- Sources/CCRouterCore/SubscriptionSession.swift` shows `public actor` → `open class: @unchecked Sendable` + `init(testCredentials:)` backdoor.
- This file is NOT in the Phase 1 plan's target set. Implementer modified production code to enable `MockSessionLoader` to subclass.
- Clean alternative exists (and is the in-plan pattern): introduce a `SubscriptionSessionLoading` protocol like `ResponsesStreamingClient` in Task 6.
- Loss: actor's serial-access semantic removed from production (no current races because class has no mutable state, but future state would not be protected).

```
[R9 Audit] Files edited: 4 source — plan-specified: 3 (AnthropicBridge, LocalHTTPServer, ResponsesClient), unplanned: 1 (SubscriptionSession.swift)
```

**Decision authority** — View modifications: 0. Phase 1 has no UI scope.

### 13.1 Test Completeness Audit

Plan requires 4 new test files with specific @Test methods:

| Test file | Required | Actual @Test | Coverage |
|---|---|---|---|
| IRBlockConversionTests.swift | ≥15 | 19 | All 3 directions covered (A/B/C per plan) ✅ |
| StreamingBridgeIntegrationTests.swift | ≥10 | 10 | All 10 named tests present ✅ |
| BridgeRegressionTests.swift | 2 | 2 | §3.13 + §3.14 both present, S1 #4 filter asserted ✅ |
| ResponsesClientStreamingTests.swift | ≥7 | 7 | 5 parser paths ✅, 2 HTTP status paths ❌ (see §7) |

**Shell/weak test:** `chunkedTransferHeadersExcludeContentLength` (StreamingBridgeIntegrationTests.swift:690-709) asserts only `bodyData == nil` and `headers["Content-Length"] == nil`. Plan specified byte-level inspection of the wire headers after `sendStreamBody` — test does not exercise `sendStreamBody` at all. The filtering logic at `LocalHTTPServer.swift:347-352` is consequently uncovered. Plan has smoke-test deferral clause (line 1112), but the weakness still matters because the smoke test is not part of this phase's automation.

```
[Test Completeness]
- Required tests: 4 files (total plan-listed @Test: 34)
- Files exist: 4
- Non-empty tests: 4
- Core path covered: 3 (IR + bridge integration + regression)
- Shell tests: 1 (chunkedTransferHeadersExcludeContentLength)
- Missing from plan: 2 @Test in Task 8 (non200... + errorBodyReadWithoutAssumingUTF8Lines)
```

---

## Part 2: Design Fidelity Audit

Design doc: `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md` (Phase 1 section).

### 14. Spec Value Comparison (Gap A)

- [A] `AnthropicSSEEncoder.BlockKind` enum cases — design implicit (via emit* method list): 5 cases expected, 5 present. ✅ match
- [A] `processUpstreamStream` handles upstream event types `{response.output_text.delta, response.output_item.done, response.completed}` — matches `docs/scheme3/08 §4.2`. AnthropicBridge.swift:371-418 covers all three. ✅ match
- [A] DP-003=A `Connection: close` — LocalHTTPServer.swift:351 includes `"Connection": "close"`. ✅ match
- [A] DP-004=A "JSONObject only at protocol edges" — 12 call sites in AnthropicBridge (plan threshold ≤10). 10 of 12 are trace log / payload maker / anthropicError (all allowed by plan Quality marker exception). 2 in `convertTools` (preserved helper per Step 10 keep list; also protocol-edge since it builds /responses tools). Spirit-of-DP-004 met; literal count exceeds threshold. See Low-Confidence Appendix.

### 15. Data Flow Connectivity Tracing (Gap B)

- [B] Anthropic JSON → `IRAnthropicCodec.decodeRequestBlocks` → `IRMessage` → `IRResponsesCodec.encodeInputItems` → `/responses` payload. Trace:
  - AnthropicBridge.swift:162 (decodeRequestBlocks) → :286 (encodeInputItems). ✅ connected
- [B] `/responses` SSE event → `IRResponsesCodec.decodeOutputItem` → IR → `AnthropicSSEEncoder.emit*`. Trace:
  - AnthropicBridge.swift:384 (decodeOutputItem) → :396 (emitToolUseBlock) / :404 (emitThinkingBlock). ✅ connected
- [B] Continuation: `pending.replayIR` → `encodeReplayBlocks` → /responses input. Trace:
  - AnthropicBridge.swift:192 (encodeReplayBlocks). ✅ connected
- [B] Error path: catch → encoder.emitTextDelta + finish. Trace:
  - AnthropicBridge.swift:241-256 (continuation branch) + :328-346 (initial branch). ✅ connected

All five new data flows are wired end-to-end. [C:95] ✅

### 16. Old Code Removal Completeness (Gap C)

Per Plan Step 10, 14 helpers marked for deletion. Grep confirms all removed. [C:95] ✅

Dead code leftover: `AnthropicBridge.encodeJSONObjectToString` (line 711-714) is defined but never called. Not in plan's keep list, but harmless (private, no warning). Note only. [C:80]

### 17. Missing Feature Detection (Gap D)

| Design requirement | Code location | Status |
|---|---|---|
| Per-event streaming emit (S3) | processUpstreamStream AnthropicBridge.swift:352-426 | ✅ found |
| URLSession.bytes streaming (S1) | ResponsesClient.swift:45 | ✅ found |
| Chunked transfer (S2) | LocalHTTPServer.swift:337-381 | ✅ found |
| IR layer (S4) | Sources/CCRouterCore/IR/ | ✅ found |
| IR-driven convertContentBlocks (S5) | decodeRequestBlocks + encodeInputItems + encodeToolResultOutputs | ✅ found |
| PendingToolTurn.replayIR (S6) | AnthropicBridge.swift:783-788 | ✅ found |
| First-delta 50ms latency budget | StreamingBridgeIntegrationTests.swift:121 | ✅ test exists |
| Claude-CLI wire-compatible SSE | AnthropicSSEEncoder.swift | ✅ emits correct event/frame types |

All 8 design-specified features present. [C:95] ✅

### 18. Implementation Quality Comparison (Gap E)

- [E] Task 8 pivot — plan specified `URLProtocol`-based HTTP stubbing. Implementation pivoted to `parseSSELines` extraction for parse-path unit testing, citing "Swift 6.2's URLSession.bytes(for:) does not cooperate with URLProtocol". This pivot:
  - IS documented in session-brief disclosure (unlike silent downgrade) — partial R9 alignment
  - HAS a plausible technical rationale (`bytes(for:)` + URLProtocol interop is a known Swift concurrency limitation)
  - But the stated mitigation ("integration tests cover HTTP status + cancellation") is **unsupported** by evidence (§7)
  - Severity: ❌ **silent-degradation-on-coverage** (code is faithful to plan; test coverage is degraded below plan threshold without user sign-off)

- [E] `chunkedTransferHeadersExcludeContentLength` test weaker than plan specified. ⚠️ acknowledged per plan's smoke-deferral, but this was specified as a unit test asserting wire bytes.

- [E] `SubscriptionSessionLoader` actor → open class conversion (see R9 audit). Design specified `public actor`. Code has `open class: @unchecked Sendable`. ❌ silent degradation of production concurrency semantic.

---

## Pre-existing Issues

### Pre-1: SubscriptionSessionLoader actor→class conversion [C:95]

**Change:** `Sources/CCRouterCore/SubscriptionSession.swift` modified outside plan scope. Diff:
- `public actor SubscriptionSessionLoader` → `open class SubscriptionSessionLoader: @unchecked Sendable`
- Added `_testCredentials: SubscriptionCredentials?` storage
- Added `public init(testCredentials:)` backdoor constructor
- Added short-circuit `if let credentials = _testCredentials { return credentials }` at start of `loadCurrent()`

**Origin investigation:**
- `git log --oneline -3 -- Sources/CCRouterCore/SubscriptionSession.swift` shows last commit `c5bb7c9` predates Phase 1. The diff is uncommitted working-tree change → introduced during this Phase 1 session.
- Purpose: enable `MockSessionLoader` (Tests/CCRouterCoreTests/MockResponsesEventStream.swift:435) to subclass and override `loadCurrent()`.

**Impact:**
1. **Production concurrency semantic changed**: actor's serial-access guarantee lost. Current `SubscriptionSessionLoader` has no mutable state (all `private let`), so no immediate race bug — but this is coincidental safety, not structural. Future fields added to the class could silently introduce races.
2. **Plan requirement violation** — Phase 1 plan explicitly does not list SubscriptionSession.swift in any task's Files section. R9: "遇阻修阻不绕路" and "计划明确要求的事项不能偏离". The obstacle was "tests need credential injection"; the plan's in-pattern fix would be a protocol (as done for `ResponsesStreamingClient` in Task 6).
3. **API surface grew publicly** — `init(testCredentials:)` is `public`, so subscribers can now bypass the auth file entirely. This is a test seam leaking into production API.

**Fix Recommendation:**
- Revert `SubscriptionSession.swift` to the pre-phase-1 `public actor` version
- Introduce `SubscriptionSessionLoading` protocol:
  ```swift
  public protocol SubscriptionSessionLoading: Sendable {
      func loadCurrent() async throws -> SubscriptionCredentials
  }
  extension SubscriptionSessionLoader: SubscriptionSessionLoading {}
  ```
- Change `AnthropicBridge.init` parameter type to `any SubscriptionSessionLoading`
- Rewrite `MockSessionLoader` as a plain `struct: SubscriptionSessionLoading` with stored credentials, no subclassing
- Unblocks: tests retain coverage, production retains actor isolation, no public-API test seam

---

## Decisions

### [DP-001] Task 8 missing HTTP status tests (blocking)

**Gap:** Plan Task 8 lists 7 @Test cases; two plan-specified tests (`non200StatusThrowsResponsesHTTPError` and `errorBodyReadWithoutAssumingUTF8Lines`) are missing. Grep confirms no test anywhere in the suite exercises the non-200 status branch or the raw-byte error-body drain at `ResponsesClient.swift:51-65`. These tests were added in plan-verifier cycle 1 specifically to close latent bugs (S1 #5 non-UTF-8 body crash, S3 Gap #1 connection leak on cancellation of error response). Silently dropping them re-opens both gaps.

**Options:**

| | A: Add the missing tests | B: Accept coverage deferral |
|---|---|---|
| Behavior | Plan-specified 2 tests added; coverage intact | Trust the raw-byte + cancellation code works untested; flag as known risk |
| Implementation | ~80 lines total: refactor error-body-drain into a helper that takes `AsyncSequence<UInt8>` (mirroring the `parseSSELines` pattern), or extend `URLProtocol` for the non-200 case (plain URLSession requests do cooperate with URLProtocol — only `.bytes(for:)` success path has the interop issue). Drop into new @Test in `ResponsesClientStreamingTests.swift`. | Add "⚠️ coverage gap" to execution-report.md + dev-workflow-state.yml; defer to Phase 3 probe testing. |
| Risk | Implementation time cost only. | Latent bug surfaces in prod: first time a token expires AND upstream returns zstd-compressed error body, end users see a crash or hang, not a clean 401 propagation. |

**Recommendation:** A — `ResponsesClient.swift:51-65` is a fresh code path introduced in this phase (not inherited) so it has never been runtime-exercised. Pattern already exists (`parseSSELines` was factored out for exactly this kind of test-ability). 80 lines of test is a low ask to close a latent-bug risk that the plan-verifier cycle 1 explicitly called out.

### [DP-002] SubscriptionSessionLoader actor→class conversion (blocking)

**Gap:** Phase 1 plan lists no changes to `Sources/CCRouterCore/SubscriptionSession.swift`. Implementation changed `public actor SubscriptionSessionLoader` → `open class SubscriptionSessionLoader: @unchecked Sendable` and added a `public init(testCredentials:)` backdoor, purely to let `MockSessionLoader` subclass for test injection. Production loses actor isolation; public API gains a test-only seam.

**Options:**

| | A: Revert + introduce protocol | B: Accept current form |
|---|---|---|
| Behavior | `SubscriptionSessionLoader` returns to actor; tests use `SubscriptionSessionLoading` protocol + struct mock | Class + backdoor init stays in production API |
| Implementation | Revert SubscriptionSession.swift (40-line diff); add ~15-line protocol; rewrite MockSessionLoader as struct (~15 lines). Net 3 files touched. | Zero additional work |
| Risk | Test file rewrite effort | Any field added to `SubscriptionSessionLoader` in future phases has no actor protection; silent race if mutable state added. Public `init(testCredentials:)` can be misused by downstream callers to bypass auth. |

**Recommendation:** A — the plan already uses this exact pattern (Task 6 introduces `ResponsesStreamingClient` protocol with the same intent). Applying the same pattern for sessionLoader is strictly in-plan style and restores production concurrency semantic. The 40-line revert + 30-line protocol addition is lower risk than preserving an unauthorized production API change.

### [DP-003] Weak unit test for chunked-transfer header filtering (recommended)

**Gap:** Plan Task 6 specifies `chunkedTransferHeadersExcludeContentLength` as a unit test that "check 原始字节含 `Transfer-Encoding: chunked` 但不含 `Content-Length:`" — i.e. assert the actual wire header bytes output by `sendStreamBody`. Actual test (StreamingBridgeIntegrationTests.swift:690-709) only inspects the `HTTPResponse` enum form and user-supplied `headers` dict; it never calls `sendStreamBody`. The filtering code at `LocalHTTPServer.swift:347-352` (which removes any `Content-Length` user-supplied header before adding `Transfer-Encoding: chunked`) has no automated coverage.

**Options:**

| | A: Strengthen unit test | B: Rely on smoke test |
|---|---|---|
| Behavior | Unit test captures sendStreamBody output bytes and greps for header presence/absence | Plan's real-daemon smoke at dev-guide acceptance §4 covers end-to-end |
| Implementation | Extract header-serialisation from `sendStreamBody` into a testable helper (returns `Data`) or feed a `Data`-accumulator NWConnection stand-in. ~40 lines. | Zero additional work |
| Risk | Implementation time cost | RFC 9112 §6.2 violation goes undetected until someone runs the smoke test manually; automated CI does not catch a regression where user-supplied Content-Length leaks through |

**Recommendation:** A — the plan's own quality marker "至少 10 个 @Test；每个 @Test 直接用 `#expect` 断言具体 wire byte 内容或时间差（不允许只 `#expect(chunks.count > 0)` 这种弱断言）" (plan line 870) calls out exactly this kind of weak assertion as forbidden. Current test violates the plan's own quality marker.

---

## Low-Confidence Appendix (C < 80)

- [C:70] `JSONObject.from([` count = 12 vs plan threshold ≤10 — **low confidence reason:** 10 of 12 are trace/log + makeResponsesPayload (explicitly allowed by plan Quality marker); 2 in `convertTools` are for protocol-edge tool-schema construction (convertTools is preserved per plan Step 10 keep list). Spirit of DP-004 (IR-only in translation path) is met; literal threshold not. Counting the threshold as "passed" or "failed" is a judgment call.
- [C:75] `AnthropicBridge.encodeJSONObjectToString` (line 711-714) dead code — **low confidence reason:** private function, compiler emits no warning (Swift does not warn on unused private methods), no runtime impact. Ought to be deleted but failing to delete is cosmetic.
- [C:70] `ContentView.swift:389` uses `try await loader.loadCurrent()` against now-synchronous method — **low confidence reason:** xcodebuild emits no warning on this (verified), Swift permits `await` on non-async expression. Harmless but stylistically stale; would be caught and cleaned up if DP-002 is accepted.

---

## Summary Output

### Plan-vs-Code (Part 1)
- Total gaps: 3 reported (C >= 80) + 3 low-confidence appendix items (C < 80)
  - Critical: 1 (DP-001 Task 8 missing tests)
  - Standard: 2 (DP-002 unauthorized SubscriptionSession change, DP-003 weak chunked header test)
- Tests: 34 plan-listed @Test required across 4 new files; 38 @Test exist; 36 non-shell; 1 shell (chunkedTransfer..., see DP-003); 2 plan-specified @Test missing (Task 8, see DP-001)

### Design Fidelity (Part 2)
- [A] Spec values: 4 checked, 0 mismatched (DP-004 threshold literally breached but spirit met → low-conf)
- [B] Data flow: 4 new flows traced, 0 disconnected
- [C] Old code: 14 deletion items, 0 still present (1 dead-code leftover from impl noted in low-conf)
- [D] Features: 8 checked, 0 missing
- [E] Quality: 3 compared — 1 silent degradation (Task 8 test coverage), 1 known simplification (chunked header test), 1 unauthorized production API change (sessionLoader)

### Rules Audit
- R6: 3 completion claims audited — 2 ✅ verified (52/52 tests, clean build), 1 ❌ false ("HTTP status covered by integration tests" — grep falsifies)
- R9: 1 file edited outside plan target set (SubscriptionSession.swift) — bypass rather than protocol-extract
- Decision authority: 0 View modifications (Phase 1 has no UI scope)

### Verdict
❌ 3 gaps require remediation (2 blocking: DP-001 missing HTTP tests, DP-002 unauthorized SubscriptionSession actor→class; 1 recommended: DP-003 weaken chunked header test).

Note: The main deliverables of Phase 1 (IR layer, streaming pipeline, chunked transfer, advisor bridge, regression of §3.13/§3.14) are all correctly implemented and tested. The gaps are in test coverage completeness (DP-001), an unauthorized refactoring of an adjacent production type (DP-002), and one weak assertion (DP-003). Phase 1 business goals are achieved; remediation closes quality/safety gaps before Phase 2.
