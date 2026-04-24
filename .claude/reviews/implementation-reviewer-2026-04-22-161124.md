## Implementation Review Summary
**Status:** complete
**Plan:** docs/06-plans/2026-04-22-phase2-model-routing-plan.md
**Design doc:** docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md (Phase 2 section)
**Started:** 2026-04-22-161124

---

## Part 1: Plan-vs-Code Verification

### 1. Deletion Verification
No file/component deletions specified in Phase 2. Section N/A.

### 2. Struct/Interface Field Comparison

**ModelRoute** (plan Task 1 §107-121 vs `Sources/CCRouterCore/ModelRouting.swift:5-15`):
- `upstreamModel: String` ✅
- `reasoningEffort: String` ✅
- `textVerbosity: String` ✅
- Codable + Sendable + Equatable ✅
[C:100] match

**ModelRoutingRule** (plan §123-132 vs `ModelRouting.swift:19-27`):
- `match: String` + `route: ModelRoute` ✅ [C:100]

**ModelRoutingTable** (plan §134-155 vs `ModelRouting.swift:30-51`):
- `rules: [ModelRoutingRule]` + `fallback: ModelRoute` ✅
- `resolve(for:)` lowercased substring-contains, first match wins, else fallback ✅ [C:100]

**defaultTable / defaultAdvisorRoute** (plan §158-173 vs `ModelRouting.swift:55-72`):
- 3 rules: opus/sonnet/haiku → gpt-5.4/gpt-5.4/gpt-5.3-codex all xhigh+low ✅
- fallback: gpt-5.4/xhigh/low ✅
- defaultAdvisorRoute: gpt-5.4/xhigh/low ✅ [C:100]

**RouterConfiguration stored fields** (plan Task 3 §289-304 vs `RouterConfiguration.swift:3-22`):
- Stored `routingTable: ModelRoutingTable` ✅
- Stored `advisorRoute: ModelRoute` ✅
- Computed `executorModel`/`advisorModel` deriving from table/advisor ✅ [C:100]

**PendingToolTurn** (plan Task 5 §929-935 vs `AnthropicBridge.swift:794-800`):
- `resolvedRoute: ModelRoute` added ✅ [C:100]

### 3. UI Element Verification
No UI changes in Phase 2 scope (DP-001-P2 A: ContentView unchanged). Confirmed: `git diff --stat HEAD -- ModelBridge/ContentView.swift ModelBridge/SettingsView.swift` → empty output. ✅ [C:100]

### 4. "No Matches Found" Red-Flag Check
- `grep 'claude_model\|reasoning_effort\|text_verbosity\|resolved_route_match' Sources/ Tests/` → 0 matches (expected — Phase 6 fields correctly excluded). ✅ [C:100]
- `grep 'configuration\.executorModel\|configuration\.advisorModel' AnthropicBridge.swift` → 0 matches in bridge (plan Task 5 expected). ✅ [C:100]

### 5. Integration Point Verification

Plan says AnthropicBridge calls `routingTable.resolve(for:)` → passes `ModelRoute` into `makeResponsesPayload`:
- `AnthropicBridge.swift:288` — `let resolvedRoute = configuration.routingTable.resolve(for: anthropicModel)` ✅
- `AnthropicBridge.swift:290-296` — `makeResponsesPayload(route: resolvedRoute, ...)` ✅
- `AnthropicBridge.swift:193-199` — continuation payload: `makeResponsesPayload(route: pending.resolvedRoute, ...)` ✅
- `AnthropicBridge.swift:687-693` — advisor sub-call: `makeResponsesPayload(route: configuration.advisorRoute, ...)` ✅
- `AnthropicBridge.swift:568-574` — second pass: `makeResponsesPayload(route: resolvedRoute, ...)` ✅
- `AnthropicBridge.swift:727-753` — signature: `makeResponsesPayload(route: ModelRoute, ...)` with `model`/`reasoning.effort`/`text.verbosity` all reading from `route` ✅ [C:100]

### 6. Never Trust Existing Code
Verified `RouterConfiguration.swift` and `RouterConfigurationStore.swift` actually modified (not just "exists"):
- `RouterConfiguration.swift` has manual Codable with migration decode (plan Task 3 §366-407) ✅
- `RouterConfigurationStore.swift` has `normalizedConfiguration` with 3-branch logic at `:190-212` (stored → use; legacy → single-rule; fresh → defaultTable) ✅ [C:100]

### 7. Unauthorized Deferral Detection
- Plan Task 6 `responses_out_initial` trace — has `upstream_model` at `AnthropicBridge.swift:302` ✅
- Plan Task 6 `responses_out_continuation` trace — has `upstream_model` at `AnthropicBridge.swift:205` ✅
- Plan Task 6 `responses_out_advisor_continuation` trace — has `upstream_model` at `AnthropicBridge.swift:580` ✅
- Plan Task 4 `freshInstallGetsDefaultThreeRuleTable` — asserted at `RouterConfigurationMigrationTests.swift:102-125` ✅
- Plan Task 7 integration tests — all 5 tests present in `ModelRoutingBridgeIntegrationTests.swift` (opus/haiku/fallback/advisor/pendingToolTurn) ✅
- No deferrals detected. [C:95]

### 8. Conditional Branch Verification
3-branch `normalizedConfiguration` (plan Task 3 §465-502):
1. `stored.routingTable` present → use it (`:192-193`) ✅
2. Legacy `executorModel` or env var present → single-rule table (`:194-199`) ✅
3. Fresh install → `.defaultTable` (`:200-203`) ✅

Tests cover branches (1) `newFormatConfigLoadsWithRoutingTableIntact`, (2) `legacyFlatFieldsMigrateToSingleRuleFallback` + `envExecutorModelOverridesFallbackUpstream`, (3) `freshInstallGetsDefaultThreeRuleTable`. [C:100]

### 9. Removal-Replacement Reachability
Legacy `executorModel`/`advisorModel` no longer stored but retained as computed. All app-side readers (`GatewayDaemon.swift:54-55,97-98`, `SettingsView.swift:401,410,501`, `ContentView.swift:59-60,612-613`) continue reading through computed properties. ✅ [C:100]

### 10. Term Consistency After Rename
No rename — legacy fields preserved as computed for backward compatibility. [C:100]

### 11. ADR Action Completeness
Phase 2 DP-001 chosen C: probe user-requested IDs, ship whitelist only in defaultTable. Verified:
- `defaultTable` uses only whitelist (`gpt-5.4`, `gpt-5.3-codex`), not `gpt-4.5` or `gpt-5.3-codex-spark` ✅
- Probe ran all 5 models and recorded in `docs/research/2026-04-22-upstream-model-probe.md` ✅
- `gpt-5.3-codex-spark` returned 200 (surprise — noted for Phase 6 UI per DP-001) ✅

DP-002 chosen A (probe effort values): all 4 values (low/medium/high/xhigh) probed and all returned 200. Recorded in `docs/research/2026-04-22-reasoning-effort-probe.md`. ✅ [C:95]

### 12. Reverse Regression Reasoning

**[Reverse Reasoning] Hypothetical regression #1 — rules-wipe via legacy init:**
- User action: opens Settings after fresh install, authorizes subscription auth file (no intent to change routing).
- Code path: `ContentView.swift:520 persistSubscriptionAuthAuthorization` → constructs `RouterConfiguration` via **legacy init** at `:523-539` passing only `executorModel` + `advisorModel` strings.
- Failure point: legacy init at `RouterConfiguration.swift:77-94` always builds `ModelRoutingTable(rules: [], fallback: ...)` — the 3-rule `defaultTable` that a fresh install received is **discarded** and replaced with an empty-rules table.
- `configurationStore.save` → `normalizedConfiguration` sees `configuration.routingTable != nil` → persists empty rules to disk.
- Next user request with `claude-haiku-…` — no match in empty rules → falls through to `fallback.upstreamModel` (gpt-5.4). Acceptance criteria #4+#5 (3-model fan-out to ≥2 upstreams) silently broken for any user who clicks anything in Settings.
- Covered by forward check: ❌ — NEW FINDING. `freshInstallGetsDefaultThreeRuleTable` tests only the initial load; no test covers load-then-save-via-legacy-init round-trip.
- Action Required: **fix required before ship** — see Finding RR-1 below and `Decisions/[DP-001]`.

**[Reverse Reasoning] Hypothetical regression #2 — env override wipes stored rules after legacy-path migration:**
- User with legacy config.json (has `executorModel` only, no `routingTable`) sets `CC_ROUTER_EXECUTOR_MODEL=foo` env var.
- Code path: `normalizedConfiguration:194` → legacy migration builds empty-rules table. Then `resolveConfiguration:127-133` → env override replaces fallback.upstreamModel but preserves stored rules (= empty from migration).
- Result: executorModel is `foo`, rules are `[]`. This is expected behavior since the legacy config had no rules to preserve.
- Covered by forward check: ✅ — `envExecutorModelOverridesFallbackUpstream` confirms. No issue. [C:90]

### 13. Rules Compliance Audit

**[R6 Audit]** Completion claims in execution-report.md: 10 task ✅ marks. All with corresponding grep/test verifications in the plan's Verify sections. Test run captured in `.claude/test-reports/test-run-2026-04-22T16-09-56.md` showing 79/79 pass. ✅ verified.

**[R9 Audit]** Files edited vs plan's target files:
- Plan-specified: ModelRouting.swift, RouterConfiguration.swift, RouterConfigurationStore.swift, AnthropicBridge.swift, ModelRoutingTests.swift, RouterConfigurationMigrationTests.swift, RouterConfigurationStoreTests.swift, ModelRoutingBridgeIntegrationTests.swift, 3 probe scripts + 3 research reports.
- Unplanned: `AnthropicProtocol.swift` (added `textOnlyFixture` extension — but plan Task 7 step 4 directs this; legitimate), `_probe_common.py` (helpers extraction; benign).
- Pre-existing uncommitted (Phase 1 leftovers): `LocalHTTPServer.swift`, `ResponsesClient.swift`, `SubscriptionSession.swift`. Not touched by Phase 2 (git log shows no recent commits; diffs are Phase 1 streaming infra per execution-report.md Phase 1 section). See Pre-existing Issues.

**[Decision Audit]** View/UI modifications: 0. DP-001-P2 A honored. ✅

### 13.1 Test Completeness Audit

- Task 2 `ModelRoutingTests.swift` — 9 @Test (plan expected 9; context mentions "×11" — discrepancy, see finding T-count). All 9 have assertions; core path covered. ✅
- Task 4 `RouterConfigurationMigrationTests.swift` — 5 @Test (plan expected 5). All have assertions. ✅
- Task 4 `RouterConfigurationStoreTests.swift` — added `saveWithRoutingTablePersistsExpectedRules`. ✅
- Task 6 trace `upstream_model` — **no unit-level assertion**. Code at `AnthropicBridge.swift:205, 302, 580` emits the field, but no test reads `TraceLogger` records to confirm presence. Integration tests (`ModelRoutingBridgeIntegrationTests`) inspect `mock.capturedRequests` (the HTTP payload) — that confirms routing works at the wire level, but does NOT verify the `upstream_model` key literally appears in trace logs. Plan Task 6 Verify is grep-only (confirmed by `grep 'upstream_model' AnthropicBridge.swift` = 3 matches, not a behavioral assertion). Cycle-1 verifier's advisory T1 Gap #1 still open. See finding T-trace. ⚠️
- Task 7 `ModelRoutingBridgeIntegrationTests.swift` — 5 @Test (plan expected 5). All have wire-level assertions on model/effort/verbosity. ✅

[Test Completeness]
- Required tests: 19 (9+5+1+5 task-driven counts, using 9 for Task 2 per actual plan code)
- Files exist: 4/4
- Non-empty tests: 19/19
- Core path covered: 18/19 (missing: trace upstream_model presence)
- Shell tests: 0

---

## Part 2: Design Fidelity Audit

### 14. Spec Value Comparison (Gap A)

- [A] `ModelRoute.upstreamModel / reasoningEffort / textVerbosity` struct fields — dev-guide §117 spec matches `ModelRouting.swift:5-15` ✅ match
- [A] Default table entries (plan §57-67, dev-guide §117):
  - opus → gpt-5.4 / xhigh / low ✅ (`ModelRouting.swift:60`)
  - sonnet → gpt-5.4 / xhigh / low ✅ (`:61`)
  - haiku → gpt-5.3-codex / xhigh / low ✅ (`:62`)
  - fallback → gpt-5.4 / xhigh / low ✅ (`:64`)
  - advisorRoute → gpt-5.4 / xhigh / low ✅ (`:67-71`)
- [A] /responses payload top-level fields (dev-guide §53 + plan §53) — all 14 fields present at `AnthropicBridge.swift:737-752` in the plan's specified order ✅
- [A] `parallel_tool_calls: true`, `store: false`, `stream: true`, `service_tier: "priority"`, `include: ["reasoning.encrypted_content"]` — all present verbatim ✅

### 15. Data Flow Connectivity Tracing (Gap B)

- [B] Fresh install → defaultTable flow:
  - Source: `loadOrCreate:32-48` (no existing file) → `normalizedConfiguration:200-203` (fresh branch) → `.defaultTable` → `resolveConfiguration:134-135` (stored.routingTable present) → `RouterConfiguration.routingTable`
  - Consumer: `AnthropicBridge.runInitialTurn:288` (reads `configuration.routingTable.resolve(for: anthropicModel)`)
  - ✅ connected end-to-end

- [B] Per-Claude-model fan-out flow:
  - Source: `/v1/messages` body `model` field → decoded at AnthropicBridge
  - Component: `ModelRoutingTable.resolve(for: anthropicModel)` at `AnthropicBridge.swift:288`
  - Consumer: `makeResponsesPayload(route:)` — body `model` at `:738` reads `route.upstreamModel`
  - ✅ connected

- [B] PendingToolTurn route persistence:
  - Source: `resolvedRoute` computed at `AnthropicBridge.swift:288`
  - Storage: `PendingToolTurn(..., resolvedRoute: resolvedRoute)` at `:480` and `:611`
  - Consumer: continuation turn at `:194` reads `pending.resolvedRoute`
  - ✅ connected

### 16. Old Code Removal Completeness (Gap C)

- [C] Dev-guide §119: "硬用 `configuration.executorModel` 改成 routingTable.resolve" — `grep configuration.executorModel\|configuration.advisorModel AnthropicBridge.swift` → 0 matches ✅ removed
- [C] Dev-guide §120: "makeResponsesPayload 硬编码 xhigh / low" — body at `:737-752` now reads `route.reasoningEffort` / `route.textVerbosity` (no hardcoded string literal `"xhigh"` or `"low"` in `makeResponsesPayload`) ✅ removed

### 17. Missing Feature Detection (Gap D)

- [D] ModelRoute / ModelRoutingRule / ModelRoutingTable value types — ✅ found at `ModelRouting.swift:5-51`
- [D] `resolve(for:)` substring match — ✅ found at `ModelRouting.swift:42-50`
- [D] Auto-migration for legacy `executorModel` — ✅ found at `RouterConfiguration.swift:130-145` (decode) and `RouterConfigurationStore.swift:194-199` (normalize)
- [D] `PendingToolTurn.resolvedRoute` — ✅ found at `AnthropicBridge.swift:799`
- [D] `upstream_model` trace field — ✅ found at `AnthropicBridge.swift:205, 302, 580`
- [D] 3 probe scripts — ✅ found (`probe_upstream_models.py`, `probe_reasoning_effort.py`, `probe_text_verbosity.py`)
- [D] 3 research reports — ✅ found with real probe data

### 18. Implementation Quality Comparison (Gap E)

- [E] Substring matching design approach (dev-guide §117: "对 Claude model 小写 substring 匹配") — code uses `needle.contains(rule.match.lowercased())` on `claudeModel.lowercased()` at `ModelRouting.swift:42-47` — ✅ faithful
- [E] 3-branch `normalizedConfiguration` (plan §459-502) — code implements stored → legacy → fresh path correctly — ✅ faithful
- [E] Legacy init preserves rules (DP-001-P2 A narrative at plan:78: *"保存时若用户只改了这两个字符串，整个 `routingTable.rules` 保持不变"*) — **plan self-contradicts**: the narrative promises rules-preserving, but the code block at plan §330-359 specifies `rules: []`. Implementation follows the code block (`RouterConfiguration.swift:82-86`: `ModelRoutingTable(rules: [], fallback: ...)`). ❌ **silent degradation** when measured against the narrative — but ✅ faithful when measured against the plan's code block. See Finding RR-1 in Section 12 — this is a blocking bug regardless of which plan side "wins" since it violates Phase 2 acceptance #4+#5 the moment the Settings UI saves anything.

---

## Gap Summary

### Critical (blocking)

**Gap RR-1 [C:95]: Legacy init wipes `routingTable.rules` on save via Settings UI**
- Location: `Sources/CCRouterCore/RouterConfiguration.swift:77-94` (legacy init) invoked from `ModelBridge/ContentView.swift:496-512` (`persistConfiguration`) and `:520-539` (`persistSubscriptionAuthAuthorization`).
- Mechanism: Legacy init always constructs `ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: executorModel, ...))`. When the user saves anything via Settings (auth file authorize, port change, responsesURL change), the in-memory `RouterConfiguration` is rebuilt via legacy init — `currentConfiguration.routingTable.rules` is not passed in → lost → persisted as empty on disk.
- Consequence: After any Settings save, fresh-install's 3-rule defaultTable is gone. Next `claude-opus-4-7` / `claude-sonnet-4-6` / `claude-haiku-…` request — all land on `fallback.upstreamModel`. Phase 2 acceptance #4+#5 (≥2 distinct upstream_model values) silently broken.
- Plan-vs-narrative conflict: Plan DP-001-P2 A narrative at plan:78 promised rules would be preserved. Plan code block at §330-359 contradicts by hardcoding `rules: []`. Implementation followed the code.
- No test coverage: `freshInstallGetsDefaultThreeRuleTable` tests initial load only; `saveWithRoutingTablePersistsExpectedRules` tests canonical-init save, not legacy-init save.

### Standard (open, non-blocking)

**Gap T-trace [C:95]: No unit assertion that `upstream_model` appears in TraceLogger records**
- Location: `AnthropicBridge.swift:205, 302, 580` emits the field.
- Gap: Integration tests assert the HTTP payload `model` field (via `mock.capturedRequests`), but no test reads TraceLogger records to confirm the trace line actually contains `upstream_model`. Plan Task 6's Verify is grep-only (`grep 'upstream_model' AnthropicBridge.swift` ≥ 3).
- Impact: Low — code emits correctly; regression would need to accidentally delete one of the three `upstream_model` lines. Grep-based verify catches accidental removal.
- Status: Cycle-1 verifier's T1 Gap #1 (left as advisory). Still open as acknowledged advisory.
- Recommendation: Acceptable to ship given (a) code inspection confirms emission, (b) dev-guide Phase 2 acceptance #7 requires real-trace grep which only manual/smoke verify can do, (c) the integration tests do verify the routing itself works.

### Minor (documentation / convention)

**Gap DOC-1 [C:90]: `docs/research/2026-04-22-upstream-model-probe.md` lacks `## Conclusion` section**
- Plan skeleton at plan §1294-1298 shows a Conclusion block listing "Add to default routing table / Reject / Surface to Phase 6 Routing UI picker".
- Actual report has only the table header + 5 result rows. No conclusion, no Phase 6 action flag.
- Impact: Low — raw results are present; a reader must draw their own conclusion.
- Recommendation: add a Conclusion section to each of the 3 reports documenting the decision (especially the `gpt-5.3-codex-spark` 200 → Phase 6 UI candidate decision).

### Informational (scope / count)

**Gap T-count [C:90]: Actual ModelRoutingTests has 9 @Test, user context claims "×11"**
- Actual file: 9 tests (plan Task 2 §192-270 also specifies 9: opus/sonnet/haiku/mixedcase/noMatch/emptyRules/firstWins/defaultTable/codableRoundTrip).
- User context paragraph says "ModelRoutingTests × 11" — appears to be a transcription error in the dispatch context; plan actually specified 9 and implementation delivered 9.
- No gap against plan. Flagged for accuracy only.

---

## Pre-existing Issues

### PE-1 [C:85]: Uncommitted Phase 1 changes in working tree
- Files: `Sources/CCRouterCore/LocalHTTPServer.swift`, `Sources/CCRouterCore/ResponsesClient.swift`, `Sources/CCRouterCore/SubscriptionSession.swift`.
- `git log HEAD` last-touched these files at commit `c5bb7c9` (pre-Phase-1). Diff shows streaming infrastructure (`HTTPResponse.Body` enum with `.data`/`.stream` cases, `HTTPBodyWriter` protocol, `streamEvents` on `ResponsesClient`) which matches Phase 1 execution-report.md Task 3 + Task 4 descriptions.
- Investigation: these are Phase 1 outputs that were never committed. Phase 1 execution-report.md at line 120 shows Task 7/8 were marked blocked, and the implementer may have paused before committing. Phase 2 legitimately depends on these changes (`ModelRoutingBridgeIntegrationTests` uses `InMemoryBodyWriter` and `.stream` body case).
- Recommendation: these changes should be committed alongside Phase 2's commit, or Phase 1 should be committed separately first. **Do not discard.** Discarding would break Phase 2 build.
- Fix recommendation: commit Phase 1 artifacts first (`LocalHTTPServer.swift`, `ResponsesClient.swift`, `SubscriptionSession.swift`, plus Phase 1's own `IR/`, `AnthropicSSEEncoder.swift`, `ResponsesClientStreamingTests.swift`, `IRBlockConversionTests.swift`, `BridgeRegressionTests.swift`) with a commit message attributing to Phase 1, then commit Phase 2 artifacts.

### PE-2 [C:70]: `AnthropicProtocol.swift` modified without attribution in execution-report.md
- `git diff HEAD -- Sources/CCRouterCore/AnthropicProtocol.swift` shows added `textOnlyFixture(model:)` extension (a test helper).
- Plan Task 7 step 4 at §1106-1123 explicitly directs this addition. Legitimate.
- But `execution-report.md "Files Modified (Phase 2)"` (lines 74-85) does not list `AnthropicProtocol.swift` — minor discrepancy in the report.
- Recommendation: add `Sources/CCRouterCore/AnthropicProtocol.swift` to the report's Phase 2 files list.

---

## Rules Audit

- R6 (Evidence before claims): ✅ All 10 task completion claims in execution-report.md are backed by verify-command output. Test run 79/79 pass verified in `.claude/test-reports/test-run-2026-04-22T16-09-56.md`.
- R9 (Fix obstacles, don't bypass): ✅ No bypass detected. Phase 1 pre-existing files are legitimately dependencies, not detours.
- Decision authority: ✅ DP-001-P2 A honored (ContentView unchanged). All other UI behavior unchanged.

---

## Real-Machine Acceptance Items (manual verification required)

Per dev-guide Phase 2 §137-145, the following are deferred to real-machine verification (outside automated review scope):

1. ⚠️ Manual: `bash scripts/smoke_local_gateway.sh` passes.
2. ⚠️ Manual: `ANTHROPIC_MODEL=claude-opus-4-7 claude --bare -p 'Reply OPUSOK.'` + sonnet + haiku → 3 requests each hit a different configured upstream.
3. ⚠️ Manual: `grep upstream_model /tmp/modelbridge-trace.jsonl | jq -r .upstream_model | sort -u` outputs ≥ 2 distinct values.

These cannot be exercised in the review sandbox. The unit/integration tests cover the **code path** for all three (wire-level payload + trace field emission). Real-machine verification remains the user's responsibility.

**⚠️ Real-machine verification blocked by Finding RR-1:** if the user runs the smoke/manual acceptance without fixing RR-1, and the smoke script happens to trigger any Settings-UI save path, the acceptance items #4-#5 from the dev-guide (3 Claude models → ≥2 upstreams) will fail. Fix RR-1 first.

---

## Probe Surprise — DP-001 Phase 6 follow-up

`gpt-5.3-codex-spark` returned 200 from the real probe. Per plan DP-001 chosen C (ship whitelist + probe user-requested IDs), this is **not** a Phase 2 blocker — Phase 2 intentionally ships only the conservative whitelist (`gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`) in `defaultTable`. Plan Task 8 step 3 at §1320 explicitly forbids auto-updating `defaultTable` from probe results; the surfacing happens in Phase 6 UI.

**However**, the user should decide whether to:
- **Option A (default — per plan):** preserve current `defaultTable` (whitelist only) until Phase 6 UI is built, when users can manually opt in.
- **Option B (accelerate):** update `ModelRouting.swift` `defaultTable` now to add a 4th entry using `gpt-5.3-codex-spark` for some Claude model, shipping the probe win immediately.

See Decisions/[DP-002] below.

---

## Low-Confidence Appendix (C < 80)

None. All findings C ≥ 85.

---

## Decisions

### [DP-001] Legacy init rules-wipe bug (`blocking`)

**Gap:** Plan DP-001-P2 A narrative promised saving only `executorModel`/`advisorModel` would preserve `routingTable.rules`. Actual legacy init at `RouterConfiguration.swift:77-94` hardcodes `rules: []`. Triggered by ContentView's `persistConfiguration` (line 496) and `persistSubscriptionAuthAuthorization` (line 520), which both call legacy init. Consequence: any Settings UI save wipes the fresh-install defaultTable's 3 rules, silently breaking Phase 2 acceptance #4+#5 (3-model fan-out) after the first user interaction.

**Options:**

| | A: Fix ContentView callsites | B: Change legacy init signature | C: Defer to Phase 6 |
|---|---|---|---|
| Behavior | Settings save preserves routingTable.rules | Settings save preserves routingTable.rules via explicit `preservingRules:` param | Settings save silently wipes rules until Phase 6 UI lands |
| Implementation | Rewrite 2 ContentView callsites at `:496-512` and `:520-539` to use canonical init with `currentConfiguration.routingTable` + `.advisorRoute` (~16 lines changed across both methods). Legacy init remains, but only tests use it. | Add optional `preservingRules: [ModelRoutingRule]? = nil` to legacy init + update both ContentView callsites to pass `currentConfiguration.routingTable.rules`. Plus update `BridgeRegressionTests` (doesn't pass it; default nil OK). ~10 lines changed in 3 files. | Zero code change. Document the regression in execution-report.md + README. |
| Risk | Low — canonical init is already exercised by `saveWithRoutingTablePersistsExpectedRules`. ContentView compile check will flag if any field is missed. | Low but footgun remains for any future caller that forgets `preservingRules:`. | High — users who touch Settings experience silent fan-out loss. Phase 2 acceptance #4+#5 fails in practice despite passing tests. |

**Chosen:** A — user confirmed 2026-04-22. Applied to `ModelBridge/ContentView.swift:496-512` (`persistConfiguration` — builds updatedTable preserving rules, only updates fallback.upstreamModel from draft) and `:520-539` (`persistSubscriptionAuthAuthorization` — passes existing routingTable + advisorRoute directly). Legacy init retained for test fixtures.

### [DP-002] `gpt-5.3-codex-spark` probe-confirmed — update `defaultTable` now or wait for Phase 6? (`recommended`)

**Gap:** Real probe confirmed `gpt-5.3-codex-spark` returns 200 (an unexpected win). Current `defaultTable` only includes the conservative whitelist. Plan Task 8 step 3 at §1320 explicitly defers this decision to the user.

**Options:**

| | A: Preserve defaults (per plan) | B: Accelerate — add now |
|---|---|---|
| Behavior | `defaultTable` unchanged: opus/sonnet → gpt-5.4, haiku → gpt-5.3-codex. Users can opt in via Phase 6 UI. | `defaultTable` updated: e.g. haiku → gpt-5.3-codex-spark (or as sonnet), shipping probe win immediately. |
| Implementation | Zero change. | 1–2 line change in `Sources/CCRouterCore/ModelRouting.swift:60-62`, and update `ModelRoutingTests.defaultTableHasExpectedShape` (`Tests/CCRouterCoreTests/ModelRoutingTests.swift:63-69`) to match. |
| Risk | Zero regression risk; plan's intent preserved. Users stuck with whitelist until Phase 6. | `gpt-5.3-codex-spark` is probe-verified but not field-tested for sustained load / multi-turn behavior; one 200 response is not the same as long-term stability. |

**Chosen:** B — user confirmed 2026-04-22. Applied: `Sources/CCRouterCore/ModelRouting.swift:62` haiku rule now maps to `gpt-5.3-codex-spark` (probe-confirmed 200 on 2026-04-22). Updated assertions: `Tests/CCRouterCoreTests/ModelRoutingTests.swift:67` and `Tests/CCRouterCoreTests/RouterConfigurationMigrationTests.swift:123`. Rationale recorded in ModelRouting.swift source comment + in `docs/research/2026-04-22-upstream-model-probe.md` Conclusion section.

---

## Verdict

❌ **1 gap requires remediation (RR-1).** Test coverage green, routing logic correct, DP fidelity honored, probes ran and reported truthfully. The blocking issue is a data-loss bug in the Settings-save path caused by the legacy init wiping `routingTable.rules`, which breaks Phase 2 acceptance #4+#5 the moment any user interaction saves configuration. One standard advisory (T-trace, carried from cycle-1) and two minor doc items remain.

---

## Summary Output

### Plan-vs-Code (Part 1)
- Total gaps: 4 (Critical: 1 [RR-1], Standard: 1 [T-trace], Minor: 2 [DOC-1, T-count]) — reported: 4 (all C≥80), filtered: 0
- Tests: 19 required, 19 exist, 18 covered, shell: 0
- RR-1: `RouterConfiguration.swift:77-94` legacy init hardcodes `rules: []`, called from `ContentView.swift:496, 520` — wipes fresh-install rules on any save.
- T-trace: no test asserts TraceLogger records contain `upstream_model` (code emits correctly; advisory carried from cycle-1).
- DOC-1: 3 research reports lack Conclusion sections.
- T-count: dispatch context said "×11"; actual 9 (plan also said 9). No real gap.

### Design Fidelity (Part 2)
- [A] Spec values: 14 checked, 0 mismatched
- [B] Data flow: 3 traced, 0 disconnected
- [C] Old code: 2 checked, 0 still present
- [D] Features: 7 checked, 0 missing
- [E] Quality: 3 compared, 1 silent degradation (RR-1 counted here too — legacy init narrative vs code mismatch)

### Rules Audit
- R6: 10 completion claims, all verified via plan Verify commands + test report
- R9: 0 bypass; Phase 1 pre-existing files are legitimate dependencies
- Decision authority: DP-001-P2 A honored (ContentView untouched)

### Pre-existing
- PE-1: Uncommitted Phase 1 changes in working tree (should be committed)
- PE-2: `AnthropicProtocol.swift` mod legitimate per plan but missing from execution-report's file list

### Verdict
❌ 1 blocking gap (RR-1) requires remediation; 2 decisions posted for user review (DP-001, DP-002).
