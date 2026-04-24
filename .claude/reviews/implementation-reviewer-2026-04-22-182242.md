## Implementation Review Summary
**Status:** complete
**Plan:** docs/06-plans/2026-04-22-phase2-model-routing-plan.md
**Design doc:** docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md (Phase 2 section)
**Started:** 2026-04-22-182242
**Cycle:** 2 (re-audit after RR-1 fix from prior review at .claude/reviews/implementation-reviewer-2026-04-22-161124.md)

---

## Audit Focus (per dispatch)

1. RR-1 fix is durable (ContentView legacy-init wipe)
2. No new drift since prior review
3. Phase 2 acceptance criteria verifiable from code+tests are satisfied
4. Test coverage is real, not shells

---

## Part 1: Plan-vs-Code Verification

### 1. Deletion Verification
N/A — Phase 2 specifies no file deletions.

### 2. Struct/Interface Field Comparison

Re-verified against current code. All struct definitions stable since cycle-1:

- **ModelRoute** (`Sources/CCRouterCore/ModelRouting.swift:5-15`): `upstreamModel`, `reasoningEffort`, `textVerbosity` — Codable + Sendable + Equatable. ✅ [C:100]
- **ModelRoutingRule** (`:19-27`): `match: String`, `route: ModelRoute`. ✅ [C:100]
- **ModelRoutingTable** (`:30-51`): `rules: [ModelRoutingRule]`, `fallback: ModelRoute`, `resolve(for:)` lowercased substring-contains, first match wins. ✅ [C:100]
- **defaultTable** (`:62-69`): opus → gpt-5.4 / xhigh / low; sonnet → gpt-5.4 / xhigh / low; **haiku → gpt-5.3-codex-spark / xhigh / low** (DP-002 Option B applied — comment at `:58-60` documents probe-confirmed 200 on 2026-04-22). Fallback gpt-5.4. ✅ [C:100]
- **defaultAdvisorRoute** (`:71-75`): gpt-5.4 / xhigh / low. ✅ [C:100]
- **RouterConfiguration** (`Sources/CCRouterCore/RouterConfiguration.swift:3-22`): stored `routingTable: ModelRoutingTable` + `advisorRoute: ModelRoute`; `executorModel` / `advisorModel` as computed read-throughs. ✅ [C:100]
- **PendingToolTurn** (`Sources/CCRouterCore/AnthropicBridge.swift:804-810`): `resolvedRoute: ModelRoute` field present. ✅ [C:100]

### 3. UI Element Verification
DP-001-P2 chose Option A (no Settings UI surface in Phase 2). ContentView is modified only in `persistConfiguration` and `persistSubscriptionAuthAuthorization` to use the canonical init (per RR-1 fix). No new visible UI elements; no display-data wiring changes. ✅ [C:100]

### 4. "No Matches Found" Red-Flag Check
- `grep -rn "ModelRoutingTable(rules: \[\]" Sources/ ModelBridge/` → 0 matches in non-test code. ✅ [C:100]
- `grep -rn "configuration.executorModel\|configuration.advisorModel" Sources/CCRouterCore/AnthropicBridge.swift` → 0 matches (Phase 2 routing replaced). ✅ [C:100]
- `grep -rn "claude_model\|reasoning_effort\|text_verbosity\|resolved_route_match" Sources/ Tests/` — Phase 6 fields correctly absent. ✅ [C:100]

### 5. Integration Point Verification

Re-verified from grep output:

- `AnthropicBridge.swift:288` — `let resolvedRoute = configuration.routingTable.resolve(for: anthropicModel)` ✅
- `:290-296` — `makeResponsesPayload(route: resolvedRoute, ...)` — initial turn ✅
- `:193-194` — continuation turn: `makeResponsesPayload(route: pending.resolvedRoute, ...)` ✅
- `:578-579` — second-pass: `makeResponsesPayload(route: resolvedRoute, ...)` ✅
- `:697-698` — advisor sub-call: `makeResponsesPayload(route: configuration.advisorRoute, ...)` ✅
- `:737-763` — `makeResponsesPayload(route:)` signature: `model = route.upstreamModel`, `reasoning.effort = route.reasoningEffort`, `text.verbosity = route.textVerbosity`. ✅
- `PendingToolTurn` storage at `:485-490` (function_call branch) and `:616-621` (advisor branch) both pass `resolvedRoute`. ✅
- `handleOutputBlocks` parameterized at `:438-454` and `:534`. ✅

[C:100] All routing wires intact.

### 6. Never Trust Existing Code
- Re-read `RouterConfiguration.swift:121-153` — manual Codable migration decode preserves new format AND falls back to legacy `executorModel` / `advisorModel` keys with sensible defaults. ✅
- Re-read `RouterConfigurationStore.swift:190-212` — 3-branch normalization (stored → legacy → fresh) intact; `:223-224` strips legacy keys on write. ✅

[C:100]

### 7. Unauthorized Deferral Detection

Cross-checked plan tasks 1-10 vs `docs/06-plans/execution-report.md`:

- Tasks 1, 2, 3, 4, 5, 8, 9, 10 — explicitly listed in execution-report ✅
- **Tasks 6 and 7 are MISSING from execution-report's "Task Results (Phase 2)"** — the report jumps from Task 5 to Task 8. This is a reporting omission; the underlying implementation is in fact done:
  - Task 6 trace `upstream_model` — present at `AnthropicBridge.swift:205, 302, 590` (3 sites verified by grep). ✅
  - Task 7 `ModelRoutingBridgeIntegrationTests.swift` — file exists with 5 @Test, all pass. ✅

No actual deferrals. Reporting gap noted as **Gap REPORT-1** below. [C:95]

### 8. Conditional Branch Verification
3-branch `normalizedConfiguration` (`RouterConfigurationStore.swift:190-212`):
1. Stored `routingTable` present → use it (`:192-193`) — covered by `newFormatConfigLoadsWithRoutingTableIntact` ✅
2. Legacy `executorModel` (or env) → single-rule table with empty rules (`:194-199`) — covered by `legacyFlatFieldsMigrateToSingleRuleFallback` + `envExecutorModelOverridesFallbackUpstream` ✅
3. Fresh install → `.defaultTable` (`:200-203`) — covered by `freshInstallGetsDefaultThreeRuleTable` (now also asserts haiku → `gpt-5.3-codex-spark` per DP-002 B at line 123) ✅

[C:100]

### 9. Removal-Replacement Reachability
Legacy `executorModel` / `advisorModel` retained as computed (RouterConfiguration.swift:20-22). All consumers continue reading via the computed read-through (`GatewayDaemon.swift:54,97`, `DoctorSnapshot.swift:14`, `ContentView.swift:422,440`). The 3 ContentView read sites use `executorModelDraft`/`advisorModelDraft` which now flow through `persistConfiguration` (rules-preserving canonical init). ✅ [C:100]

### 10. Term Consistency After Rename
No rename — backward-compatible computed accessors retained. ✅ [C:100]

### 11. ADR Action Completeness
- DP-001-P2 (Option A): ContentView remains UI-untouched; no new Settings tab. ✅
- DP-002 (Option A → now Option B): `ModelRouting.swift:62-66` includes `gpt-5.3-codex-spark` for haiku rule; comment at `:58-60` documents probe + DP-002 Option B; `Tests/CCRouterCoreTests/ModelRoutingTests.swift:67` and `RouterConfigurationMigrationTests.swift:123` updated to match. ✅
- DP-001 from cycle-1 review (Option A — fix ContentView callsites): VERIFIED — see Section 13 + RR-1 follow-up below.
- DP from Phase 2 plan DP-001 (probe model IDs + ship whitelist): probe ran 5 IDs, results recorded with Conclusion sections per DOC-1 fix. ✅

[C:95]

### 12. Reverse Regression Reasoning

**[Reverse Reasoning] Hypothetical regression #1 — RR-1 follow-up:**
- User action: any Settings save (auth file authorize, port change, executor model edit)
- Code path: `ContentView.swift:418-446` (`saveGatewaySettings` / `saveUpstreamSettings`) → `:484` `persistConfiguration(...)` → `:498-512` builds `updatedTable` preserving `existingTable.rules`, only replaces `fallback.upstreamModel` from draft → `:514-529` calls **canonical init** with explicit `routingTable: updatedTable, advisorRoute: updatedAdvisor`.
- Failure point would be: legacy init (rules: []) being invoked. Verified absent — `grep "RouterConfiguration(" ModelBridge/ContentView.swift` shows exactly 2 invocations (`:514`, `:541`), both canonical (named `routingTable:` + `advisorRoute:` parameters present in both).
- Auth-file authorize path at `:537-563` directly passes `currentConfiguration.routingTable` and `.advisorRoute` (no transformation).
- ✅ COVERED — RR-1 fix is durable. [C:100]

**[Reverse Reasoning] Hypothetical regression #2 — direct legacy-init invocation by future caller:**
- The legacy init at `RouterConfiguration.swift:62-94` still hardcodes `rules: []`. A future callsite (new code) could regress.
- Current callers of legacy init: `Tests/CCRouterCoreTests/BridgeRegressionTests.swift:17-28` and `StreamingBridgeIntegrationTests.swift:17-28` (per plan Task 7 step 1+2 these are intentionally preserved). No production code uses legacy init.
- Risk: low for Phase 2; future-engineer footgun. Could be mitigated by adding `@available(*, deprecated, message: "Use canonical init…")` annotation to the legacy init. **Not a Phase 2 gap** — flagged as advisory FOOTGUN-1.
- Covered by forward check: ✅ no production caller. [C:90]

**[Reverse Reasoning] Hypothetical regression #3 — failing Phase 1 test masks Phase 2 regression in shared CI:**
- `swift test` exits non-zero because `StreamingBridgeIntegrationTests.toolUseBlockFollowedByMoreTextOpensNewBlockIndex` fails (2 issues at `StreamingBridgeIntegrationTests.swift:549, 555`). All 25 Phase 2 tests pass individually.
- This failure is in untracked Phase 1 code. It does not invalidate Phase 2 routing logic, but it pollutes the green-suite signal: a future engineer running `swift test` will see "1 failure" and may not investigate which suite.
- Covered by forward check: ⚠️ NEW FINDING — tracked as **Pre-existing Issue PE-3** below.
- Action Required: investigate Phase 1 streaming bug or quarantine the test until fixed. [C:95]

### 13. Rules Compliance Audit

**[R6 Audit]** Completion claims verifiable:
- execution-report.md "Tasks: 10/10 completed" — but only 8 task results listed (Tasks 6 + 7 missing from report body). Code does contain Task 6+7 deliverables. R6 violated at the report level (claim "10/10" without evidence text for 6/7); the underlying code IS verified. [C:95]
- Phase 2 test runs: ModelRoutingTests 9/9 ✅, ModelRoutingBridgeIntegrationTests 5/5 ✅, RouterConfigurationMigrationTests 5/5 ✅, RouterConfigurationStoreTests 6/6 ✅ (verified by re-running).

**[R9 Audit]** Files edited vs plan:
- Plan-specified: `ModelRouting.swift`, `RouterConfiguration.swift`, `RouterConfigurationStore.swift`, `AnthropicBridge.swift`, 4 test files, 3 probe scripts + 3 research reports — all present.
- Unplanned (Phase 2 cycle-1): `AnthropicProtocol.swift` (legitimate per plan Task 7 step 4), `_probe_common.py` (helper extraction; benign).
- Unplanned (Phase 2 cycle-2 = RR-1 fix): `ContentView.swift:484-563` rewrite of `persistConfiguration` + `persistSubscriptionAuthAuthorization` to use canonical init. This is in scope of the cycle-1 review's DP-001 Option A user-confirmed; classified as `secondary fix to honor user-approved DP`. ✅
- Pre-existing uncommitted (Phase 1): `LocalHTTPServer.swift`, `ResponsesClient.swift`, `SubscriptionSession.swift`, plus untracked Phase 1 test files. Same as cycle-1 PE-1.

**[Decision Audit]** UI/View modifications: 1 file touched (`ContentView.swift`) — internal logic only (init parameters), no user-visible UI change. DP-001-P2 A still honored. ✅

### 13.1 Test Completeness Audit

| File | @Test | Assertions | Shell? | Core path covered |
|---|---|---|---|---|
| ModelRoutingTests.swift | 9 | yes (50 #expect across all 3 new files) | no | ✅ |
| RouterConfigurationMigrationTests.swift | 5 | yes (incl. fresh install + DP-002 haiku assertion at :123) | no | ✅ |
| RouterConfigurationStoreTests.swift | 6 (1 new: `saveWithRoutingTablePersistsExpectedRules`) | yes | no | ✅ |
| ModelRoutingBridgeIntegrationTests.swift | 5 | yes (model/effort/verbosity wire-level) | no | ✅ |

[Test Completeness]
- Required tests: 25 (9 + 5 + 6 + 5)
- Files exist: 4 / 4
- Non-empty: 25 / 25
- Core path covered: 24 / 25 (still missing: TraceLogger record assertion for `upstream_model` — see T-trace below; carried from cycle-1 as advisory)
- Shell tests: 0

**Phase 2 test execution result (verified live):** All 25 Phase 2 tests pass.

**Note on RR-1 specific regression test:** No new test was added that exercises the ContentView callsite specifically (i.e., construct a `RouterConfiguration` via legacy init and assert rules-wipe occurs, or simulate `persistConfiguration` and assert preservation). The fix instead removes the vulnerability by making both ContentView callsites use canonical init. The existing `saveWithRoutingTablePersistsExpectedRules` test confirms the canonical-init save round-trip preserves rules; RR-1 is now structurally impossible from the production code path.

---

## Part 2: Design Fidelity Audit

### 14. Spec Value Comparison (Gap A)

- [A] `ModelRoute` shape — dev-guide §117 spec matches `ModelRouting.swift:5-15` ✅
- [A] Default table entries (DP-002 B applied):
  - opus → gpt-5.4 / xhigh / low ✅ (`:64`)
  - sonnet → gpt-5.4 / xhigh / low ✅ (`:65`)
  - haiku → gpt-5.3-codex-**spark** / xhigh / low ✅ (`:66`) — Note: dev-guide §117 wrote "gpt-5.3-codex" for haiku; DP-002 Option B chosen by user 2026-04-22 supersedes this. Plan source narrative + `ModelRouting.swift:58-60` comment + research-report Conclusion all converge on the spark variant. ✅
  - fallback → gpt-5.4 / xhigh / low ✅ (`:68`)
  - defaultAdvisorRoute → gpt-5.4 / xhigh / low ✅ (`:71-75`)
- [A] `/responses` payload top-level fields (dev-guide §53) — all 14 fields present at `AnthropicBridge.swift:747-762` in spec order: `model`, `instructions`, `input`, `tools`, `tool_choice`, `parallel_tool_calls`, `reasoning`, `store`, `stream`, `include`, `service_tier`, `prompt_cache_key`, `text`, `client_metadata` ✅
- [A] Constants: `parallel_tool_calls: true`, `store: false`, `stream: true`, `service_tier: "priority"`, `include: ["reasoning.encrypted_content"]` — all verbatim ✅

### 15. Data Flow Connectivity Tracing (Gap B)

- [B] Fresh install → defaultTable: `loadOrCreate` → `normalizedConfiguration:200-203` → `.defaultTable` → `RouterConfiguration.routingTable` → `AnthropicBridge.runInitialTurn:288 .resolve(for:)` → `makeResponsesPayload(route:)` → wire `model` field. ✅ connected
- [B] Per-Claude-model fan-out: `/v1/messages` body `model` → `AnthropicBridge:288` → `route.upstreamModel` → wire payload. ✅ connected
- [B] `PendingToolTurn` route persistence: `:288 resolvedRoute` → `:485-490` and `:616-621` PendingToolTurn storage → `:194` continuation read → `:193 makeResponsesPayload(route: pending.resolvedRoute,...)`. ✅ connected
- [B] Settings save preserves rules (RR-1 fix): `currentConfiguration.routingTable` → `ContentView.swift:498 existingTable` → `:499-506 updatedTable(rules: existingTable.rules, ...)` → `:521 routingTable: updatedTable` → `configurationStore.save` → disk → next `loadOrCreate` returns same rules. ✅ connected end-to-end (re-verified by re-reading file)

### 16. Old Code Removal Completeness (Gap C)

- [C] Dev-guide §119 "硬用 `configuration.executorModel` 改成 routingTable.resolve" — `grep configuration.executorModel\|configuration.advisorModel AnthropicBridge.swift` → 0 matches ✅
- [C] Dev-guide §120 "makeResponsesPayload 硬编码 xhigh / low" — `:737-762` reads `route.reasoningEffort` / `route.textVerbosity`; no hardcoded literal `"xhigh"` or `"low"` in `makeResponsesPayload`. ✅

### 17. Missing Feature Detection (Gap D)

- [D] Three value types `ModelRoute` / `ModelRoutingRule` / `ModelRoutingTable` — ✅ at `ModelRouting.swift:5-51`
- [D] `resolve(for:)` substring match — ✅ at `:42-50`
- [D] Auto-migration: ✅ `RouterConfiguration.swift:130-145` (decode) + `RouterConfigurationStore.swift:194-199` (normalize)
- [D] `PendingToolTurn.resolvedRoute` — ✅ at `AnthropicBridge.swift:809`
- [D] `upstream_model` trace — ✅ at `:205, 302, 590` (3 sites)
- [D] 3 probe scripts — ✅
- [D] 3 research reports + Conclusion sections — ✅ (DOC-1 from cycle-1 fixed: `grep -l Conclusion docs/research/2026-04-22-*.md` returns 3)
- [D] Acceptance criteria #4-#5 (3-model fan-out → ≥2 upstreams) — verified by `defaultTableHasExpectedShape` test asserting opus → gpt-5.4, haiku → gpt-5.3-codex-spark (2 distinct upstream values). ✅

### 18. Implementation Quality Comparison (Gap E)

- [E] Substring matching design (dev-guide §117) — `ModelRouting.swift:42-50` uses `needle.contains(rule.match.lowercased())` on `claudeModel.lowercased()`. ✅ faithful
- [E] 3-branch `normalizedConfiguration` (plan §459-502) — implemented as specified at `RouterConfigurationStore.swift:190-212`. ✅ faithful
- [E] Legacy init still hardcodes `rules: []` (`RouterConfiguration.swift:78-94`) — but per RR-1 fix, NO production code calls legacy init anymore (only `BridgeRegressionTests` + `StreamingBridgeIntegrationTests`, intentionally preserved per plan Task 7 steps 1-2). The previous "silent degradation" reading of this is now NEUTRALIZED at the production layer. The legacy init itself is unchanged; the fix moved the responsibility upstream to ContentView. ✅ resolved at the user-facing layer.

---

## Gap Summary

### Critical (blocking)
**None.** RR-1 from cycle-1 confirmed fixed.

### Standard (open advisory)

**Gap T-trace [C:90]** — *carried from cycle-1*
- Location: `AnthropicBridge.swift:205, 302, 590` emits `upstream_model`.
- Gap: No unit test reads `TraceLogger` records to assert the field's literal presence. Integration tests assert HTTP payload `model` (wire-level), which confirms routing works but not trace emission.
- Impact: Low — code inspection confirms emission; grep verify guards accidental removal.
- Recommendation: acceptable to ship; add a `TraceLoggerObserver`-style test in Phase 6 if a recall harness needs it.

### Minor

**Gap REPORT-1 [C:95]: execution-report.md omits Task 6 and Task 7 from "Task Results (Phase 2)"**
- Location: `docs/06-plans/execution-report.md:7-68` lists Tasks 1, 2, 3, 4, 5, 8, 9, 10 but skips 6 (trace `upstream_model`) and 7 (ModelRoutingBridgeIntegrationTests). The header at `:5` claims "10/10 completed".
- Underlying implementation IS done — verified at `AnthropicBridge.swift:205,302,590` and `Tests/CCRouterCoreTests/ModelRoutingBridgeIntegrationTests.swift` (5 @Test, all pass).
- Impact: Low (documentation accuracy); could mislead a downstream auditor into thinking the trace and integration tests were skipped.
- Fix recommendation: append two entries between Task 5 and Task 8 documenting trace emission and the 5 integration tests.

**Gap FOOTGUN-1 [C:80]: Legacy init at `RouterConfiguration.swift:62-94` still hardcodes `rules: []`**
- Not a current bug (no production caller after RR-1 fix), but a future-engineer footgun. A new callsite that calls legacy init will silently wipe rules.
- Mitigation options: (a) `@available(*, deprecated, message: "Use canonical init; legacy init wipes routingTable.rules")` annotation, (b) rename legacy init to `init(legacyOnly:)`, (c) accept risk and rely on code review.
- Impact: Low. Tests still legitimately use legacy init per plan Task 7 step 1+2.
- Recommendation: add deprecation annotation when convenient; not blocking.

---

## Pre-existing Issues

**PE-1 [C:90]: Uncommitted Phase 1 source files in working tree**
- Files: `Sources/CCRouterCore/LocalHTTPServer.swift`, `ResponsesClient.swift`, `SubscriptionSession.swift` (modified) + `Sources/CCRouterCore/AnthropicSSEEncoder.swift`, `Sources/CCRouterCore/IR/`, plus untracked Phase 1 test files (`BridgeRegressionTests.swift`, `IRBlockConversionTests.swift`, `MockResponsesEventStream.swift`, `ResponsesClientStreamingTests.swift`, `StreamingBridgeIntegrationTests.swift`).
- Phase 2 depends on these (`ModelRoutingBridgeIntegrationTests` uses `InMemoryBodyWriter`). Same as cycle-1 PE-1. Not introduced by Phase 2.
- Recommendation: commit Phase 1 artifacts before Phase 2's commit (or in same commit with clear message).

**PE-2 [C:80]: AnthropicProtocol.swift modification missing from execution-report.md file list**
- Cycle-1 finding. Same status.
- Plan Task 7 step 4 directs the `textOnlyFixture` extension legitimately. Report omission only.

**PE-3 [C:95] (NEW): `StreamingBridgeIntegrationTests.toolUseBlockFollowedByMoreTextOpensNewBlockIndex` fails**
- File: `Tests/CCRouterCoreTests/StreamingBridgeIntegrationTests.swift:549, 555` — Phase 1 untracked test.
- Failure: `(blockStartFrames.count → 2) >= 3` and `(indices → [0, 1]).contains(2)` — the test expects 3 content_block_start frames but bridge only emits 2. The third text block (after a tool_use) is not opening a new content block index.
- Investigation: this is a real Phase 1 streaming bug — when the upstream produces text → function_call → text in one stream, the bridge collapses the third text segment into the same block index instead of opening index 2. The fixture at `StreamingBridgeIntegrationTests.swift:430-495` is correctly shaped (output_index 0,1,2; correct `output_item.added`/`done` envelopes for each).
- Impact on Phase 2: NONE for routing correctness. But the test failure means `swift test` exits non-zero, which masks a future Phase 2 regression in shared CI signals.
- Origin: Phase 1 implementation (untracked `Sources/CCRouterCore/IR/` + `AnthropicSSEEncoder.swift`). Not introduced by Phase 2.
- Root-cause hypothesis (not verified — would require reading the SSE encoder): the IR-to-Anthropic encoder likely tracks "current text block index" mutably and resets it only on stream completion, not on tool_use boundary. When tool_use appears in the middle, the next text block reuses the previous text index instead of incrementing.
- Fix recommendation: this is Phase 1 scope. Either (a) fix in Phase 1 follow-up before committing Phase 1 artifacts, or (b) commit with `@Test(.disabled("phase-1-bug-#TODO"))` quarantine. Do NOT silently delete the test.

---

## Rules Audit

- **R6 (Evidence before claims):** execution-report.md header claims "10/10 completed" but only 8 task results documented. R6 partially violated at the report level. Underlying code is verified — Tasks 6+7 are done. Recommend updating the report (REPORT-1).
- **R9 (Fix obstacles, don't bypass):** RR-1 fix took the correct path — modified ContentView callsites (the obstacle's actual location), did not bypass by adding workarounds elsewhere. ✅ honored.
- **Decision authority:** DP-001-P2 A still honored (no UI surface added). DP-002 B applied per cycle-1 user confirmation. ✅

---

## Real-Machine Acceptance Items (manual)

Per dev-guide Phase 2 §137-145, deferred to manual verification (not exercisable here):

1. ⚠️ Manual: `bash scripts/smoke_local_gateway.sh`
2. ⚠️ Manual: 3 Claude models (opus / sonnet / haiku) → ≥2 distinct upstream_model values in trace.
3. ⚠️ Manual: `grep upstream_model /tmp/modelbridge-trace.jsonl | jq -r .upstream_model | sort -u`

After RR-1 fix, the production code path is now safe — Settings UI saves preserve `routingTable.rules`. The defaultTable's haiku → gpt-5.3-codex-spark + opus/sonnet → gpt-5.4 will produce ≥2 distinct upstream_model values on first install.

---

## Low-Confidence Appendix (C < 80)

None. All findings C ≥ 80.

---

## Decisions

### [DP-001] Phase 1 streaming test failure — Phase 2 commit policy (`recommended`)

**Gap:** `StreamingBridgeIntegrationTests.toolUseBlockFollowedByMoreTextOpensNewBlockIndex` fails (PE-3). The test is Phase 1 scope, not introduced by Phase 2, but blocks the green-suite signal.

**Options:**

| | A: Fix Phase 1 bug first | B: Quarantine and commit Phase 2 | C: Commit Phase 2 over red |
|---|---|---|---|
| Behavior | Phase 1 bug fixed in IR encoder (text→tool_use→text now opens index 2). Suite returns to 79/79 green. | Test marked `.disabled("phase-1-bug")` with TODO. Suite green. Bug deferred. | Phase 2 commits while suite reports 1 failure. Future regressions in Phase 2 mixed with PE-3 noise. |
| Implementation | Read `Sources/CCRouterCore/AnthropicSSEEncoder.swift` (untracked) + IR codec, find block-index reset logic, fix. ~1-2 hour task; Phase 1 scope. | 1-line annotation + TODO comment in test file. | Zero change. |
| Risk | Phase 2 commit delayed by Phase 1 work. | TODO debt; risk of forgetting (suite shows 78 pass instead of failure flag). | Eroded CI signal for Phase 2 and beyond. Engineers may ignore "1 failure expected". |

**Chosen:** A — fix Phase 1 streaming bug before proceeding to Phase 3.

### [DP-002] Legacy init deprecation (`recommended`)

**Gap:** `RouterConfiguration.swift:62-94` legacy init still hardcodes `rules: []` (FOOTGUN-1). No current production caller, but a future engineer adding a new callsite would silently wipe routing rules.

**Options:**

| | A: Add deprecation annotation | B: Rename to legacyOnly init | C: Leave as-is |
|---|---|---|---|
| Behavior | New callers see Xcode warning "Use canonical init; legacy init wipes routingTable.rules". Existing tests still compile. | New callers must explicitly write `RouterConfiguration.legacyInit(...)` — intent self-documents. Tests need rename. | No protection; rely on review. |
| Implementation | Add `@available(*, deprecated, message: "...")` to init at `:62`. ~1 line. | Rename + update 2 test files (`BridgeRegressionTests.swift:17`, `StreamingBridgeIntegrationTests.swift:17`). ~5-10 lines across 3 files. | 0 lines. |
| Risk | Tests emit deprecation warnings (intentional; tests legitimately use it for legacy fixtures). Could pollute build output. | Slightly more invasive; touches Phase 1 untracked tests. | Future regression risk = future RR-1 reincarnation. |

**Chosen:** A — add deprecation annotation.

### [DP-003] execution-report.md Tasks 6 + 7 omission (`recommended`)

**Gap:** REPORT-1. `docs/06-plans/execution-report.md:7-68` skips Task 6 and Task 7. Underlying implementation done.

**Options:**

| | A: Append missing entries | B: Leave as-is |
|---|---|---|
| Behavior | Report accurately reflects 10/10. Future auditor sees full task chain. | Report claims 10/10 but documents 8/10. Mismatch invites confusion. |
| Implementation | Append ~10 lines describing Task 6 (3 trace sites) + Task 7 (5 integration tests + AnthropicProtocol.textOnlyFixture extension). | Zero change. |
| Risk | None. | Future audit cycles may flag the same gap repeatedly. |

**Chosen:** A — append missing entries.

---

## Verdict

✅ **Implementation complete.** RR-1 fix is durable and verified. All 25 Phase 2 tests pass. No new plan-vs-code drift. 1 advisory gap (T-trace, carried), 3 minor / non-blocking findings (REPORT-1, FOOTGUN-1, PE-3). 3 decisions posted for user review (DP-001 = how to handle Phase 1 PE-3, DP-002 = optional legacy-init deprecation, DP-003 = report cleanup).

---

## Summary Output

### Plan-vs-Code (Part 1)
- Total gaps: 3 (Critical: 0, Standard: 1 [T-trace], Minor: 2 [REPORT-1, FOOTGUN-1]) — reported: 3 (all C≥80), filtered: 0
- Tests: 25 required, 25 exist, 24 covered, shell: 0
- All 25 Phase 2 tests pass live (verified by individual `swift test --filter`).

### Design Fidelity (Part 2)
- [A] Spec values: 14 checked, 0 mismatched
- [B] Data flow: 4 traced, 0 disconnected (added RR-1 fix path)
- [C] Old code: 2 checked, 0 still present
- [D] Features: 8 checked, 0 missing (added DOC-1 closure check)
- [E] Quality: 3 compared, 0 silent degradation (RR-1 resolved at production layer)

### Rules Audit
- R6: 8/10 task entries documented in report; underlying code verified for all 10. Report cleanup recommended (DP-003).
- R9: 0 bypass; RR-1 fix corrected in-place per cycle-1 DP-001 A.
- Decision authority: DP-001-P2 A and cycle-2 DP-001 A both honored.

### Pre-existing
- PE-1: Uncommitted Phase 1 changes (carried)
- PE-2: AnthropicProtocol.swift not in report file list (carried)
- PE-3 (NEW): Phase 1 streaming test fails — text→tool_use→text block-index regression
