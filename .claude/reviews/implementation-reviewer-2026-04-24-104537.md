## Implementation Review Summary
**Status:** complete
**Plan:** docs/06-plans/2026-04-24-phase6-observability-settings-ui-plan.md
**Design doc:** docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md §Phase 6 (lines 311-353)
**Started:** 2026-04-24-104537

---

## Part 1 — Plan vs Code

### Task 1: Trace routing fields

**Plan expectations:**
- `ResolvedRoute` struct in `ModelRouting.swift`
- `ModelRoutingTable.resolveWithMatch(for:)` returning `ResolvedRoute`
- `PreparedTurn.resolvedRoute` + `PendingToolTurn.resolvedRoute` upgraded to `ResolvedRoute`
- `handleOutputBlocks` + `runAdvisorSubcallAndSecondPass` signature upgrade
- 5 emit points carry 5 routing fields (`claude_model` / `upstream_model` / `reasoning_effort` / `text_verbosity` / `resolved_route_match`):
  - `anthropic_in` (post-prepareTurn)
  - `responses_out_initial`
  - `responses_out_continuation`
  - `anthropic_out` main via `logRequestOutcome`
  - `anthropic_out` stream_aborted branch inline emit
- New test file `TraceLoggerRoutingFieldsTests.swift` with 7 cases covering opus/sonnet/haiku + fallback + end-to-end + stream_aborted regression

**Evidence:**
- `Sources/CCRouterCore/ModelRouting.swift:30-38` declares `ResolvedRoute`
- `Sources/CCRouterCore/ModelRouting.swift:65-73` declares `resolveWithMatch`
- `Sources/CCRouterCore/AnthropicBridge.swift:1358` `PreparedTurn.resolvedRoute: ResolvedRoute`
- `Sources/CCRouterCore/AnthropicBridge.swift:1371` `PendingToolTurn.resolvedRoute: ResolvedRoute`
- `Sources/CCRouterCore/AnthropicBridge.swift:766` `handleOutputBlocks(..., resolvedRoute: ResolvedRoute, ...)`
- `Sources/CCRouterCore/AnthropicBridge.swift:882` `runAdvisorSubcallAndSecondPass(..., resolvedRoute: ResolvedRoute, ...)`
- 5 emit sites confirmed:
  - `anthropic_in`: `AnthropicBridge.swift:73-82` (post-prepareTurn)
  - `responses_out_initial`: `AnthropicBridge.swift:555-561`
  - `responses_out_continuation`: `AnthropicBridge.swift:1274-1280` (via `logContinuationDispatch`)
  - `anthropic_out` main: `AnthropicBridge.swift:1200-1220` (`logRequestOutcome` signature extended with `claudeModel` + `resolvedRoute` default-nil)
  - `anthropic_out` stream_aborted: `AnthropicBridge.swift:638-649` inline emit carries all 5 fields
- `Tests/CCRouterCoreTests/TraceLoggerRoutingFieldsTests.swift` exists with 8 `@Test` methods (plan specified 7; extra = stream_aborted secondary case; no gap)

**Verdict:** ✅ Complete [C:95]

### Task 2: TraceDiagnostics per-Claude-model aggregation

**Plan expectations:**
- `ClaudeModelMetrics` struct (count/success/failure/p50/p95/lastUpstreamModel/recentErrorReasons)
- `TraceDiagnostics.perClaudeModelMetrics: [String: ClaudeModelMetrics]`
- `TraceLogger.diagnostics(limit:)` populates per-model state via session_id → claude_model lookup
- 5 test cases covering 3-model distribution / success+failure mix / p50+p95 / lastUpstream / empty

**Evidence:**
- `Sources/CCRouterCore/TraceDiagnostics.swift:6-32` defines `ClaudeModelMetrics` with exact fields specified
- `Sources/CCRouterCore/TraceDiagnostics.swift:50` exposes `perClaudeModelMetrics`
- `Sources/CCRouterCore/TraceDiagnostics.swift:98` `.empty` initializes as `[:]`
- `Sources/CCRouterCore/TraceLogger.swift:96-98, 140-162, 204-236` implement sessionID→claude_model lookup + state aggregation + p50/p95 percentile + lastUpstream + errors
- `Tests/CCRouterCoreTests/TraceDiagnosticsPerModelAggregationTests.swift` has 5 `@Test` methods (matches plan spec)

**Verdict:** ✅ Complete [C:95]

### Task 3: Dashboard Routing insights (AppModel layer)

**Plan expectations:**
- `RoutingInsightRow` struct
- `AppModel.routingInsights: [RoutingInsightRow]` computed property
- Fixed 3 rows (opus/sonnet/haiku)
- `currentRouteLabel` via `resolveWithMatch(for: "claude-\(key)-probe")`
- `metrics` sourced from `doctorSnapshot.traceDiagnostics.perClaudeModelMetrics[key]`

**Evidence:**
- `ModelBridge/ContentView.swift:9-14` declares `RoutingInsightRow`
- `ModelBridge/ContentView.swift:317-336` implements computed property with fixed 3 rows, `resolveWithMatch` for label, diagnostics lookup for metrics

**Minor spec deviation:** The metrics lookup is `metricsMap.first { $0.key.lowercased().contains(key) }?.value` (line 328), not `perClaudeModelMetrics[key]` as plan specified. This is semantically broader (tolerates `"claude-opus-4-7"` keys from actual trace) and consistent with how `claude_model` values are stored (full model strings). No gap — implementation is more correct than literal plan [C:80].

**Verdict:** ✅ Complete [C:85]

### Task 4: Dashboard Routing insights UI

**Plan expectations:**
- Insert `routingInsightsSection` after `recentSection` in ContentView body
- `MBCard(padding: 10)` with 3 rows (Claude model + `→ <upstreamModel> · <effort>` + metric text / "—")
- Visual parity with `kpiSection`

**Evidence:**
- `ModelBridge/ContentView.swift:956` inserts `routingInsightsSection` in body
- `ModelBridge/ContentView.swift:1178-1212` implements the section with `MBCard(padding: 10, background: MBColor.paperDim)`, 3 rows rendered via `ForEach` of `model.routingInsights`, `→ <currentRouteLabel>` secondary text, metric text right-aligned
- No click drill-down implemented

**Dev-guide deviation:** Dev-guide line 328 says "点击单行可下钻到该 Claude 模型的详细 trace 列表". The Phase 6 plan's Task 4 does NOT include click-to-drill; the plan (approved by user) is the source of truth. Drill-down is out of the current plan's scope. Flag as design-vs-plan gap, not plan-vs-code gap. See Design Fidelity section D below [C:85].

**Verdict:** ✅ Complete (plan-scope) [C:90]

### Task 5: Bridge + Daemon hot reload

**Plan expectations:**
- `AnthropicBridge.routingTable` + `advisorRoute` as mutable fields
- `AnthropicBridge.updateRouting(table:, advisorRoute:) async` actor method (with trace emit)
- `GatewayDaemon.applyRoutingUpdate(table:, advisorRoute:) async` delegation
- Test file `AnthropicBridgeRoutingHotReloadTests.swift` with 3 cases (executor hot reload, advisor hot reload, concurrency)

**Evidence:**
- `Sources/CCRouterCore/AnthropicBridge.swift:24-25` mutable `routingTable` + `advisorRoute`
- `Sources/CCRouterCore/AnthropicBridge.swift:308` `updateRouting` actor method
- `Sources/CCRouterCore/GatewayDaemon.swift:75-77` `applyRoutingUpdate` delegation
- All resolve call sites read `self.routingTable` / `self.advisorRoute` (AnthropicBridge.swift:414, 467, 544 confirmed)
- `Tests/CCRouterCoreTests/AnthropicBridgeRoutingHotReloadTests.swift` has 3 `@Test` methods (204 lines)

**Verdict:** ✅ Complete [C:95]

### Task 6: AppModel routing draft state

**Plan expectations:**
- `RoutingRuleDraft`, `RouteDraft`, `RoutingOptions` types
- `AppModel` publishes `routingRulesDraft`, `fallbackRouteDraft`, `advisorRouteDraft`
- Methods: `syncRoutingDraftsFromConfiguration`, `addRoutingRule`, `removeRoutingRule`, `moveRoutingRule`, `saveRoutingAndApply`, `saveLegacyUpstreamSettings`
- `saveRoutingAndApply`: validate (trim + non-empty keyword), build table, call `configurationStore.save`, call `daemon.applyRoutingUpdate`
- `executorModelDraft` + `advisorModelDraft` deleted; `persistConfiguration` callsites switched to `currentConfiguration.executorModel` / `.advisorModel` compat props
- Backward-compat layer preserved (`RouterConfiguration.executorModel` computed property, `DoctorSnapshot.executorModel/.advisorModel`, legacy `StoredConfiguration` Codable)

**Evidence:**
- `ModelBridge/ContentView.swift:16, 38, 44` declare `RoutingRuleDraft`, `RouteDraft`, `RoutingOptions`
- `ModelBridge/ContentView.swift:89-92` publish draft state
- `ModelBridge/ContentView.swift:526-612` all methods present including trim validation + non-empty keyword check at line 557-560
- `ModelBridge/ContentView.swift:610` calls `daemon.applyRoutingUpdate`
- No `executorModelDraft` / `advisorModelDraft` references in ContentView or SettingsView (grep confirmed zero hits)
- `RouterConfiguration.executorModel` compat property preserved (per execution report)

**Verdict:** ✅ Complete [C:90]

### Task 7: Settings Routing editor UI

**Plan expectations:**
- `UpstreamSettingsTab` Upstream MBSection keeps only Responses URL
- Three new MBSection: "Routing rules" / "Fallback route" / "Advisor route"
- `RoutingRuleDraftRow` with keyword TextField + 3 Pickers + delete
- `RouteDraftPickers` reusable component
- Save button "Save routing + upstream" action `saveRoutingAndApply`
- `routingSaveError` displayed as red text
- New Xcode test file `SettingsRoutingEditorTests.swift` with 5 cases (Add / Edit / Delete / Move / saveRoutingAndApply invokes daemon+store)

**Evidence:**
- `ModelBridge/SettingsView.swift:391-400` Upstream MBSection has only Responses URL
- `ModelBridge/SettingsView.swift:402-434` three new MBSections present
- `ModelBridge/SettingsView.swift:599-637` `RoutingRuleDraftRow` + `RouteDraftPickers` defined
- `ModelBridge/SettingsView.swift:525-528` Save button with correct action + label
- `ModelBridge/SettingsView.swift:403-407` routing save error rendered inside "Routing rules" section
- `ModelBridgeTests/SettingsRoutingEditorTests.swift` exists (143 lines, 12 `@Test` methods covering Add/Edit/Delete/Move/Fallback/Advisor drafts)

**Gap — T7-save:** Plan step 4 case 5 requires: `saveRoutingAndApply → configurationStore 被调用 + daemon.applyRoutingUpdate 被调用（用测试替身）`. The test file's opening FIXME comment (lines 1-7) acknowledges this case is NOT implemented because AppModel lacks injectable dependencies. This is a test-coverage shortfall per the plan spec. The implementing agent documented the gap rather than silently skipping (R9 compliant), and the core-path logic is covered by `AnthropicBridgeRoutingHotReloadTests` at the bridge layer. Recommend: mark as T7-test-deferred and address in a follow-up (add protocol wrapper for `configurationStore` + `daemon`) [C:90].

**Gap — T7-pbxproj:** `SettingsRoutingEditorTests.swift` and `SettingsTokenStatusTests.swift` exist on disk but are not added to `project.pbxproj` PBXSourcesBuildPhase for `ModelBridgeTests` target. Execution report notes: "pbxproj edit blocked by protection hook". Without pbxproj inclusion, `xcodebuild test -only-testing:ModelBridgeTests` does not execute these files. **Note:** per user input, these files ARE now being compiled (the 12 `@MainActor` errors in `SettingsTokenStatusTests.swift` confirm Xcode IS trying to build them), so the pbxproj step has been resolved since the report was written [C:80].

**Gap — T7-shell:** `SettingsRoutingEditorTests.swift` tests are real assertions (not shells). `SettingsTokenStatusTests.swift` (Task 10 deliverable) contains 3 of 6 cases with `#expect(true)` placeholders (lines 22, 31, 92) — these are shell tests per this review's definition. See Task 10 gap below [C:95].

**Verdict:** ⚠️ Partial — UI complete; test coverage incomplete (saveRoutingAndApply integration case missing + Task 10 shell tests) [C:85]

### Task 8: Advisor route independent verification

**Plan expectation:** Covered via Task 5 case 2 (`hotReloadChangesAdvisorRouteOnlyForAdvisorSubcall`). Only needed supplemental Xcode test if UI merged Advisor into Fallback.

**Evidence:**
- `Tests/CCRouterCoreTests/AnthropicBridgeRoutingHotReloadTests.swift` has 3 `@Test` including advisor independence case
- `ModelBridge/SettingsView.swift:432-434` has separate "Advisor route" MBSection (not merged with Fallback)

**Verdict:** ✅ Complete — no supplemental test needed per plan's conditional logic [C:95]

### Task 9: DoctorSnapshot + BridgeDoctorStatus accessTokenPreview

**Plan expectations:**
- `DoctorSnapshot.accessTokenPreview: String?` (nil when unauthenticated)
- `BridgeDoctorStatus.accessTokenPreview: String?`
- `SubscriptionCredentials.accessTokenPreview` preview helper (`"abcd…5678"` format)
- `AnthropicBridge.doctorStatus()` fills preview when ready
- `GatewayDaemon.snapshot` + `/health` handler fill field
- `DoctorSnapshotTests.accessTokenPreviewExposedWhenAuthenticated` case

**Evidence:**
- `Sources/CCRouterCore/DoctorSnapshot.swift:27, 57, 86` field declared + threaded through init
- `Sources/CCRouterCore/AnthropicBridge.swift:1461` `BridgeDoctorStatus.accessTokenPreview: String?`
- `Sources/CCRouterCore/SubscriptionSession.swift:21-25` `accessTokenPreview` computed property emits `prefix(4) + "…" + suffix(4)` (matches plan exact format)
- `Sources/CCRouterCore/AnthropicBridge.swift:283, 293, 303` doctorStatus fills preview only when `credentials` exists
- `Sources/CCRouterCore/GatewayDaemon.swift:67, 117` both snapshot paths fill `accessTokenPreview`
- `Tests/CCRouterCoreTests/DoctorSnapshotTests.swift` has 4 `@Test` methods (includes accessTokenPreview case)

**Verdict:** ✅ Complete [C:95]

### Task 10: Settings Token status UI

**Plan expectations:**
- `AppModel` publishes `isRefreshingToken`, `tokenRefreshError`
- `refreshTokenNow()` constructs per-call `SubscriptionSessionLoader` and calls `refreshAndReload()`
- `startTokenStatusPolling()` 30-second loop
- `UpstreamSettingsTab` mounts `.task { await model.startTokenStatusPolling() }`
- "Token status" MBSection with 4 rows (Access token / Last refresh / State / Refresh)
- Xcode test file `SettingsTokenStatusTests.swift` with 3 cases

**Evidence:**
- `ModelBridge/ContentView.swift:93-94` publishes flags
- `ModelBridge/ContentView.swift:614-630` `refreshTokenNow` per-call loader pattern
- `ModelBridge/ContentView.swift:632-637` polling loop with 30s sleep (plan Task 10 step 1 advisory C2-A2 inline patch applied — no `stopTokenStatusPolling`)
- `ModelBridge/SettingsView.swift:481-518` Token status MBSection with all 4 rows + error display
- `ModelBridge/SettingsView.swift:532-534` `.task { await model.startTokenStatusPolling() }` mounted on SettingsShell
- `ModelBridgeTests/SettingsTokenStatusTests.swift` exists with 6 `@Test` methods

**Gap — T10-shell:** `SettingsTokenStatusTests.swift` contains shell tests:
- Line 22: `#expect(true) // placeholder — real assertion requires AppModel snapshot injection`
- Line 31: `#expect(true) // placeholder — real assertion requires AppModel snapshot injection`
- Line 45-48: tautological assertions (`#expect(model.isRefreshingToken == false)` both before and after — tests "fast path" but asserts flag value is false regardless)
- Line 58: `#expect(model.tokenRefreshError == nil || model.tokenRefreshError != nil)` — vacuously true
- Line 75: `#expect(errorExists || model.tokenRefreshError == nil)` — vacuously true
- Line 92: `#expect(true)`

Plan Task 10 step 3 explicitly required 3 cases with real assertions:
- `tokenPreviewRendersFromSnapshot` → "UI 显示正确" (not implemented; snapshot injection missing)
- `refreshNowTogglesBusyFlag` → "isRefreshingToken 从 false → true → false" (partially; test can't observe true state because `@MainActor` suspension ordering)
- `refreshFailurePopulatesError` → "tokenRefreshError 非 nil" (not verified; current assertion is tautological)

The test file's top FIXME comment acknowledges the limitation: "real assertion requires AppModel snapshot injection". R9 compliant documentation but plan requirements are not met [C:95].

**Gap — T10-compile:** Per user note, the Xcode ModelBridgeTests target currently fails to build with 12 `@MainActor` isolation errors in `SettingsTokenStatusTests.swift` (called out in `.claude/test-reports/test-run-2026-04-24T10-42-47.md`). Root cause: `AppModel()` is `@MainActor`-isolated but test methods are not marked `@MainActor`; `#expect` macro expands to nonisolated autoclosures that cannot access `@MainActor` properties. **User stated this is being fixed in a separate "Step 7 fix"**, so it is out of scope for this review's remediation list; noted as awareness item [C:95].

**Verdict:** ⚠️ Partial — UI + AppModel complete; test coverage is shell-level with a compile blocker [C:85]

### Task 11: E2E integration

**Plan expectations:** `swift test` green, Xcode test green, smoke script green, manual hot reload + Dashboard + Token UI acceptance.

**Evidence (from execution report + test-run report):**
- `swift test`: 214/214 green
- `xcodebuild build`: SUCCEEDED
- `bash scripts/smoke_local_gateway.sh`: passed
- `xcodebuild test -only-testing:ModelBridgeTests`: FAILS to build (Task 10 compile blocker above)
- Manual acceptance items: **pending manual verification** (hot reload smoke, Dashboard Routing insights, Token Refresh now)

**Verdict:** ⚠️ Partial — SPM + build + smoke green; Xcode test target blocked (addressed in Step 7 fix per user); 3 manual acceptance items unverified [C:90]

---

### Test Completeness Audit

| Task | Required test file | Exists | Non-empty | Core path covered | Shell |
|---|---|---|---|---|---|
| 1 | `TraceLoggerRoutingFieldsTests.swift` | ✅ | ✅ | ✅ (8 cases) | 0 |
| 2 | `TraceDiagnosticsPerModelAggregationTests.swift` | ✅ | ✅ | ✅ (5 cases) | 0 |
| 5 | `AnthropicBridgeRoutingHotReloadTests.swift` | ✅ | ✅ | ✅ (3 cases) | 0 |
| 7 | `SettingsRoutingEditorTests.swift` | ✅ | ✅ | ⚠️ (12/5 cases; saveRoutingAndApply case missing) | 0 (but 1 required case absent) |
| 9 | `DoctorSnapshotTests.swift` (extended) | ✅ | ✅ | ✅ | 0 |
| 10 | `SettingsTokenStatusTests.swift` | ✅ | ✅ | ❌ (assertions tautological or `#expect(true)`) | 6 |

**[Test Completeness]**
- Required tests: 6
- Files exist: 6
- Non-empty tests: 6
- Core path covered: 4 fully + 1 partially (Task 7) = 4.5
- Shell tests: 6 (all in `SettingsTokenStatusTests.swift`)

---

### Pre-existing Issues

**Flaky pre-existing tests:** `firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta`, `cancellationViaOnTerminationStopsParser` — timing-sensitive, pass on retry. Execution report confirms these are not Phase 6 regressions. No remediation required for Phase 6.

**Git status note:** The project's `git status` shows 16 modified files + many untracked files (test fixtures, IR support files, Resources). These are intentional additions from prior phases (Phase 2-5 deliverables). Reviewer sampled the following for relevance to Phase 6 claims and found them consistent:
- `Sources/CCRouterCore/TraceDiagnostics.swift` (Task 2 target)
- `Sources/CCRouterCore/TraceLogger.swift` (Task 2 target)
- `Sources/CCRouterCore/AnthropicBridge.swift` (Task 1/5/9 target)
- `Sources/CCRouterCore/RouterConfiguration.swift` (compat layer per Task 6)
- `ModelBridge/ContentView.swift` (Tasks 3/4/6/10)
- `ModelBridge/SettingsView.swift` (Tasks 7/10)

No evidence of pre-existing issues that need action beyond the Step 7 fix for `@MainActor`.

---

## Part 2 — Design Fidelity (dev-guide Phase 6)

### [A] Spec values

| Spec | Design (dev-guide §Phase 6) | Code | Match |
|---|---|---|---|
| Trace fields | `claude_model` / `upstream_model` / `reasoning_effort` / `text_verbosity` / `resolved_route_match` (fallback literal `"fallback"`) | `AnthropicBridge.swift:78-82, 557-561, 645-649, 954-958, 1214-1220, 1276-1280` | ✅ match |
| Dashboard 3 rows | haiku / sonnet / opus | `ContentView.swift:318-322` (opus / sonnet / haiku; order reversed from dev-guide phrasing but user prompt confirms opus-first) | ✅ match (user confirmed order) |
| Token preview | access_token 前/后缀 | `SubscriptionSession.swift:22-24` `prefix(4) + "…" + suffix(4)` | ✅ match |

### [B] Data flow connectivity

| Path | Connected at | Verdict |
|---|---|---|
| Request → `prepareTurn` → `resolvedRoute` → trace emit | `AnthropicBridge.swift:73-82` (anthropic_in post-prepareTurn) | ✅ connected |
| Trace → `TraceLogger.diagnostics` → `perClaudeModelMetrics` → `AppModel.routingInsights` → `routingInsightsSection` | `TraceLogger.swift:235` → `AppModel.swift:317-336` → `ContentView.swift:1185` | ✅ connected |
| Settings Save → `saveRoutingAndApply` → `configurationStore.save` + `daemon.applyRoutingUpdate` → `bridge.updateRouting` → in-memory `routingTable` / `advisorRoute` swap | `ContentView.swift:587-611` → `GatewayDaemon.swift:75-77` → `AnthropicBridge.swift:308-322` | ✅ connected |
| Token refresh button → `refreshTokenNow` → `SubscriptionSessionLoader.refreshAndReload` → `doctorSnapshot` refresh | `ContentView.swift:614-630` | ✅ connected |

### [C] Old code removal

| Spec | Verdict |
|---|---|
| Remove `executorModelDraft` / `advisorModelDraft` | ✅ grep confirms zero hits in both ContentView + SettingsView |
| Replace single-value Executor/Advisor model TextFields with table editor | ✅ SettingsView.swift:391-400 keeps only Responses URL; 402-434 adds 3 routing MBSections |

### [D] Missing features

| Dev-guide feature | Implementation evidence | Verdict |
|---|---|---|
| Dashboard Routing insights section | `ContentView.swift:1178-1212` | ✅ found |
| Settings Routing editor (add/edit/delete) | `SettingsView.swift:402-426` | ✅ found |
| Settings Advisor route (separate or integrated) | `SettingsView.swift:432-434` (separate) | ✅ found |
| Settings Token status section | `SettingsView.swift:481-518` | ✅ found |
| Hot-reload save → applied without restart | `GatewayDaemon.swift:75-77` + bridge `updateRouting` actor method | ✅ found |
| **Click-to-drill-down on routing insights** (dev-guide line 328) | Not implemented; plan Task 4 did not include it | ❌ Design gap (out of plan scope) |
| Refresh failure re-login guidance | Minimal — error text only, no explicit re-login CTA in Token status section (compare `SettingsView.swift:466-478` `authInstructionText` for subscription auth) | ⚠️ partial — acceptable per plan but dev-guide line 324 says "refresh 失败时展示 re-login 引导" which implies dedicated guidance |

**Gap D-drilldown [C:85]:** Dev-guide Phase 6 line 328 specifies "点击单行可下钻到该 Claude 模型的详细 trace 列表". The Phase 6 plan Task 4 does NOT include this drill-down requirement; only the 3-row display. This is a design-to-plan omission that propagated to the code. Since the plan is user-approved, this is out of the current plan's scope. **Recommend** flagging for a follow-up Phase 6.1 or folding into Phase 7/dashboard iteration.

**Gap D-relogin [C:75]:** Dev-guide line 324 says "refresh 失败时展示 re-login 引导". Current Token status section shows only error text (`SettingsView.swift:513-517`). The existing Subscription auth section does have `authInstructionText` CTA when `requiresAuthAttention` is true, so the infrastructure exists; it is just not wired to Token status failures. Minor — listed in low-confidence appendix.

### [E] Quality / implementation approach

| Design approach | Code approach | Verdict |
|---|---|---|
| `perClaudeModelMetrics` via session_id → claude_model lookup | Matches plan: `TraceLogger.swift:96-162` | ✅ faithful |
| `updateRouting` atomic on actor | Actor method at `AnthropicBridge.swift:308` with mutable field replacement | ✅ faithful |
| 30s polling bound to view lifecycle via `.task` | `.task { await startTokenStatusPolling() }` at `SettingsView.swift:532-534`; no explicit stop method (SwiftUI auto-cancels) | ✅ faithful (matches plan C2-A2 advisory) |
| Whitelist-based Picker options | `RoutingOptions` enum at `ContentView.swift:44` | ✅ faithful |

No silent degradations detected.

---

## Rules Audit

**[R6 Audit] Completion claims:** Execution report makes 5 "completed" claims. All 5 are backed by file:line references + test commands (e.g. "8/8 TraceLoggerRoutingFieldsTests pass", "214 tests total: 203 pass; 2 timing flaky"). ✅ Evidence present.

**[R9 Audit] Files edited vs plan:** All files modified in execution report correspond to plan's target files:
- `AnthropicBridge.swift` (Tasks 1, 5, 9) ✅ plan-specified
- `ModelRouting.swift` (Task 1) ✅ plan-specified
- `TraceLogger.swift` + `TraceDiagnostics.swift` (Tasks 1, 2) ✅ plan-specified
- `GatewayDaemon.swift` (Task 5) ✅ plan-specified
- `DoctorSnapshot.swift` + `SubscriptionSession.swift` (Task 9) ✅ plan-specified
- `ContentView.swift` + `SettingsView.swift` (Tasks 3, 4, 6, 7, 10) ✅ plan-specified
- `Tests/CCRouterCoreTests/*` + `ModelBridgeTests/*` ✅ plan-specified

No unplanned edits identified.

**[Decision Audit] View modifications:** Three UI changes (Routing insights, Routing editor, Token status) — all specified in plan. Advisor route kept as separate MBSection rather than merged with Fallback; plan listed both options and code chose "separate", consistent with design doc. ✅ No unauthorized UI decisions.

---

## Reverse Reasoning

**Hypothetical regression 1:** User edits opus rule in Settings → clicks Save → sends opus request → trace does not reflect new route.

- User action: Settings edit → Save button
- Code path: `saveRoutingAndApply` (ContentView.swift:540) → `configurationStore.save` → `daemon.applyRoutingUpdate` (GatewayDaemon.swift:75) → `bridge.updateRouting` (AnthropicBridge.swift:308) → next request's `resolve` reads updated `self.routingTable` (AnthropicBridge.swift:414, 467, 544)
- Covered by forward check: ✅ Section Task 5 (hot reload tests) + Task 6 (saveRoutingAndApply logic)
- Action required: manual smoke per Task 11 pending-manual list

**Hypothetical regression 2:** Save routing with empty keyword → no validation → every subsequent request hits that rule → silent routing degradation.

- User action: Add rule → leave keyword empty → Save
- Code path: `saveRoutingAndApply:548-560` — trims whitespace, then checks `allSatisfy({ !$0.keyword.isEmpty })`; fails with `routingSaveError = "Routing rule keywords cannot be empty"` and bails before `configurationStore.save`
- Covered by forward check: ✅ threat-model spec in plan; no test verifying the validation branch. Minor test gap [C:85].
- Action required: add one test case `saveRoutingAndApplyRejectsEmptyKeywordAfterTrim` — **recommended, non-blocking**.

**Hypothetical regression 3:** Token Refresh button clicked with no auth file → user sees what?

- User action: Refresh now button
- Code path: `refreshTokenNow` → `SubscriptionSessionLoader(authFileURL: non-existent).refreshAndReload()` → throws → `tokenRefreshError = error.localizedDescription` + `statusText = "Token refresh failed: …"`
- UI: red error text at `SettingsView.swift:513-517`
- Covered by forward check: ✅ but the `SettingsTokenStatusTests` assertions that verify this are tautological.
- Action required: fix assertion logic (`tokenRefreshError` should be non-nil after intentional failure) — fold into Step 7 fix.

---

## Verdict

❌ **3 gaps require remediation:**

1. **T7-save (test coverage):** `saveRoutingAndApply` → `configurationStore` + `daemon.applyRoutingUpdate` call verification case missing from `SettingsRoutingEditorTests.swift`. Plan Task 7 step 4 case 5 required this. Requires injectable dependencies on AppModel. [C:90]
2. **T10-shell (test coverage):** `SettingsTokenStatusTests.swift` contains 6 shell tests with `#expect(true)` placeholders or tautological assertions. Plan Task 10 step 3 required 3 real assertion cases. [C:95]
3. **T10-compile (blocking Xcode test target):** `SettingsTokenStatusTests.swift` has 12 `@MainActor` isolation errors preventing `ModelBridgeTests` target from building. User indicates this is being fixed in Step 7. [C:95]

Plan-vs-Code implementation gaps: 0 (implementation matches plan fully)
Test-coverage gaps: 3
Pre-existing: 2 flaky tests (not Phase 6 regressions; no remediation needed)
Design fidelity mismatches: 1 blocking-scope + 1 minor (click-drill-down, re-login guidance) — both design-to-plan omissions, not plan-to-code

---

## Decisions

### [DP-P6R-001] Accept or close test-coverage gap T7-save (recommended)

**Gap:** Plan Task 7 step 4 case 5 required a test verifying `saveRoutingAndApply` calls `configurationStore.save` + `daemon.applyRoutingUpdate` with test doubles. Current `SettingsRoutingEditorTests.swift` top-comment FIXME acknowledges this is not implemented because AppModel lacks injectable dependencies. Production code path is covered at the bridge layer by `AnthropicBridgeRoutingHotReloadTests`, but the Settings-layer integration is not unit-tested.

**Options:**

| | A: Accept as-is | B: Add injection + test |
|---|---|---|
| Behavior | `saveRoutingAndApply` has no unit test for invoking store+daemon | Full plan coverage; one test asserts store.save + daemon.applyRoutingUpdate invocation |
| Implementation | zero code change | ~30 LOC: add `ConfigurationStoreProtocol` + `DaemonProtocol` to AppModel init; update existing callers; add test double |
| Risk | silent regression if future refactor breaks wiring | adds indirection to AppModel; slight coupling increase |

**Recommendation:** B — `AnthropicBridge.swift:308` hot-reload tests prove bridge-layer wiring, but the ContentView → GatewayDaemon boundary is only validated by smoke script. A protocol wrapper follows a common AppModel refactor pattern and gives future Phase 7+ work a cleaner test surface.

### [DP-P6R-002] Accept or close test-coverage gap T10-shell (blocking)

**Gap:** `SettingsTokenStatusTests.swift` has 6 tests; 3 are `#expect(true)` placeholders and 3 have tautological assertions (e.g. `#expect(model.tokenRefreshError == nil || model.tokenRefreshError != nil)` at line 58). Plan Task 10 step 3 required 3 real-assertion cases: tokenPreview rendering, busy-flag toggle, error population.

**Options:**

| | A: Remove shell tests | B: Replace with real assertions |
|---|---|---|
| Behavior | Test file contains only cases that actually assert; fewer but honest | All 3 plan-required cases verified end-to-end |
| Implementation | Delete 3 shell tests + rewrite 3 tautological assertions = ~40 LOC net | Same + inject mock `SubscriptionSessionLoader` into AppModel (matches DP-P6R-001 pattern) |
| Risk | Test count drops; Task 10 coverage appears incomplete | Requires DP-P6R-001's injection work; larger surface area |

**Recommendation:** B — the `@MainActor` compile errors (T10-compile) force a rewrite of these tests anyway (per user's Step 7 fix). Combining the rewrite with real assertion logic (`#expect(model.tokenRefreshError != nil)` after intentional failure) is a zero-extra-cost upgrade. Reference: plan Task 10 step 3 exact wording "→ `isRefreshingToken` 从 false → true → false" requires observable state transitions, which `#expect(true)` does not deliver.

### [DP-P6R-003] Design-vs-plan omission: routing insights click-to-drill-down (recommended)

**Gap:** Dev-guide Phase 6 line 328 specifies "点击单行可下钻到该 Claude 模型的详细 trace 列表". The approved Phase 6 plan's Task 4 does NOT include this drill-down behavior. Code matches plan but misses design intent.

**Options:**

| | A: Accept as out-of-scope | B: Add drill-down in a Phase 6.1 follow-up |
|---|---|---|
| Behavior | Routing insights stays view-only | Clicking a row opens a filtered trace list for that Claude model |
| Implementation | zero code change | Modest — add `Button` wrapper + navigate to a new filtered trace view (which does not yet exist) |
| Risk | Design drift compounds in later phases | Scope creep beyond Phase 6 deliverables |

**Recommendation:** A — the plan is user-approved and explicitly enumerates the 3-row read-only view. Drill-down requires a new trace list view that is not in Phase 6's surface. Flag as Phase 6.1 or fold into Phase 7 observability iteration. Reference: plan line 203-204 specifies metrics-only display; no `.onTapGesture` in `routingInsightsSection` (ContentView.swift:1185-1208).

---

## Low-Confidence Appendix (C < 80)

- [C:75] Gap D-relogin: Dev-guide line 324 "refresh 失败时展示 re-login 引导" vs current code only shows `tokenRefreshError` text without a CTA button. Low confidence because the plan Task 10 step 3 does not enumerate re-login CTA, and existing `authInstructionText` path in Subscription auth section is reused when `requiresAuthAttention` fires — Token refresh failure may indirectly flip that flag. Needs runtime trace to confirm end-to-end behavior.

---

## Summary Output

### Plan-vs-Code (Part 1)
- Total gaps: 3 (Critical: 0, Standard: 3) — reported: 3 (C>=80), filtered: 0
- Tests: 6 required, 6 exist, 4.5 covered, shell: 6 (all in `SettingsTokenStatusTests.swift`)
- T7-save: `saveRoutingAndApply` integration test missing (Task 7 step 4 case 5) [C:90]
- T10-shell: 6 shell/tautological tests in `SettingsTokenStatusTests.swift` (Task 10 step 3) [C:95]
- T10-compile: 12 `@MainActor` isolation errors blocking `ModelBridgeTests` target build [C:95]

### Design Fidelity (Part 2)
- [A] Spec values: 3 checked, 0 mismatched
- [B] Data flow: 4 traced, 0 disconnected
- [C] Old code: 2 checked, 0 still present
- [D] Features: 7 checked, 1 missing (click drill-down) + 1 partial (re-login CTA)
- [E] Quality: 4 compared, 0 degraded

### Rules Audit
- R6: All 5 completion claims in execution report carry file:line + test-command evidence. ✅
- R9: All edited files match plan's Files sections; no unauthorized expansions. ✅
- Decision authority: 3 UI changes all plan-specified; Advisor route kept separate (plan allowed both). ✅

### Verdict
❌ 3 gaps require remediation (all test-coverage; no plan-vs-code implementation gaps)
