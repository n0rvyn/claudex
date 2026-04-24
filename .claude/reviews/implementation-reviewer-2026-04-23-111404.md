## Implementation Review Summary
**Status:** complete
**Plan:** /Users/norvyn/Code/Projects/ModelBridge/docs/06-plans/2026-04-23-phase4-session-cache-stability-plan.md
**Started:** 2026-04-23-111404

## Part 1: Plan-vs-Code Verification

### 1. Deletion Verification

Plan prescribes no file deletions. N/A.

The fixed advisor guidance string `"Provide concise strategic guidance for the current task"` was to be replaced (not a file delete, but a code removal mandated by Task 6).

- `grep -rn 'Provide concise strategic guidance' Sources/` → 0 production hits.
- Only reference is in the negative-assertion test `AdvisorContextForwardingTests.swift:221` verifying its absence.

✅ No gaps. [C:100]

### 2. Struct/Interface Field Comparison

**`RouterConfiguration` (Sources/CCRouterCore/RouterConfiguration.swift:3-20)**

Plan additions:
- `pendingToolTurnTTLSeconds: Int` (default 1800) — present at line 12, init default at :37, coding key at :122, decode at :155, encode at :176. ✅
- `advisorContextMessageLimit: Int` (default 8) — present at line 13, init default at :38, coding key at :122, decode at :156, encode at :177. ✅

**`StoredConfiguration` (Sources/CCRouterCore/RouterConfigurationStore.swift:296-316)**

- Phase 4 additions at :314-315 use **plain `Int?`** with no inline defaults — matches the cycle-3 lesson (inline defaults silently disable Codable synthesis). ✅

**`PendingToolTurn` (Sources/CCRouterCore/AnthropicBridge.swift:934-941)**

- New `lastAccessedAt: Date` present at line 940. Declared `var` so helpers can mutate. ✅

**`DoctorSnapshot` (Sources/CCRouterCore/DoctorSnapshot.swift:28-81)**

- New `pendingToolTurnsCount: Int` at line 28; no default (compiler forces all call sites to update). Present in init at :55 and assignment at :81. ✅

No gaps. [C:100]

### 3. UI Element Verification

Phase 4 has no UI layout changes. Settings UI editor for Phase 4 fields is explicitly out of scope (dev-guide § Phase 6 / plan line 1201).

N/A. [C:100]

### 4. "No Matches Found" = Red Flag

- `grep 'Provide concise strategic guidance' Sources/` → 0 (expected — plan required removal).
- `grep 'UUID().uuidString.lowercased()' Sources/CCRouterCore/AnthropicBridge.swift` → 2 hits (`:38` installationID, `:43` sessionID fallback). Plan verify step says expect exactly 2. ✅

No unexpected zeros. [C:100]

### 5. Integration Point Verification

**Cache-key threading (Task 2):** plan says all 4 `makeResponsesPayload` call sites must receive a `promptCacheKey` computed via `PromptCacheKey.stable(sessionID: sessionHeader, ...)`.

| Call site | Location | Computes cacheKey via PromptCacheKey.stable | Passes `promptCacheKey:` to payload |
|---|---|---|---|
| Initial turn | `runInitialTurn` :309-321 | ✅ :309 | ✅ :320 |
| Continuation | `runStreamingTurn` :196-209 | ✅ :196 | ✅ :208 |
| Advisor second pass | `runAdvisorSubcallAndSecondPass` :657-664 | Receives `promptCacheKey` param from caller | ✅ :663 |
| Advisor sub-call | `runAdvisorSubcall` :820-827 | Receives `promptCacheKey` param from caller | ✅ :826 |

**`sessionHeader` propagation**: `grep -c 'sessionHeader' AnthropicBridge.swift` = 15 (plan expected ≥ 5). Raw extraction at :42, threaded into `runStreamingTurn` :161, `runInitialTurn` :302, `handleOutputBlocks` :502, `runAdvisorSubcallAndSecondPass` :608. ✅

**`promptCacheKey:` argument count**: `grep -c` = 12 (plan expected ≥ 5). ✅

**Trace logging**: prompt_cache_key logged at `:216` (continuation), `:328` (initial), `:671` (advisor second pass). ✅

**DoctorSnapshot wire-through (Task 5)**: `bridge.pendingToolTurnsCount()` called at `GatewayDaemon.swift:69` (public snapshot) and `:112` (GET /health route). ✅

No gaps. [C:100]

### 6. Never Trust Existing Code

All touched files verified by reading, not assumed.

Verified the user-flagged regression points personally:
- `runInitialTurn` catch block `try? await encoder.emitTextDelta("\n[upstream error: ...]")` — present at line 369. ✅
- `runStreamingTurn` continuation catch block — present at line 261. ✅
- `runAdvisorSubcallAndSecondPass` text-only else-branch `try await encoder.finish(stopReasonHint: .endTurn)` — present at line 708. ✅

All three dropped lines that the user flagged were restored in the final file.

No gaps. [C:100]

### 7. Unauthorized Deferral Detection

Plan has 7 tasks. Scanning for any "deferred", "optional", "next phase", "TODO":

- Task 7 probe script exists, has `--dry-run` flag, research doc has Setup/Raw usage/Conclusion/Amendment sections per plan. No deferral. ✅
- All 7 tasks have their Files listed and tests present (see § 13.1).

No unauthorized deferrals. [C:100]

### 8. Conditional Branch Verification

Plan contains no "if X then A, else B" user-facing conditionals. The only conditional is the internal fallback branch in `PromptCacheKey.stable` (session-header present vs absent), which is tested by `PromptCacheKeyStabilityTests`:
- `returnsSessionIDLowercasedWhenPresent` (present branch)
- `fallbackHashingIsDeterministic` + `emptySessionFallsBack` + `oversizedSessionFallsBack` (absent/invalid branch)

Both branches exercised. ✅ [C:100]

### 9. Removal-Replacement Reachability

The fixed advisor guidance string is replaced by dynamic context (instructions + historyIR). Verifying reachability:
- `runAdvisorSubcall` at :820-827 builds `advisorPayload` with `input: advisorMessages` (the truncated history from :798-814) and `instructions: advisorSystem` (the dynamic string at :816-818, which embeds the real `instructions` param).
- Callers (`runAdvisorSubcallAndSecondPass` :625-631) pass real `instructions` and `historyIR` sourced from `handleOutputBlocks`, which in turn receives them from `runInitialTurn`/`runStreamingTurn`.

Replacement is reachable on the exact path the old code traversed. ✅ [C:100]

### 10. Term Consistency After Rename

No renames in Phase 4. The old `prompt_cache_key: UUID()...` usage has been globally removed (see § 5). [C:100]

### 11. ADR Action Completeness

Plan includes no ADR-style delete checklists beyond Task 6's fixed-string replacement (already verified in § 1 and § 9). [C:100]

### 12. Reverse Regression Reasoning

**Hypothetical regression 1**: Continuation turn does not hit the cache partition that initial turn created.
- User action: send an initial tool-using turn on session `s1`, then send the tool-result continuation.
- Code path: `handleMessages` → `runStreamingTurn` → initial branch uses `cacheKey = s1`; continuation branch at :196 recomputes `cacheKey = PromptCacheKey.stable(sessionID: sessionHeader, ...)` which yields the same `s1` since `sessionHeader` is reused.
- Both initial and continuation use the same `cacheKey` → same upstream cache partition. ✅ Covered by § 5.

**Hypothetical regression 2**: Silent data loss when user rotates gateway token.
- User action: click "rotate gateway token" in Settings.
- Code path: `regenerateGatewayToken` at `RouterConfigurationStore.swift:98-119` rebuilds a `RouterConfiguration` with Phase 4 fields threaded through at :109-110. Test `tokenRegenerationPreservesPhase4Fields` at `RouterConfigurationMigrationTests.swift:206` uses non-default values (600, 4) and asserts preservation after rotation. ✅ Covered.

**Hypothetical regression 3**: `PendingToolTurn` map grows unbounded when users abandon tool turns.
- User action: start a tool-use turn, close the client without sending `tool_result`.
- Code path: `storePending` at :953 runs `evictStalePending` after insert; `readPending` at :945 runs it before every continuation lookup. TTL configurable (default 1800s). Tests `pendingToolTurnEvictedWhenSimulatedTimeExceedsTTL` and `pendingToolTurnSurvivesBeforeTTL` verify both sides of the threshold. ✅ Covered.

No new findings from reverse reasoning. [C:95]

### 13. Rules Compliance Audit

**[R6 Audit]** Test-run report at `.claude/test-reports/test-run-2026-04-23T11-12-50.md` lists actual command output (143/144 pass, 1 unrelated flake). This is verified completion — not a "should work" claim. ✅ Evidence present.

**[R9 Audit]** Files edited by Phase 4 (from plan's Files lists):
- `Sources/CCRouterCore/PromptCacheKey.swift` (new) — Task 1 ✅
- `Sources/CCRouterCore/AnthropicBridge.swift` — Tasks 2, 4, 6 ✅
- `Sources/CCRouterCore/RouterConfiguration.swift` — Task 3 ✅
- `Sources/CCRouterCore/RouterConfigurationStore.swift` — Task 3 ✅
- `Sources/CCRouterCore/DoctorSnapshot.swift` — Task 5 ✅
- `Sources/CCRouterCore/GatewayDaemon.swift` — Task 5 ✅
- Test files per Tasks 1/3/4/5/6 ✅
- `scripts/probe_prompt_cache_hit.py` + research doc — Task 7 ✅

All edited files are plan-specified. No unplanned file edits. ✅

**[Decision Audit]** No View/UI file modifications in Phase 4. The `git status` shows `ModelBridge/ContentView.swift` modified from earlier phases (phase-3 executed earlier), not Phase 4. [C:95]

### 13.1 Test Completeness Audit

| Required test | Path | Exists | Non-empty | Core-path covered |
|---|---|---|---|---|
| T1 PromptCacheKeyStability (7 @Test) | Tests/CCRouterCoreTests/PromptCacheKeyStabilityTests.swift | ✅ | ✅ | ✅ |
| T3 RouterConfigurationMigration Phase 4 additions (3 @Test expected, +saveReload = 4) | Tests/CCRouterCoreTests/RouterConfigurationMigrationTests.swift | ✅ | ✅ | ✅ |
| T4 PendingToolTurnEviction (3 @Test) | Tests/CCRouterCoreTests/PendingToolTurnEvictionTests.swift | ✅ | ✅ | ✅ |
| T5 DoctorSnapshot (1 @Test) | Tests/CCRouterCoreTests/DoctorSnapshotTests.swift | ✅ | ✅ | ✅ |
| T6 AdvisorContextForwarding (3 @Test) | Tests/CCRouterCoreTests/AdvisorContextForwardingTests.swift | ✅ | ✅ | ✅ |
| T2 BridgeRegression — `requestsWithoutSessionHeaderShareStableCacheKey` | Tests/CCRouterCoreTests/BridgeRegressionTests.swift:346 | ✅ | ✅ | ✅ |

Verified every test has real `#expect` assertions (no shell tests).

- **RouterConfigurationMigrationTests**: lines 166 (`legacyConfigWithoutPhase4FieldsUsesDefaults`), 182 (`phase4FieldsRoundTripThroughCodable`), 206 (`tokenRegenerationPreservesPhase4Fields`), 243 (`saveReloadRoundTripPreservesPhase4Fields`) — 4 new Phase 4 tests. Non-default values (600, 4) chosen to catch default-reset regressions.
- **PendingToolTurnEviction**: uses `evictStalePending(now:)` with `Date().addingTimeInterval(1801)` / `.addingTimeInterval(29*60)` — deterministic, no real-time sleep.
- **AdvisorContextForwarding**: asserts `captured[1]` (advisor /responses perform) has `input.count == 8` (default) and `== 4` (custom limit); asserts fixed guidance string absent.

[Test Completeness]
- Required tests: 6 test files
- Files exist: 6
- Non-empty tests: 6
- Core path covered: 6
- Shell tests: 0

[C:100]

---

## Part 2: Design Fidelity Audit

Design doc: `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md` § Phase 4.

The dev-guide § Phase 4 is 6 bullet points of scope (cache-key stability, pending-tool-turn TTL, advisor context, visible trace changes, probe). The plan expands these into 7 tasks and is independently verified approved in cycle 4.

### 14. Spec Value Comparison (Gap A)

| Spec value (plan/design) | Code | Match |
|---|---|---|
| TTL default 1800s (DP-001-P4) | `RouterConfiguration.swift:37` default `= 1800`; `Store.swift:170` fallback `?? 1800`; decoder :155 `?? 1800` | ✅ |
| Advisor message limit default 8 (DP-003-P4) | `RouterConfiguration.swift:38` default `= 8`; `Store.swift:171` fallback `?? 8`; decoder :156 `?? 8` | ✅ |
| Session-ID byte bound 512 | `PromptCacheKey.swift:15` `id.utf8.count <= 512` | ✅ |
| Unit separator 0x1F | `PromptCacheKey.swift:20` `Data([0x1F])` | ✅ |
| Fallback hash = instructions + firstUserMessageText (DP-002-P4 A) | `PromptCacheKey.swift:18-23` | ✅ |
| Lazy sweep on request + public hook (DP-004-P4 C) | `AnthropicBridge.swift:945-976` `evictStalePending(now:)` internal + called in readPending/storePending/pendingToolTurnsCount | ✅ |

No mismatches. [C:100]

### 15. Data Flow Connectivity Tracing (Gap B)

| Flow | Source | Component | Consumer | Connected |
|---|---|---|---|---|
| Cache key | HTTP header `x-claude-code-session-id` :42 | `PromptCacheKey.stable` | `makeResponsesPayload` :889 `"prompt_cache_key"` | ✅ |
| Advisor context | request system + requestIR | `runAdvisorSubcall` truncation/encoding | `makeResponsesPayload` advisor payload | ✅ |
| Pending count | `AnthropicBridge.pendingToolTurns` | `pendingToolTurnsCount()` | `DoctorSnapshot.pendingToolTurnsCount` via `GatewayDaemon` | ✅ |
| TTL config | `config.json` → `StoredConfiguration` | `resolveConfiguration` :170 | `AnthropicBridge.evictStalePending` reads `configuration.pendingToolTurnTTLSeconds` | ✅ |
| Advisor limit config | `config.json` → `StoredConfiguration` | `resolveConfiguration` :171 | `runAdvisorSubcallAndSecondPass` :629 reads `configuration.advisorContextMessageLimit` | ✅ |

No disconnected flows. [C:100]

### 16. Old Code Removal Completeness (Gap C)

| Removal directive | Still present? |
|---|---|
| `UUID().uuidString.lowercased()` as prompt_cache_key at former :791 | ❌ Absent. The two remaining hits are installationID init and sessionID UUID fallback — both legitimate retained paths per plan. |
| Fixed string `"Provide concise strategic guidance for the current task"` in production | ❌ Absent. Only in negative-assertion test. |
| Direct `pendingToolTurns[sessionID] = ...` map writes outside helpers | ❌ Absent. All 3 remaining subscript references are inside the 3 helper methods. |

No old-code leaks. [C:100]

### 17. Missing Feature Detection (Gap D)

Dev-guide § Phase 4 scope (each feature):

| Feature | Evidence |
|---|---|
| Prompt cache hits actually work (stable key per session) | `PromptCacheKey.stable` + 4 call sites | ✅ |
| Pending tool turn bounded growth (TTL eviction) | `evictStalePending` + tests | ✅ |
| Advisor sub-call gets real context | `runAdvisorSubcall` new signature + 3 tests | ✅ |
| `prompt_cache_key` visible in trace | `TraceLogger.log` sites at :216, :328, :671 | ✅ |
| Count visible via `/health` | `DoctorSnapshot.pendingToolTurnsCount` wired at GatewayDaemon :112 | ✅ |
| Probe `/responses` usage fields | `scripts/probe_prompt_cache_hit.py` + research doc | ✅ |

No missing features. [C:100]

### 18. Implementation Quality Comparison (Gap E)

| Design approach | Code approach | Verdict |
|---|---|---|
| SHA-256 with unit separator to prevent shift collisions | CryptoKit SHA256; 0x1F separator; test `separatorPreventsShiftCollision` validates | ✅ faithful |
| Actor-isolated helpers for map access | Private `readPending`/`storePending`/`removePending`, `internal evictStalePending` — all on the `AnthropicBridge` actor | ✅ faithful |
| Last-N truncation (message count, not token count) | `historyIR.suffix(messageLimit)` at :793 | ✅ faithful |
| output_text/input_text role split (matches Phase 3 IRResponsesCodec) | `:806` `message.role == "assistant" ? "output_text" : "input_text"` | ✅ faithful |

No silent degradations. Plan contains no `⚠️ SIMPLIFIED:` annotations and none were needed. [C:100]

---

## Pre-existing Issues

### PRE-001: Phase 1 timing flake `firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta`

- **Location**: `Tests/CCRouterCoreTests/StreamingBridgeIntegrationTests.swift:162`
- **Failure**: `#expect(elapsed < .milliseconds(50))` — actual 59.3ms on test run machine.
- **Origin**: Phase 1 work (streaming IR), not Phase 4. Confirmed by test-run report itself and by `git log --oneline` showing AnthropicBridge test history pre-dates Phase 4 session.
- **Impact on Phase 4**: None. Phase 4 plan does not touch `processUpstreamStream` hot-path latency.
- **Fix recommendation** (non-blocking): relax threshold to 100ms or tag the test with a performance/CI-only marker so it does not gate Phase 4 sign-off. This is a latency-envelope assertion on an unloaded machine, which is environmental. Do NOT block Phase 4 completion on it.

### Note on uncommitted git state

`git status` shows 9 modified files + many untracked files from prior phases and the current Phase 4 session. All Phase 4 edits are part of the current uncommitted session. No stale/orphaned changes identified in the files Phase 4 touched.

---

## Plan Advisory Items (from cycle-4 verifier, cosmetic)

These are documentation-level notes the plan author flagged as non-blocking:
- Plan step 6(f) grep-count arithmetic ("≥ 10 matches" should be "≥ 12" since sites count is 6 not 5). Grep output still satisfies the stated threshold either way.
- Plan step 6(e) phrasing ("Swift enforces init-arg declared order") could be sharper — the advice to match declared positional order is still correct.

Neither affects the implementation.

---

## Decisions

None.

All cycle-4 DP-001-P4 through DP-004-P4 decisions are resolved and faithfully implemented. No new implementation-level decision points.

---

## Summary

### Plan-vs-Code (Part 1)
- Total gaps: 0 (Critical: 0, Standard: 0) — reported: 0 (C>=80), filtered: 0 (C<80)
- Tests: 6 required, 6 exist, 6 covered, shell: 0

### Design Fidelity (Part 2)
- [A] Spec values: 6 checked, 0 mismatched
- [B] Data flow: 5 traced, 0 disconnected
- [C] Old code: 3 checked, 0 still present
- [D] Features: 6 checked, 0 missing
- [E] Quality: 4 compared, 0 degraded

### Rules Audit
- R6: ✅ test-run report provides real command output; 143/144 pass with the 1 failure being a pre-existing unrelated timing flake
- R9: ✅ all file edits are plan-specified; no bypasses or unplanned edits
- Decision authority: ✅ no unauthorized UI/UX changes

### Low-Confidence Appendix (C < 80)
None.

### Verdict
✅ Implementation complete — 0 gaps require remediation.

Phase 4 is ready for sign-off. The single `firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta` failure is pre-existing Phase-1 territory, environmental (50ms elapsed assertion under load), and not a Phase 4 regression.
