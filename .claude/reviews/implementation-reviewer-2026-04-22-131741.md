## Implementation Review Summary
**Status:** complete
**Plan:** docs/06-plans/2026-04-22-phase1-streaming-ir-plan.md
**Design doc:** docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md (Phase 1)
**Started:** 2026-04-22-131741
**Prior review:** .claude/reviews/implementation-reviewer-2026-04-22-130156.md (3 DPs raised)
**Scope:** Re-audit the three DP fixes (DP-001 HTTP tests, DP-002 SubscriptionSession revert, DP-003 chunked byte-level tests) + regression sweep.

---

## Re-Audit of Prior DPs

### DP-002 — SubscriptionSessionLoader actor→class reverted (blocking → resolved) [C:95]

**Prior state (at review 130156):** `public actor SubscriptionSessionLoader` had been silently converted to `open class SubscriptionSessionLoader: @unchecked Sendable` with a public `init(testCredentials:)` backdoor. Production lost actor isolation; public API leaked a test seam.

**Current state verified:**

1. `Sources/CCRouterCore/SubscriptionSession.swift:95` — `public actor SubscriptionSessionLoader: SubscriptionSessionProviding` is restored.
2. `_testCredentials` backdoor init **removed** (`grep -n "_testCredentials" Sources/` → no match).
3. `Sources/CCRouterCore/SubscriptionSession.swift:91-93` — new protocol added:
   ```swift
   public protocol SubscriptionSessionProviding: Sendable {
       func loadCurrent() async throws -> SubscriptionCredentials
   }
   ```
4. `git diff HEAD -- Sources/CCRouterCore/SubscriptionSession.swift` is now a clean 22-line additive diff (protocol definition + conformance) rather than the prior 40-line semantic downgrade.
5. `Sources/CCRouterCore/AnthropicBridge.swift:25,33,37,47,126`:
   - `private let sessionLoader: any SubscriptionSessionProviding`
   - `sessionLoader: (any SubscriptionSessionProviding)? = nil` with `?? SubscriptionSessionLoader()` default
   - Both call sites use `try await sessionLoader.loadCurrent()` (actor isolation respected)
6. `Tests/CCRouterCoreTests/MockResponsesEventStream.swift:437` — `MockSessionLoader` is now `struct MockSessionLoader: SubscriptionSessionProviding { let credentials: ...; func loadCurrent() async throws -> ... }`. No subclassing, no `@unchecked Sendable`.
7. `ModelBridge/ContentView.swift:389` — `try await SubscriptionSessionLoader(...).loadCurrent()` call is consistent with actor isolation; xcodebuild passes.
8. `Sources/CCRouterCore/GatewayDaemon.swift:11-17` — production wiring passes concrete `SubscriptionSessionLoader` via protocol parameter; back-compat preserved.

**Matches prior DP-002 Option A recommendation verbatim.** Actor serial-access semantics restored; test seam removed from production API.

### DP-001 — Task 8 HTTP status + error-body tests added (blocking → resolved) [C:90]

**Prior state:** Plan listed 7 @Test; two (`non200StatusThrowsResponsesHTTPError`, `errorBodyReadWithoutAssumingUTF8Lines`) were silently dropped. `ResponsesClient.swift:51-65` (error-body drain) had zero coverage.

**Current state verified:**

1. `Sources/CCRouterCore/ResponsesClient.swift:68-83` — `drainErrorBody` extracted as `internal static func drainErrorBody<S: AsyncSequence & Sendable>(_:maxBytes:) async -> String where S.Element == UInt8`. This mirrors the `parseSSELines` pattern that the prior DP-001 recommendation explicitly cited.
2. `Sources/CCRouterCore/ResponsesClient.swift:51-53` — the streamEvents non-2xx branch now calls `Self.drainErrorBody(bytes)`; the helper is unit-testable in isolation.
3. `Tests/CCRouterCoreTests/ResponsesClientStreamingTests.swift` @Test count: **11** (prior: 7; plan floor: ≥7).
4. The four new @Test methods are all present:
   - `errorBodyReadWithoutAssumingUTF8Lines` (line 180-189) — feeds 8 non-UTF-8 bytes (`0x80..0x87`), asserts `"<non-utf8 body, 8 bytes>"` placeholder. Directly exercises `ResponsesClient.swift:81-82`.
   - `errorBodyDrainReturnsUTF8StringWhenValid` (line 191-196) — happy path, asserts `result == #"{"error":"bad request"}"#`.
   - `errorBodyDrainHonoursMaxBytes` (line 198-204) — 100 KB body + `maxBytes: 256`, asserts truncation.
   - `non200StatusThrowsResponsesHTTPError` (line 206-218) — constructs `ResponsesHTTPError(statusCode: 401, body: ...)`, asserts `.statusCode`, `.body`, and `LocalizedError` bridge.
5. Pattern exactly matches the prior DP-001 Option A recommendation ("refactor error-body-drain into a helper that takes `AsyncSequence<UInt8>`, mirroring the parseSSELines pattern").

**Minor observation (not a new DP):** `non200StatusThrowsResponsesHTTPError` tests the error object alone, not the full `streamEvents` → HTTPURLResponse → non-2xx → drainErrorBody → throw composite. The 3-line glue at `ResponsesClient.swift:51-53` is inspectable by reading and is the simplest possible composition of helpers that are each tested. Filed as low-confidence item, not a remediation DP.

### DP-003 — Chunked transfer byte-level tests added (recommended → resolved) [C:95]

**Prior state:** `chunkedTransferHeadersExcludeContentLength` only inspected the `HTTPResponse` enum shape (`bodyData == nil` + `headers["Content-Length"] == nil`), never exercising `sendStreamBody`'s header serialisation. Violated the plan's own quality marker (line 870) forbidding weak assertions.

**Current state verified:**

1. `Sources/CCRouterCore/LocalHTTPServer.swift:95-135` — `internal enum ChunkedHTTPEncoder` extracted:
   - `buildHeaderBytes(statusCode:reasonPhrase:userHeaders:) -> Data`
   - `formatChunk(_:) -> Data`
   - `terminator: Data` (`"0\r\n\r\n"`)
2. `sendStreamBody` (line 384) and `NWConnectionBodyWriter` (line 146, 159) delegate to the encoder; behavior preserved.
3. `Tests/CCRouterCoreTests/StreamingBridgeIntegrationTests.swift` @Test count: **13** (prior: 10).
4. Three new @Test methods present:
   - `chunkedTransferHeadersExcludeContentLength` (line 690-720) — **rewritten, no longer a shell test**. Input includes a bogus `Content-Length: 999`; asserts byte-level: status line prefix, `Transfer-Encoding: chunked\r\n` presence, `content-length` absence (case-insensitive), `\r\n\r\n` terminator, `Content-Type: text/event-stream\r\n` preserved, `Cache-Control: no-cache\r\n` preserved.
   - `chunkedFrameFormatMatchesRFC9112` (line 722-737) — asserts `"hello"` → `5\r\nhello\r\n`, empty → `0\r\n\r\n`, 255-byte `0x41` → `ff\r\nA...` (lowercase hex).
   - `chunkedTerminatorIsCorrect` (line 739-741) — `#expect(ChunkedHTTPEncoder.terminator == Data("0\r\n\r\n".utf8))`.
5. The prior weak test was renamed to `chunkedTransferPreservesHTTPResponseEnumForm` (line 743-762) and kept as an enum-shape smoke check (legitimately weak, no longer masquerading as the wire-byte test).

**Exercises the real wire format.** Plan quality marker satisfied.

---

## Regression Sweep (Sections 1-13 on full diff)

### 1. Deletion Verification [C:95] ✅
All 14 removal targets from plan Step 10 remain absent (verified in prior review §1).

### 2. Struct/Interface Field Comparison [C:95] ✅
IRBlock / IRMessage / AnthropicSSEEncoder / PendingToolTurn / HTTPResponse.Body all still match plan (verified in prior review §2).

### 3-5. UI / No-match / Integration [C:95] ✅
No UI scope. Integration greps pass (prior review §4-5). No new deviations.

### 6. Never Trust Existing Code

Spot-read the three refactored files:
- `Sources/CCRouterCore/ResponsesClient.swift:40-83` — `streamEvents` + `drainErrorBody` split is clean. Generic `S: AsyncSequence & Sendable where S.Element == UInt8` constraint matches `URLSession.AsyncBytes`. `maxBytes` default 64000; fails safe on invalid UTF-8 via `??` fallback.
- `Sources/CCRouterCore/LocalHTTPServer.swift:95-135, 146, 159, 384` — encoder extraction is a pure refactor; call sites delegate, no behavior change. `filteredHeaders` filters case-insensitively (`.lowercased() != "content-length"`) which matches RFC 9112 §6.2.
- `Sources/CCRouterCore/SubscriptionSession.swift:91-95` — protocol is additive; actor body unchanged from pre-phase-1. Only surface change: protocol conformance declaration on actor line.

[C:90] ✅ No stale half-edits detected.

### 7. Unauthorized Deferral Detection

**Prior DP-001 deferral (dropping two tests) is closed.** Current implementation has all three plan-line-1040-1042 @Test names present (with the cancellation test named `cancellationViaOnTerminationStopsParser` rather than `cancellationPropagatesToUpstreamTask` — still covers the scenario at parser level). Plan required ≥7; current is 11.

[C:90] ✅ No new unauthorized deferrals detected.

### 8. Conditional Branch Verification [C:95] ✅
Branches A/B in Step 3 and advisor-false in Step 5 still correctly implemented (verified prior review §8). Not affected by this round of fixes.

### 9. Removal-Replacement Reachability [C:90] ✅
Unchanged from prior review. `finalizeResponse` → streaming pipeline still reachable.

### 10. Term Consistency After Rename [C:95] ✅
`replayItems` absent; `replayIR` present.

### 11. ADR Action Completeness [C:95] ✅
Deletion checklist items all gone.

### 12. Reverse Regression Reasoning

**Regression #1 — Error body crash on upstream 4xx/5xx:**
- Path: 401 upstream → streamEvents → non-2xx guard → `drainErrorBody(bytes)` → non-UTF-8 `nil` → `"<non-utf8 body, N bytes>"` fallback → throw `ResponsesHTTPError`.
- Covered by forward check: ✅ `errorBodyReadWithoutAssumingUTF8Lines` exercises the fallback branch.
- Action Required: **none** (resolved by DP-001 fix).

**Regression #2 — Continuation payload leaks user text to upstream:**
- Covered by `BridgeRegressionTests.bashToolTurnTwoRoundsStillClosesViaStreaming` (unchanged from prior round).
- Action Required: none.

**Regression #3 (new) — ChunkedHTTPEncoder extraction breaks existing streaming on wire:**
- Path: `sendStreamBody` → `buildHeaderBytes` → NWConnection.send(headerBytes).
- If encoder produced wrong bytes, integration tests (`firstContentBlockDeltaArrivesWithin50Ms`, `responseBodyIsStreamFormAndNotDataFallback`, etc.) would fail. All 13 StreamingBridgeIntegrationTests pass.
- Covered by forward check: ✅ both wire-format tests (new) and integration tests (existing) pass.
- Action Required: none.

**Regression #4 (new) — SubscriptionSessionLoader actor restoration breaks compile:**
- Path: `AnthropicBridge.init` accepts `any SubscriptionSessionProviding`; production passes concrete `SubscriptionSessionLoader()`; protocol conformance + actor isolation both hold.
- Both `swift test` (59/59) and `xcodebuild test` (2/2) pass → type-checker accepts the new shape end-to-end.
- Action Required: none.

### 13. Rules Compliance Audit

**R6 (Evidence before claims):**
- Session brief claims: build clean, `swift test` 59/59, `xcodebuild` 2/2 pass.
- Verified independently: `swift test --scratch-path /tmp/ModelBridgeSwiftTest` → `Test run with 59 tests in 8 suites passed after 0.040 seconds`. `xcodebuild test -project ModelBridge.xcodeproj -scheme ModelBridge -destination 'platform=macOS' -only-testing:ModelBridgeTests` → `** TEST SUCCEEDED **` with ModelBridgeTests individual cases passing.

```
[R6 Audit] Completion claims: 3 — ✅ 3 verified, 0 unverified
```

**R9 (Fix obstacles, don't bypass):**
- Files modified vs HEAD: `AnthropicBridge.swift`, `LocalHTTPServer.swift`, `ResponsesClient.swift`, `SubscriptionSession.swift`.
- Plan-specified targets: AnthropicBridge (Task 5), LocalHTTPServer (Task 4/6), ResponsesClient (Task 3/8) → 3 files.
- Non-plan-specified: SubscriptionSession.swift (1 file). **But: the change is now an additive protocol declaration (22 lines), which is the in-pattern fix already used by Task 6 for `ResponsesStreamingClient`.** This was the exact remediation path DP-002 Option A recommended. The R9 concern from the prior review (unauthorized semantic downgrade actor→class) is fully closed.

```
[R9 Audit] Files edited: 4 source — plan-specified: 3, unplanned: 1 (SubscriptionSession.swift)
Unplanned file classification: additive protocol extraction (in-plan style, matches Task 6 pattern; not a bypass)
```

**Decision authority:** 0 View modifications. Phase 1 has no UI scope.

### 13.1 Test Completeness Audit

| Test file | Plan required | Actual @Test | Change this round | Coverage |
|---|---|---|---|---|
| IRBlockConversionTests.swift | ≥15 | 19 | — | ✅ all 3 directions |
| StreamingBridgeIntegrationTests.swift | ≥10 | 13 | +3 chunked byte-level | ✅ all plan tests present + byte-level wire format |
| BridgeRegressionTests.swift | 2 | 2 | — | ✅ §3.13 + §3.14 |
| ResponsesClientStreamingTests.swift | ≥7 | 11 | +4 (drain + envelope) | ✅ all 7 plan-named tests present (with renamed cancel test) |

No shell tests remain. The prior shell `chunkedTransferHeadersExcludeContentLength` is rewritten with byte-level assertions; the prior enum-shape assertion was renamed and kept as a legitimate smoke check.

```
[Test Completeness]
- Required tests: 4 files (total plan-listed @Test: ~34 floor)
- Files exist: 4
- Non-empty tests: 4
- Core path covered: 4 (IR + bridge integration + regression + streaming client)
- Shell tests: 0 (prior shell test rewritten with wire-byte assertions)
- New since prior review: 7 @Test (3 chunked byte-level + 4 HTTP error-drain / envelope)
- Total @Test in suite: 59 (prior: 52)
```

---

## Part 2: Design Fidelity Audit (Phase 1 only)

### 14. Spec Value Comparison (Gap A) [C:95]

- [A] BlockKind enum 5 cases: ✅ match
- [A] `processUpstreamStream` handles `{response.output_text.delta, response.output_item.done, response.completed}`: ✅ match (prior §14)
- [A] DP-003=A `Connection: close`: ✅ `ChunkedHTTPEncoder.buildHeaderBytes` line 112 includes it; new test `chunkedTransferHeadersExcludeContentLength` would catch a regression.
- [A] DP-004=A "JSONObject only at protocol edges": unchanged from prior; low-confidence literal count observation carried forward.

### 15. Data Flow Connectivity Tracing (Gap B) [C:95] ✅
All five data flows from prior review still wired end-to-end. The `drainErrorBody` extraction adds a new flow: `HTTPURLResponse non-2xx → drainErrorBody → ResponsesHTTPError` — wired at `ResponsesClient.swift:51-53`, tested independently.

### 16. Old Code Removal Completeness (Gap C) [C:95] ✅
14 deletion targets still absent. Prior low-confidence note on `AnthropicBridge.encodeJSONObjectToString` (dead private function) carried forward — still cosmetic-only, not a gap.

### 17. Missing Feature Detection (Gap D) [C:95] ✅
All 8 design features still present + test coverage (prior §17 table unchanged).

### 18. Implementation Quality Comparison (Gap E) [C:95]

- [E] Task 8 URLProtocol pivot — now legitimately acceptable: `drainErrorBody` unit tests cover the error-body branch directly (prior DP-001 closed the silent-coverage-degradation gap). ✅ plan intent met.
- [E] Chunked header test — now wire-byte assertions (prior DP-003 closed). ✅ plan quality marker met.
- [E] SubscriptionSessionLoader — actor restored (prior DP-002 closed). ✅ design-faithful.

**All three prior silent degradations resolved.**

---

## Pre-existing Issues

None newly discovered this round. Prior review's `encodeJSONObjectToString` dead-code observation is cosmetic (private, no warning, no runtime impact).

---

## Decisions

None. All prior DPs (001, 002, 003) resolved per their recommended options.

---

## Low-Confidence Appendix (C < 80)

- [C:70] `non200StatusThrowsResponsesHTTPError` tests the error object only, not the composite `streamEvents` → HTTPURLResponse-check → drainErrorBody → throw path — **low confidence reason:** the 3-line glue at `ResponsesClient.swift:51-53` is structurally inspectable; each helper is tested in isolation; the composite failure mode would require a URLProtocol-stubbed `URLSession.bytes(for:)`, which plan line 1082 acknowledges is blocked by Swift 6.2's URLSession-bytes/URLProtocol interop limitation. Not a remediation ask.
- [C:75] `AnthropicBridge.encodeJSONObjectToString` (line 711-714) dead code — **low confidence reason:** carried forward from prior review, private function, no compiler warning, cosmetic-only. Cleanup could be bundled with future refactor.
- [C:70] `JSONObject.from([` count exceeds plan's nominal ≤10 threshold — **low confidence reason:** carried forward; all 12 call sites are in plan-allowed roles (trace/log/payload maker/anthropicError/convertTools). Spirit of DP-004 met; literal threshold breach is a judgment call.

**Resolved from prior review (removed):**
- Prior C:70 note about `ContentView.swift:389` using `try await` on a "now-synchronous" method — **superseded**: SubscriptionSessionLoader is now an actor again, so `try await loader.loadCurrent()` is the correct Swift. Prior observation no longer applies.

---

## Summary Output

### Plan-vs-Code (Part 1)
- Total gaps: **0 reported (C >= 80)** + 3 low-confidence appendix items (C < 80)
- Tests: 34 plan-listed @Test floor; **59 @Test** total across 8 suites pass; 0 shell tests; 0 plan-specified tests missing.

### Design Fidelity (Part 2)
- [A] Spec values: 4 checked, 0 mismatched
- [B] Data flow: 5+ flows traced (one new: drainErrorBody), 0 disconnected
- [C] Old code: 14 deletion items, 0 still present
- [D] Features: 8 checked, 0 missing
- [E] Quality: 3 prior silent-degradations — **all 3 resolved this round**

### Rules Audit
- R6: 3 completion claims, 3 verified (build, swift test 59/59, xcodebuild 2/2)
- R9: 1 unplanned file edit (SubscriptionSession.swift); classified as **additive protocol extraction** (in-pattern fix matching Task 6's `ResponsesStreamingClient` style). Not a bypass.
- Decision authority: 0 View modifications (Phase 1 has no UI scope)

### Verdict
✅ **Implementation complete — Phase 1 approved.**

All three DPs from the prior review (DP-001 HTTP status/error-body tests, DP-002 SubscriptionSession actor revert, DP-003 chunked byte-level tests) are resolved per their recommended Option A paths. Production concurrency semantics restored. Error-body drain path now has direct unit coverage. Chunked-transfer wire format now has byte-level assertions. No new regressions introduced. 59/59 Swift Testing pass, 2/2 Xcode tests pass. Phase 1 business goals (IR layer, streaming pipeline, chunked transfer, advisor bridge, regression of §3.13/§3.14) are all implemented, tested, and verified.

Ready to proceed to Phase 2.
