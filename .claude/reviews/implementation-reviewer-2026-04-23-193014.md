## Implementation Review Summary
**Status:** complete
**Plan:** docs/06-plans/2026-04-23-phase5-auth-refresh-count-tokens-plan.md
**Started:** 2026-04-23-193014

---

## Section 1: Deletion Verification

Plan does not require deletion of any file. The string `"body-size-heuristic"` must be deleted (Task 6 Step 3).

- ✅ [C:100] `grep -rn "body-size-heuristic" Sources/ Tests/` returns 0 lines. Deletion complete.

---

## Section 2: Struct/Interface Field Comparison

### Task 2: `SubscriptionCredentials` struct

Plan fields (plan:117-134): `accessToken: String`, `accountID: String`, `refreshToken: String?`, `lastRefresh: Date?`.
Code fields (`SubscriptionSession.swift:3-19`): identical 4 fields + matching 4-param init with default values.

- ✅ [C:100] Struct fields match plan byte-for-byte, including default-param init for backward compatibility.

### Task 2: `AuthFile.Tokens` decoder

Plan fields (plan:137-143): `access_token: String?`, `account_id: String?`, `refresh_token: String?`, `id_token: String?`.
Code (`SubscriptionSession.swift:378-383`): identical.

- ✅ [C:100] All four tokens fields present.

### Task 2: `AuthFile` top-level `last_refresh: String?`

Code `SubscriptionSession.swift:376`: `let last_refresh: String?` — matches plan step 3.

- ✅ [C:100]

### Task 3: `RefreshedTokens` struct

Plan fields (plan:177-182): `accessToken`, `refreshToken`, `idToken: String?`, `lastRefresh: Date`.
Code (`AuthTokenRefresher.swift:9-26`): identical four fields plus matching init.

- ✅ [C:100]

### Task 3: `AuthRefreshError` enum

Plan cases (plan:184-187): `refreshFailed(statusCode, body)`, `invalidResponseBody(String)`.
Code (`AuthTokenRefresher.swift:28-31`): identical + `Sendable, Equatable` conformance.

- ✅ [C:100]

### Task 7: `BridgeDoctorStatus` / `DoctorSnapshot` fields

Plan adds `lastRefresh: Date?` + `hasRefreshToken: Bool`.
Code `AnthropicBridge.swift:1394-1401` has both fields on `BridgeDoctorStatus`; `DoctorSnapshot.swift:25-26` has both on `DoctorSnapshot`.

- ✅ [C:100]

---

## Section 3: UI Element Verification

No UI changes required in Phase 5 (plan line 26: "Crystal file: none（Phase 5 无视觉决策）"). Skipped.

---

## Section 4: "No Matches Found" Red Flags

- Grep for `"body-size-heuristic"`: 0 hits across Sources/Tests. This is the **expected** outcome per Task 6 Step 3 — not a gap.

---

## Section 5: Integration Point Verification

### handleMessages calls streamEvents preflight (Task 5 architectural)

Code `AnthropicBridge.swift:86-89` — `initialStream = try await responsesClient.streamEvents(...)` called in `handleMessages` outer scope BEFORE `return HTTPResponse(200, stream:)`.
Second attempt (line 134) on 401 retry path: same outer scope.

- ✅ [C:100] Preflight streamEvents in `handleMessages` outer scope. Body closure (line 156) receives the already-established stream via `initialStream:` param to `runPreparedTurn`. The header-flush-before-401 problem (plan line 16) is correctly solved.

### runPreparedTurn accepts `initialStream` param

Plan (step 1, lines 360-370): require signature to accept `initialStream: AsyncThrowingStream<JSONObject, Error>` and NOT call streamEvents internally for the first pass.
Code (`AnthropicBridge.swift:558-565`): signature includes `initialStream` param; inside (line 571): `let stream = initialStream` — no internal first-pass streamEvents. Second-pass streamEvents for advisor continuation at line 921 is correctly preserved (plan boundary: "Phase 5 不处理" for second-pass).

- ✅ [C:100] Signature + internal wiring correct.

### GatewayDaemon routes count_tokens to bridge.handleCountTokens

Plan Task 6 Step 2: remove local heuristic, delegate to `bridge.handleCountTokens(request)`.
Code `GatewayDaemon.swift:120-134`: auth check preserved, delegates to `bridge.handleCountTokens(request)` on success. No `max(1, request.body.count / 4)` heuristic remains.

- ✅ [C:100]

### sessionLoader.refreshAndReload called on 401

Code `AnthropicBridge.swift:97`: `activeCredentials = try await sessionLoader.refreshAndReload()` within the 401 catch. Trace emits `subscription_refresh_attempt` → refresh → success/failure stages.

- ✅ [C:100]

---

## Section 6: Never Trust Existing Code

All new Phase 5 files verified read, not assumed:
- `AuthTokenRefresher.swift` (Task 3) — read and verified endpoint/body/response shape match probe report.
- `CountTokensEndpointTests.swift` (Task 6) — read, 7 test methods confirmed.
- `AuthTokenRefresherTests.swift` (Task 3) — read, 4 test methods confirmed.
- `TraceLoggerRefreshEventsTests.swift` (Task 8) — read, 2 test methods confirmed.
- `docs/research/2026-04-23-codex-refresh-endpoint-probe.md` (Task 1) — read, all four probe fields confirmed with `Refresh_token rotating: true`.

---

## Section 7: Unauthorized Deferral Detection

Scanned plan tasks for skipped items or deferrals. No task marked as deferred. Plan context states "8 tasks complete".

One borderline item:
- Plan Task 4 Step 3 bullet ("具体控制流") has comment `catch let refreshError {` then rethrow. Code (`SubscriptionSession.swift:196-201`) wraps `AuthRefreshError` in `SubscriptionSessionError.authorizationRequired(url)` rather than rethrowing as-is. This is a **plan text deviation**, not a deferral — and the test at `SubscriptionSessionTests.swift:291-299` asserts the wrapped type, so the deviation is consistent with test expectations. Not a gap; see §18.

---

## Section 8: Conditional Branch Verification

Plan DP-P5-005 Chosen: A with fallback to conservative — cache-hit 5s short-circuit activation depends on Task 1 probe `rotating` status.

Probe outcome (`docs/research/2026-04-23-codex-refresh-endpoint-probe.md:48`): `Refresh_token rotating: true`.
Plan requirement: if rotating is `true` or `unknown`, Task 4 Step 3 keeps the cache-hit block.
Code (`SubscriptionSession.swift:167-176`): cache-hit block is active with `< 5.0` threshold and references DP-005 comment.

- ✅ [C:100] Condition verified (rotating=true per probe); correct branch (cache-hit retained) implemented.

---

## Section 9: Removal-Replacement Reachability

Plan replaces `body.count/4` heuristic with BPE-backed `handleCountTokens`. Replacement activation:
- Route: `POST /v1/messages/count_tokens` (`GatewayDaemon.swift:120`) → auth check → `bridge.handleCountTokens`. Always-on when authorized.
- Inside `handleCountTokens`: decodes → `buildCountablePayload` → `inputTokenCounter.countInputTokens` → returns JSON result.
- Failure path: decode error → 400 with invalid_request_error envelope; no silent fallback to heuristic.

- ✅ [C:100] Replacement unconditionally reachable for authenticated requests. No stale heuristic branch remains.

---

## Section 10: Term Consistency After Rename

Plan Task 6 Step 3: `"body-size-heuristic"` → `"cl100k-bpe"` in 3 places.

Grep result:
- `Sources/CCRouterCore/GatewayDaemon.swift:52` — `cl100k-bpe` ✓
- `Sources/CCRouterCore/GatewayDaemon.swift:98` — `cl100k-bpe` ✓
- `Tests/CCRouterCoreTests/DoctorSnapshotTests.swift:11` — `cl100k-bpe` ✓
- `body-size-heuristic` — 0 hits ✓

- ✅ [C:100] All three rename sites updated; old term fully removed from active code.

---

## Section 11: ADR Action Completeness

Plan is not an ADR; no ADR-style deletion checklist required. DP-P5-004/005/006 decisions each list a specific code change target:
- DP-P5-004 (Chosen C): IR codec path + parity test → implemented `AnthropicBridge.swift:250-264` (buildCountablePayload uses IRAnthropicCodec + IRResponsesCodec + joinedSystemText + convertTools) and `CountTokensEndpointTests.swift:367-417` (endpointMatchesBridgePrepareTurnInitialPayload).
- DP-P5-005 (Chosen A, conservative fallback): rotating probe confirmed `true` → cache-hit block retained at `SubscriptionSession.swift:167-176`.
- DP-P5-006 (Chosen A): `final class MockSessionLoader, @unchecked Sendable` at `MockResponsesEventStream.swift:461`.

- ✅ [C:90] All three decision actions have corresponding code + test. (One nuance: DP-P5-006 specified "NSLock protects mutable fields" — see §13 unplanned-change; code uses no lock, relying on actor/serial execution of bridge tests. Not a gap per se, but the "@unchecked Sendable" is kept without the documented locking.)

---

## Section 12: Reverse Regression Reasoning

### Hypothetical regression 1: Count duration is negative

User action: POST to `/v1/messages/count_tokens` with any valid payload.
Code path: `GatewayDaemon.swift:134` → `AnthropicBridge.handleCountTokens` (`AnthropicBridge.swift:216-245`).
Bug point: `AnthropicBridge.swift:229` computes `ContinuousClock.now.duration(to: startTime)` — this is `startTime - now`, which is a **negative duration** (plan intended `startTime.duration(to: .now)`). Consequence: emitted trace field `duration_ms` will be negative (or zero) for every count_tokens call.

Covered by forward check: ❌ Not caught by any forward check. The trace test (`countTokensEndpointEmitsTraceEvents`) asserts presence of `count_tokens_in` / `count_tokens_out` and input_tokens matching body, but does NOT assert duration sign.

Action Required: fix direction of `duration(to:)` call; add trace-field non-negative assertion.

### Hypothetical regression 2: Concurrent requests during 5s cache window issue second refresh

User action: Claude Code CLI spawns 2 concurrent `/v1/messages` requests after a token has expired.
Code path: `handleMessages` #1 hits 401 → `refreshAndReload` → refresh endpoint call, new tokens arrive; meanwhile `handleMessages` #2 enters 401 catch → calls `refreshAndReload` → sees cache entry (within 5s) → returns cached credentials.
Expected behavior: #2 uses newly cached tokens; no second refresh to openai.com.
Actual behavior: Works because `SubscriptionSessionLoader` is an actor (serial) and `lastSuccessfulRefreshAt` + `cachedCredentialsAfterRefresh` are updated BEFORE write-back (plan Step 3 Step correctly implemented at `SubscriptionSession.swift:212-213`).

Covered by forward check: ⚠️ no concurrency test. Task 4 tests focus on single-caller correctness. A stress test of two `Task` blocks racing `refreshAndReload` is not present. In production the actor serialization + 5s guard should handle this correctly, but the plan-stated rationale ("cache the fresh credentials BEFORE write-back so concurrent callers see fresh token even if disk write fails") is not test-verified.

Action Required: optional — consider adding concurrency test; not a plan gap, since plan only requires single-call tests.

### Hypothetical regression 3: Retry 401 fallback enters catch but logs do not flush

User action: access token stale AND refresh token still valid.
Path: first streamEvents → 401 → refresh (success) → second streamEvents → success (200) → body closure eventually emits SSE. Trace emits: `subscription_refresh_attempt`, `subscription_refresh_success`.

Covered by forward check: ✅ §5 covered `refreshAndReload` call. Test `handleMessagesRetriesOnce401AfterRefresh` at `BridgeRegressionTests.swift:1014-1063` asserts `statusCode == 200`, `streamEventsCallCount == 2`, `refreshAndReloadCallCount == 1`.

Action Required: none.

---

## Section 13: Rules Compliance Audit

### R6 (Evidence before claims)

Context from user message: "8 tasks complete; build clean; 194/197 tests pass. Known test failures (noted for separate fix): refreshSuccessEmitsTraceEvent, countTokensEndpointEmitsTraceEvents, firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta, cancellationViaOnTerminationStopsParser."

Two of the four known failures are Phase 5 tests the plan required (Task 8 Step 3/4). Per R6, declaring "8 tasks complete" while two Phase-5-required tests fail is partial verification. Plan Task 8 Verify section (line 656-659) specifies `Expected: 所有新测试绿` — this has NOT been met for the refresh-success trace test and count_tokens trace test. See §13.1 for detail.

```
[R6 Audit] Completion claims for 8 tasks: 8 — ✅ 6 verified (tests pass) / ⚠️ 2 unverified (tests fail: refreshSuccessEmitsTraceEvent, countTokensEndpointEmitsTraceEvents)
```

### R9 (Fix obstacles, don't bypass)

Plan-specified files (per all Tasks' Files sections):
- Modify: `SubscriptionSession.swift`, `AnthropicBridge.swift`, `GatewayDaemon.swift`, `DoctorSnapshot.swift`, `MockResponsesEventStream.swift`, `DoctorSnapshotTests.swift`, `SubscriptionSessionTests.swift`, `BridgeRegressionTests.swift`
- Create: `AuthTokenRefresher.swift`, `CountTokensEndpointTests.swift`, `AuthTokenRefresherTests.swift`, `TraceLoggerRefreshEventsTests.swift`, `docs/research/2026-04-23-codex-refresh-endpoint-probe.md`

Git diff shows these additional files changed:
- `ContentView.swift`, `Package.swift`, `AnthropicProtocol.swift`, `LocalHTTPServer.swift`, `ResponsesClient.swift`, `RouterConfiguration.swift`, `RouterConfigurationStore.swift`, `RouterConfigurationStoreTests.swift` — **all listed in the initial repo snapshot** (before Phase 5 execution). Classified as pre-existing uncommitted changes from prior phases. See pre-existing issues below.
- `TraceLogger.swift` — NOT in the initial M-list; Phase 5 added `resetForTesting()`. **Unplanned** Phase 5 edit not referenced by any task's Files section.

```
[R9 Audit] Files edited: 13 — plan-specified: 12 / unplanned: 1
Unplanned: Sources/CCRouterCore/TraceLogger.swift — reason: Task 8 test (countTokensEndpointEmitsTraceEvents) needs a trace reset helper; added public method but not declared in plan's Files list.
```

Classification: the `resetForTesting()` addition is a secondary fix needed to make Task 8 tests deterministic. This is a legitimate scope broadening, not a bypass — but it violates plan Files hygiene (plan did not list TraceLogger.swift). Minor procedural finding; not a functional gap.

### Decision authority scan

No View/UI modifications in Phase 5 scope. `ContentView.swift` is a pre-existing modification (Phase 4/earlier).

```
[Decision Audit] View modifications: 0 user-visible from Phase 5
```

---

## Section 13.1: Test Completeness Audit

Plan required test files and coverage:

| Task | Test File | Exists | Non-empty | Core path covered | Pass |
|------|-----------|--------|-----------|-------------------|------|
| 2 | SubscriptionSessionTests.refreshTokenAndLastRefreshParsedFromAuthFile | ✅ | ✅ | ✅ | ✅ |
| 2 | SubscriptionSessionTests.missingRefreshTokenDoesNotBreakLoad | ✅ | ✅ | ✅ | ✅ |
| 3 | AuthTokenRefresherTests.successfulRefreshReturnsNewTokens | ✅ | ✅ | ✅ | ✅ (assumed per 194/197 pass) |
| 3 | AuthTokenRefresherTests.http401ThrowsRefreshFailed | ✅ | ✅ | ✅ | ✅ |
| 3 | AuthTokenRefresherTests.malformedJSONThrowsInvalidResponseBody | ✅ | ✅ | ✅ | ✅ |
| 3 | AuthTokenRefresherTests.networkErrorThrowsURLError | ✅ | ✅ | ✅ | ✅ |
| 4 | SubscriptionSessionTests.refreshAndReloadUpdatesCredentials | ✅ | ✅ | ✅ | ✅ |
| 4 | SubscriptionSessionTests.refreshAndReloadPreservesFilePermissions | ✅ | ✅ | ✅ | ✅ |
| 4 | SubscriptionSessionTests.refreshWithNoRefreshTokenThrowsAuthorizationRequired | ✅ | ✅ | ✅ | ✅ |
| 4 | SubscriptionSessionTests.refreshFailureDoesNotCorruptAuthFile | ✅ | ✅ | ✅ | ✅ |
| 4 | SubscriptionSessionTests.refreshWritebackFailureReturnsCredentialsWithoutThrow | ✅ | ✅ | ✅ | ✅ |
| 5 | BridgeRegressionTests.handleMessagesRetriesOnce401AfterRefresh | ✅ | ✅ | ✅ | ✅ |
| 5 | BridgeRegressionTests.secondConsecutive401ReturnsAuthorizationRequired | ✅ | ✅ | ✅ | ✅ |
| 5 | BridgeRegressionTests.refreshFailureDuringRetryReturns503 | ✅ | ✅ | ✅ | ✅ |
| 6 | CountTokensEndpointTests.singleTextMessageReturnsPositiveCount | ✅ | ✅ | ✅ | ✅ |
| 6 | CountTokensEndpointTests.largerPayloadReturnsLargerCount | ✅ | ✅ | ✅ | ✅ |
| 6 | CountTokensEndpointTests.invalidJSONReturns400 | ✅ | ✅ | ✅ | ✅ |
| 6 | CountTokensEndpointTests.toolSchemaIncreasesCount | ✅ | ✅ | ✅ | ✅ |
| 6 | CountTokensEndpointTests.endpointCountMatchesInputTokenCounterDirectly | ✅ | ✅ | ⚠️ see note | ✅ |
| 6 | CountTokensEndpointTests.toolCallHistoryIsCounted | ✅ | ✅ | ✅ | ✅ |
| 6 | CountTokensEndpointTests.endpointMatchesBridgePrepareTurnInitialPayload | ✅ | ✅ | ✅ | ✅ |
| 7 | DoctorSnapshotTests.doctorSnapshotIncludesLastRefreshAndRefreshTokenPresence | ✅ | ✅ | ✅ | ✅ |
| 7 | DoctorSnapshotTests.snapshotHandlesLegacyAuthFileWithoutRefreshToken | ✅ | ✅ | ✅ | ✅ |
| 8 | TraceLoggerRefreshEventsTests.refreshSuccessEmitsTraceEvent | ✅ | ✅ | ✅ | ❌ FAIL |
| 8 | TraceLoggerRefreshEventsTests.countTokensEndpointEmitsTraceEvents | ✅ | ✅ | ✅ | ❌ FAIL |

**Gap T-fail (Task 8)**: 2 of the 2 required Task 8 tests fail.

❌ Gap T-fail-1 [C:95]: `refreshSuccessEmitsTraceEvent` fails per user-reported context ("mock session loader returns authorization-required before retry path reaches success"). This suggests the MockSessionLoader with no `refreshedCredentials` constructor arg is returning the initial credentials rather than the configured refreshed ones, OR the test reads stale trace lines before the log is flushed. Root cause needs investigation; at minimum, the test must pass to satisfy plan Task 8 Verify.

Location: `Tests/CCRouterCoreTests/TraceLoggerRefreshEventsTests.swift:88-122`
Action: diagnose and fix. Candidate checks:
- Ensure `TraceLogger.shared.resetForTesting()` is called at test start (currently only `countTokensEndpointEmitsTraceEvents` resets; `refreshSuccessEmitsTraceEvent` reads `recentLines(limit: 20)` against a potentially-stale shared file).
- Verify `MockSessionLoader(credentials:, refreshedCredentials:)` init path returns the configured refreshed creds; code at `MockResponsesEventStream.swift:489-493` does return `_refreshedCredentials ?? credentials` correctly.

❌ Gap T-fail-2 [C:95]: `countTokensEndpointEmitsTraceEvents` fails per user-reported context ("count_tokens_in trace stage not emitted").

Location: `Tests/CCRouterCoreTests/TraceLoggerRefreshEventsTests.swift:128-154`
Action: diagnose and fix. Candidate checks:
- `resetForTesting` removes and re-creates trace file at line 56-62. The subsequent `handleCountTokens` writes to it (line 219-223 of AnthropicBridge.swift). `recentLines(limit: 20)` on line 145-146 reads from the same file. File-based race is possible but unlikely — the actor serializes access.
- Possible cause: TraceLogger.shared is a global actor singleton that writes to `~/.../trace.jsonl`; other concurrent tests may be writing to the same file while this test runs. Tests run in parallel by default under Swift Testing. The `resetForTesting` truncates the file, but parallel test writes could erase the count_tokens_in entry before read.

Note on `endpointCountMatchesInputTokenCounterDirectly` (Task 6): the helper at `CountTokensEndpointTests.swift:424-440` passes RAW tools (not convertTools-output) to its direct counter, but the production endpoint passes convertTools-output. The BPE counter only reads `name`/`description`/`parameters` which are identical between raw and converted shapes (the only difference is `strict: false`), so counts match by accident. The test comment at line 423 ("to match handleCountTokens' direct path") is incorrect — handleCountTokens does NOT pass raw tools. Test still passes because the BPE-countable fields happen to be identical. Fragile assumption, not a gap.

```
[Test Completeness]
- Required tests: 25
- Files exist: 25
- Non-empty tests: 25
- Core path covered: 25
- Shell tests: 0
- Failing: 2 (refreshSuccessEmitsTraceEvent, countTokensEndpointEmitsTraceEvents)
```

---

## Section 14-18: Design Fidelity Audit

Design doc per user: "none (Phase 5 design evidence is scheme3/03-anthropic-edge.md + scheme3/14-count-tokens-observation-v1.md + already-built AnthropicInputTokenCounter code)". Plan treats this as its own design source (probe + existing code). Applying §18 Implementation Quality only.

### Section 18: Implementation Quality Comparison (Gap E)

- `buildCountablePayload` vs `prepareTurn`'s `initialPayload` construction:
  - prepareTurn (line 518-525): uses `makeResponsesPayload` which wraps input in `instructions + input + tools + tool_choice + parallel_tool_calls + reasoning + store + stream + include + service_tier + prompt_cache_key + text + client_metadata`.
  - buildCountablePayload (line 259-263): outputs `instructions + input + tools` only.
  - Per AnthropicInputTokenCounter (line 22-40): counter only reads `instructions`, `input`, `tools` fields. Extra fields on prepareTurn's payload do not affect count. So the two payloads produce identical counts on the counter. Parity test `endpointMatchesBridgePrepareTurnInitialPayload` verifies byte-equal counts.
  - ✅ [E:faithful] [C:95] plan hard-requires IR path reuse (DP-P5-004 Chosen C); code uses IR codec + parity test locks byte-level equality.

- AuthTokenRefresher endpoint/body shape vs probe report:
  - Probe: `POST application/json` to `https://auth.openai.com/oauth/token`, body `{client_id, grant_type, refresh_token}`, response `{access_token, refresh_token, id_token?}`.
  - Code `AuthTokenRefresher.swift:97-158`: matches probe byte-for-byte. Default endpoint constant at line 106; client_id constant `"app_EMoamEEZ73f0CkXaXp7hrann"` at line 103.
  - ✅ [E:faithful] [C:100]

- Atomic auth.json write-back: plan requires `FileManager.replaceItemAt` (DP-P5-003 Chosen C) to preserve 0600 permissions.
  - Code `SubscriptionSession.swift:292-297`: uses `FileManager.default.replaceItemAt`. Test `refreshAndReloadPreservesFilePermissions` asserts 0600 preserved. ✅

- Cache-hit short-circuit: plan DP-P5-005 conservative branch (rotating=true).
  - Code `SubscriptionSession.swift:167-176`: active with 5s threshold. ✅

- MockSessionLoader: plan DP-P5-006 requires `final class + @unchecked Sendable + NSLock`.
  - Code `MockResponsesEventStream.swift:461-494`: `final class ... @unchecked Sendable` ✓; NSLock **absent**. `private(set) var refreshAndReloadCallCount: Int = 0` + `private var _refreshedCredentials`, `_refreshError` — all unsynchronized.
  - Impact assessment: `MockSessionLoader` instances are captured by a single `AnthropicBridge` actor; bridge calls `refreshAndReload` via actor-serial dispatch. Concurrent access to MockSessionLoader mutable state would require two bridge actor calls in parallel referencing the same mock, which does not happen in any existing test (each test creates its own mock). So the missing NSLock does NOT cause concurrent-access undefined behavior in any currently-written test.
  - However: plan explicitly documented NSLock as required (plan lines 449-483), and `@unchecked Sendable` without any synchronization is a lie to the compiler. If future tests add concurrent execution, this would silently corrupt. See §18 verdict below.
  - ⚠️ [E:silent degradation] [C:85] Plan specified "NSLock protects mutable fields" (plan line 447); implementation omits the lock. No `⚠️ SIMPLIFIED:` annotation in plan. Rule: "code uses a different approach without `⚠️ SIMPLIFIED:` annotation → must-fix (silent degradation)". Severity: low — runtime-observable only under future concurrent test execution.

---

## Pre-existing Issues

The following files are modified in the working tree BEFORE Phase 5 execution (shown in initial git status): `ContentView.swift`, `Package.swift`, `AnthropicProtocol.swift`, `LocalHTTPServer.swift`, `ResponsesClient.swift`, `RouterConfiguration.swift`, `RouterConfigurationStore.swift`, `RouterConfigurationStoreTests.swift`, plus the prior M-list entries for Phase 5's target files. These are not caused by Phase 5.

- `TraceLogger.swift` resetForTesting addition is Phase 5-related (needed by Task 8 tests) but not listed in plan's Files sections — classified as legitimate secondary fix, not a pre-existing issue.

Most pre-existing state is leftover from Phases 1-4 execution without commits (the repo has only 4 commits from the initial bootstrap + 2 recent UI docs). This is procedural (user is not committing between phases) and outside Phase 5 scope to address; surfacing here so user is aware that `git diff HEAD` is NOT a Phase-5-only diff.

---

## Real Gaps (Plan-vs-Code, C >= 80)

1. **Gap T-fail-1 [C:95]: Task 8 test `refreshSuccessEmitsTraceEvent` fails.**
   - Plan Task 8 Step 3 requires this test to pass. User-reported failure cause: "mock session loader returns authorization-required before retry path reaches success".
   - Action: investigate root cause; likely parallel-test interference on shared `TraceLogger.shared` file. Recommend adding `await TraceLogger.shared.resetForTesting()` at test start (mirroring the other test in the same file).

2. **Gap T-fail-2 [C:95]: Task 8 test `countTokensEndpointEmitsTraceEvents` fails.**
   - Plan Task 8 Step 4 requires this test to pass. User-reported failure cause: "count_tokens_in trace stage not emitted".
   - Action: investigate. Possible causes (in order of likelihood):
     a) Parallel-test race on shared `TraceLogger.shared` file (other tests writing/truncating between reset and read).
     b) `resetForTesting` truncates file asynchronously via `try? Data().write(to:)`; subsequent `log(...)` may complete before the write visible to `recentLines`. This is unlikely given actor serialization.
     c) Test environment's trace file path resolves to a sandboxed/read-only location.
   - Recommended fix: run test in isolation (`.serialized` trait) AND/OR switch to per-test TraceLogger instance instead of `.shared`.

3. **Gap Q-bug-1 [C:90]: `handleCountTokens` duration calculation has reversed direction.**
   - Location: `AnthropicBridge.swift:229`: `let elapsed = ContinuousClock.now.duration(to: startTime)`.
   - `a.duration(to: b)` returns `b - a`, so `now.duration(to: startTime)` = `startTime - now` = negative. Expected: `startTime.duration(to: .now)` = `now - startTime` = positive elapsed.
   - Impact: emitted `duration_ms` trace field is negative for every count_tokens request.
   - Not caught by any test (test checks only presence of count_tokens_out + input_tokens match, not duration sign).
   - Action: swap operands → `startTime.duration(to: .now)`.

4. **Gap Q-plan-1 [C:85]: MockSessionLoader missing NSLock per plan DP-P5-006.**
   - Location: `Tests/CCRouterCoreTests/MockResponsesEventStream.swift:461-494`.
   - Plan (line 447-483) explicitly specified `@unchecked Sendable` + NSLock for mutable field protection.
   - Code has `@unchecked Sendable` but no NSLock; `private(set) var refreshAndReloadCallCount` + `private var _refreshedCredentials` + `private var _refreshError` are unsynchronized.
   - No current test exercises concurrent access to a single MockSessionLoader instance, so this does not cause observable failures today. But it's a silent degradation of the documented design (per §18 severity rule: no `⚠️ SIMPLIFIED:` annotation in plan → must-fix).
   - Action: add NSLock as documented in plan.

5. **Gap Q-plan-2 [C:80]: `refreshAndReload` wraps `AuthRefreshError` in `SubscriptionSessionError.authorizationRequired` instead of rethrowing.**
   - Location: `SubscriptionSession.swift:196-197`.
   - Plan Step 3 bullet: `guard let refreshToken = current.refreshToken else { throw authorizationRequired }` and `let refreshed = try await refresher.refresh(...)` (implicit rethrow on failure).
   - Code catches `AuthRefreshError` and rethrows as `SubscriptionSessionError.authorizationRequired(url)`. Test `refreshFailureDoesNotCorruptAuthFile` asserts the wrapped type, so the test is consistent with the code. But the plan text implied direct rethrow of `AuthRefreshError`.
   - Impact: caller (`AnthropicBridge.handleMessages`) catches all errors generically and maps to `authentication_error`, so externally observable behavior is the same. But the wrapping obscures the underlying refresh failure reason — a 500 "invalid_grant" from OAuth server becomes an `authorizationRequired` SubscriptionSessionError with URL.
   - Action: either (a) document this wrapping in the plan as an acceptable refinement, or (b) rethrow original AuthRefreshError so AnthropicBridge can distinguish network vs auth failures.

---

## Summary Output

```
## Implementation Review Summary

### Plan-vs-Code (Part 1)
- Total gaps: 5 (Critical: 0, Standard: 5) — reported: 5 (C>=80), filtered: 0 (C<80)
- Tests: 25 required, 25 exist, 25 core-path covered, shell: 0, failing: 2

Gaps:
- Gap T-fail-1 [C:95] §13.1: refreshSuccessEmitsTraceEvent fails
- Gap T-fail-2 [C:95] §13.1: countTokensEndpointEmitsTraceEvents fails
- Gap Q-bug-1 [C:90] §12: handleCountTokens duration reversed → negative duration_ms trace field
- Gap Q-plan-1 [C:85] §18: MockSessionLoader missing NSLock per DP-P5-006
- Gap Q-plan-2 [C:80] §7/§18: refreshAndReload wraps AuthRefreshError (not direct rethrow per plan)

### Design Fidelity (Part 2)
- [A] Spec values: 4 checked (endpoint URL, client_id, 5s cache window, 0600 perm) → 4 match
- [B] Data flow: 3 checked (handleMessages→streamEvents→runPreparedTurn, GatewayDaemon→handleCountTokens, sessionLoader→refresher) → 3 connected
- [C] Old code: 1 checked (body-size-heuristic) → removed
- [D] Features: 8 task-level features checked → 8 built
- [E] Quality: 5 compared → 4 faithful, 1 silent degradation (MockSessionLoader NSLock)

### Rules Audit
- R6: 8/8 tasks claimed complete — 6 verified (tests pass), 2 unverified (Task 8 tests fail)
- R9: 13 files edited — 12 plan-specified, 1 unplanned (TraceLogger.swift adds resetForTesting — legitimate secondary fix for Task 8 test support)
- Decision authority: 0 UI/view changes in Phase 5 scope

### Low-Confidence Appendix (C < 80)
None. All findings ≥ 80.

### Verdict
❌ 5 gaps require remediation (2 test failures blocking Task 8 Verify; 1 duration bug; 2 plan-text deviations).
```

---

## Decisions

### [DP-001] Task 8 test failures — diagnose vs accept (blocking)

**Chosen:** A — Fix tests before marking phase complete (via TraceLogger `@TaskLocal overrideFileURL` task-local override; tests bind a per-test temp file URL via `TraceLogger.$overrideFileURL.withValue(tmpURL) { ... }`, isolating writes from parallel test suites. Zero changes to AnthropicBridge/SubscriptionSessionLoader/GatewayDaemon call sites.)


**Gap:** Plan Task 8 Verify requires all Task 8 tests to pass. Two of two required Task 8 tests currently fail (`refreshSuccessEmitsTraceEvent`, `countTokensEndpointEmitsTraceEvents`). The failure is consistent with `TraceLogger.shared` being a global actor writing to a shared on-disk file, with other parallel-running tests mutating the same file.

**Options:**

| | A: Fix tests before marking phase complete | B: Accept known failures; mark phase complete |
|---|---|---|
| Behavior | Tests pass; plan Verify gate honored; trace-emit invariants guaranteed | Tests remain red in CI forever; phase done but plan Verify unmet |
| Implementation | Add `await TraceLogger.shared.resetForTesting()` at test start AND mark tests `.serialized` OR refactor to inject per-test TraceLogger — est. 30-60 lines across 2 files | 0 lines |
| Risk | Additional refactor if per-test injection needed (TraceLogger is used globally); low otherwise | Plan Verify requirements permanently unmet; regression risk (trace emits silently broken → no alert) |

**Recommendation:** A — Plan Task 8 Verify explicitly requires these tests green (plan line 656-659); `TraceLogger.swift:56-62` `resetForTesting` is already present; adding `.serialized` trait (Swift Testing supports this via `@Suite(.serialized)`) is ~2 lines. The negative feedback loop from silently-failing trace tests is high-cost.

### [DP-002] `handleCountTokens` duration direction bug — fix now or defer (recommended)

**Chosen:** A + B — Code already corrected (pre-verified: `AnthropicBridge.swift:229` now `startTime.duration(to: .now)`); test assertion added in `countTokensEndpointEmitsTraceEvents` (parses `duration_ms` from trace line, asserts `>= 0`).


**Gap:** `AnthropicBridge.swift:229` computes `ContinuousClock.now.duration(to: startTime)` which yields negative elapsed time. Every count_tokens call emits a negative `duration_ms` trace field.

**Options:**

| | A: Fix swap | B: Add assertion in test | C: Defer to future observability phase |
|---|---|---|---|
| Behavior | `duration_ms` becomes correct positive ms | Test catches regression, but current value stays negative | Trace remains broken indefinitely |
| Implementation | 1-line fix: `startTime.duration(to: .now)` | ~3 lines in `countTokensEndpointEmitsTraceEvents` | 0 lines |
| Risk | Zero | Zero | Dashboard/analytics misinterpret negative durations |

**Recommendation:** A + B — 1-line fix plus a positive-value assertion. The fix has zero risk; the assertion prevents regression.

### [DP-003] MockSessionLoader NSLock — enforce plan or accept deviation (recommended)

**Chosen:** A — Already in place at `MockResponsesEventStream.swift:461-506` (NSLock protects `_refreshAndReloadCallCount`, `_refreshedCredentials`, `_refreshError` via `lock.lock(); defer { lock.unlock() }`); re-verified before marking phase done.


**Gap:** Plan DP-P5-006 Chosen A explicitly documented NSLock for mutable field protection (plan lines 447-483). Implementation uses `@unchecked Sendable` without the documented lock. Observable impact: none in current tests (each test has its own mock instance, no concurrent access).

**Options:**

| | A: Add NSLock per plan | B: Update plan to retcon the decision |
|---|---|---|
| Behavior | Matches plan; future concurrent tests safe | Plan and code aligned; future concurrent tests unsafe |
| Implementation | ~8 lines added to MockSessionLoader | ~2 lines in plan DP-P5-006 |
| Risk | Zero | Silent corruption if future tests spawn parallel tasks against one mock |

**Recommendation:** A — NSLock overhead is negligible for test code; plan documented it for good reason (matching the production actor's safety posture); adding it now removes a latent hazard.

### [DP-004] refreshAndReload error-wrapping behavior — clarify contract (recommended)

**Chosen:** B — Already in place at `SubscriptionSession.swift:193-195` (direct `try await refresher.refresh(...)`, no wrapping catch — comment at line 193 explicitly records the intent); `AnthropicBridge.handleMessages:100-108` introspects `AuthRefreshError` / `SubscriptionSessionError` / `URLError` and emits distinct `error_type` trace fields. Verified via the existing `BridgeRegressionTests.refreshFailureDuringRetryReturns503` test.


**Gap:** `SubscriptionSession.swift:196-197` wraps `AuthRefreshError` inside `SubscriptionSessionError.authorizationRequired(url)`. Plan Step 3 bullets implied direct rethrow of `AuthRefreshError`. Test asserts the wrapped type (consistent with code).

**Options:**

| | A: Keep wrapping, update plan | B: Unwrap — rethrow original AuthRefreshError |
|---|---|---|
| Behavior | `handleMessages` sees SubscriptionSessionError with URL; loses refresh-specific detail | `handleMessages` sees AuthRefreshError with statusCode+body |
| Implementation | Update plan doc to document the wrapping | 1-line change in `SubscriptionSession.swift:196` + adjust test assertion |
| Risk | Diagnostic info lost (statusCode/body not propagated) | Zero (handleMessages already catches generically) |

**Recommendation:** B — `handleMessages.swift:98-114` already has error-type introspection (checks for AuthRefreshError / SubscriptionSessionError / URLError) and emits a specific `error_type` trace field. Unwrapping allows that branch to actually fire with "auth_refresh_error" instead of "subscription_session_error", which is more informative for ops debugging.
