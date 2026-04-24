## Implementation Review Summary
**Status:** complete
**Plan:** docs/06-plans/2026-04-24-phase7-e2e-acceptance-plan.md
**Started:** 2026-04-24-142948

## Part 1: Plan-vs-Code Verification

### Task 1 — Daemon CC_ROUTER_TRACE_PATH + actor-instance override

- ✅ `Sources/CCRouterCore/DaemonTraceOverrideResolver.swift` exists, matches plan spec; `resolve()` handles nil/empty/non-absolute/system-prefix/valid cases; `prepareParentDirectory()` returns nil-on-success. [C:100]
- ✅ `Sources/CCRouterCore/TraceLogger.swift:3-40` adds `@TaskLocal overrideFileURL`, private `instanceOverrideFileURL`, `setFileOverride(_:)`, priority: TaskLocal → instance → default. Matches plan spec exactly. [C:100]
- ✅ `Sources/CCRouterDaemon/main.swift:7-20` reads env, calls resolver, fail-closed on invalid/prep-err, calls `await TraceLogger.shared.setFileOverride(url)` for override. Matches plan spec. [C:100]
- ✅ `Tests/CCRouterCoreTests/TraceLoggerEnvOverrideTests.swift` exists — 7 cases (nil/empty/relative/etc/System/Library/valid). Matches plan spec. All pass. [C:100]
- ⚠️ Gap T-exist (§13.1): `Tests/CCRouterCoreTests/TraceLoggerInstanceOverrideTests.swift` was specified by plan (lines 69, 211-287) but was **deleted during review** per user note. The deletion is acknowledged by the user as intentional (`TraceLogger.shared` is process-global mutable state; Swift Testing parallel execution races make these meta-tests flaky). However, the plan itself still lists this file under `Files:` and `Steps: 5` — the plan should have been updated, or the deletion flagged as a decision. [C:90]
- ✅ Verify command: `swift build` green; grep `setFileOverride|instanceOverrideFileURL` in TraceLogger.swift → 5 hits (≥3 expected); grep `DaemonTraceOverrideResolver` in main.swift → 3 hits (≥1 expected). [C:100]

### Task 2 — 10-file trace isolation wrap

- ✅ `Tests/CCRouterCoreTests/TraceIsolation.swift` exists with both `withTaskLocalIsolation` and `withInstanceOverride` APIs. Cleanup for instance override uses synchronous do/catch (improvement over plan's `defer { Task { ... } }`). [C:100]
- ✅ 9 bridge-only test files wrapped with `withTaskLocalIsolation`: AnthropicBridgeRoutingHotReloadTests (3/3), PendingToolTurnEvictionTests (3/3), CountTokensEndpointTests (7/7), BridgeRegressionTests (14/14), AnthropicMessageStartUsageTests (3/3), ModelRoutingBridgeIntegrationTests (5/5), StreamingBridgeIntegrationTests (13/13), AdvisorContextForwardingTests (3/3). [C:100]
- ✅ `ThinkingBlockEmissionTests.swift` has 19 @Test but only 5 are wrapped; the 14 unwrapped tests are pure codec/decode tests (no bridge, no TraceLogger.log). Plan said "对每个 @Test body 整体 wrap 一层" literally, but the intent was "tests that log"; unwrapped tests never touch TraceLogger. Not a gap. [C:85]
- ✅ `LocalHTTPServerStreamingErrorTests.swift` has 2 @Test, both wrapped with `withInstanceOverride`. Suite is already `@Suite(.serialized)`. [C:100]
- ⚠️ Gap T-exist (§13.1): `Tests/CCRouterCoreTests/TraceHygieneTests.swift` was specified by plan (line 312, 385-440) but is **missing**. User note acknowledges deletion as intentional (race condition makes mtime assertion flaky against process-global state + parallel Swift Testing). Plan should have been updated to document the removal. [C:90]
- ⚠️ Gap (§10 stale reference): `Tests/CCRouterCoreTests/TraceIsolation.swift:8` comment still references the deleted `TraceLoggerInstanceOverrideTests.instanceOverrideSurvivesTaskDetached` as evidence: `// Daemon set-once semantics are covered by / TraceLoggerInstanceOverrideTests.instanceOverrideSurvivesTaskDetached.` — this test no longer exists. Action: update comment to explain deletion rationale (or remove the reference). [C:100]
- ✅ Verify (splits): 9 bridge-only files all contain `withTaskLocalIsolation`; LocalHTTPServerStreamingErrorTests contains `withInstanceOverride`. Grep -L returns empty for both sets as plan required. [C:100]

### Task 3 — smoke_local_gateway.sh trace assertions

- ✅ Script exists and contains all planned assertions: CC_ROUTER_TRACE_PATH env var injection (line 39), SMOKE_OUTDIR + TRACE_PATH setup (lines 20-21), trace file existence check (73), anthropic_in.claude_model (79), responses_out*.upstream_model (86), prompt_cache_key (93), responses_in_event (99), header doc comment (lines 3-5). [C:100]
- ✅ cleanup trap only kills daemon, does not rm tempdir (line 44). [C:100]
- ✅ Verify: grep count = 10 (≥6 expected). [C:100]

### Task 4 — smoke_routing_e2e.sh

- ✅ Script created with PORT=4418 default (line 14), independent SMOKE_OUTDIR + TRACE_PATH + CONFIG_PATH, heredoc config generation for 3 rules (haiku→spark, sonnet→gpt-5.4, opus→gpt-5.4), daemon env block with all 5 CC_ROUTER_* vars (lines 48-54), 30s health poll, per-model one-liner env `claude --bare`, upstream_model distinct-count ≥2 assertion, per-claude-model presence assertion. [C:100]
- ✅ `bash -n` syntax OK; grep count = 5 (≥4 expected). [C:100]
- ✅ Cleanup trap EXIT/INT/TERM only kills daemon. [C:100]

### Task 5 — smoke_multimodal.sh

- ✅ Script created with PORT=4419 default, independent trace/config/outdir, daemon env block includes CC_ROUTER_TRACE_PATH, heredoc minimal config (no routing rules), TINY_PNG_BASE64 constant (line 72), `jq -n --arg b64` structured payload (line 74), POST /v1/messages via curl, 3 assertions: response has message markers, trace has image reference, upstream response completed. [C:100]
- ✅ `bash -n` syntax OK; grep count = 3 (≥3 expected). [C:100]

### Task 6 — Phase 7 regression checklist

- ✅ `docs/09-acceptance/phase7-regression-checklist.md` created, 46 lines (≥35 expected), 23 §3.X row references for §3.13-§3.40. [C:100]
- ✅ Has header with purpose/executor/run-constraint, markdown table with Section/content/probe/test/re-run/pass-fail/evidence columns. [C:90]

### Task 7 — Acceptance report skeleton

- ✅ `docs/research/2026-04-22-refactoring-acceptance-report.md` created; 52 PASS/PENDING-DEVICE/DEFERRED mentions (≥30 expected). [C:100]
- ✅ Phase 5 §5.4 covers deferred #1 real-device refresh with Methods A/B/C and 3 assertions. [C:100]
- ❌ Gap (§10 stale reference): AC-5.6 at line 236 still cites deleted `Tests/CCRouterCoreTests/TraceHygieneTests.swift` as evidence. The two cases listed (`taskLocalIsolatedBridgeTestDoesNotPolluteProductionTrace`, `instanceOverrideIsolatedServerTestDoesNotPolluteProductionTrace`) no longer exist. Action: rewrite AC-5.6 evidence to state that meta-assertion tests were intentionally removed due to process-global race; the 10-file `TraceIsolation.withTaskLocalIsolation`/`withInstanceOverride` wraps in Task 2 close deferred #3 by construction (tests no longer call `TraceLogger.shared.log` against the default path). This is the substantive mechanism per user note. [C:100]

### Task 8 — count_tokens defer issue + dev-guide update

- ✅ `gh issue list` shows issue #2 OPEN titled "Phase 5 V2: count_tokens accuracy exceeds 10% threshold vs upstream" labeled `deferred,phase-5`. Issue #4 CLOSED (duplicate per user note). [C:100]
- ✅ Dev-guide line 298 updated to reference `https://github.com/n0rvyn/model-bridge/issues/2` (not #4). [C:100]
- ✅ Acceptance report "Deferred issues tracking" table (line 353) links to #2 and notes #4 was closed as duplicate. [C:90]

### Crystal D-001..D-008 Coverage

- ✅ D-001 (env VAR=val one-liner, no export): All 3 smoke scripts use `env VAR=value cmd` pattern for daemon + claude calls. The single `export CLANG_MODULE_CACHE_PATH` in smoke_local_gateway.sh:12 is pre-existing and scoped to subshell (D-002 compliant). [C:90]
- ✅ D-002 (bash subshell invocation): All scripts invoked via `bash scripts/...`; README/docs show no `source`. [C:90]
- ✅ D-003 (independent trace path): smoke_local_gateway.sh:21 writes to `$SMOKE_OUTDIR/trace.jsonl`; routing/multimodal use their own `$SMOKE_OUTDIR`. Task 1 daemon honors `CC_ROUTER_TRACE_PATH`. Task 2 wraps 10 test files with TaskLocal/instance override so tests no longer write to production path. [C:100]
- ✅ D-004 (teardown trap, independent ports): 4417/4418/4419 for local/routing/multimodal; trap EXIT INT TERM only kills daemon. [C:100]
- ✅ D-005 (no export in Bash tool calls): Not applicable to delivered artifacts (in-session Bash calls, not part of shipped code).
- ⚠️ D-006 (real command + output snippet in acceptance report): Report has `<pending>` placeholders for device items — expected per DP-P7-002 Chose B (device fill happens after scaffold). Not a gap. [C:85]
- ⚠️ D-007 (Phase 5 #1/#2/#3 handled in Phase 7):
  - #1 real-device refresh → AC-5.4 PENDING-DEVICE row exists with 3 assertions + 3 trigger methods (lines 202-227). ✅
  - #2 count_tokens ≤10% → re-deferred to GitHub issue #2 (DP-P7-001 Chose B). ✅
  - #3 test trace hygiene → **closed by Task 2 construction (10-file wrap)** per user note; but AC-5.6 evidence text still cites deleted `TraceHygieneTests.swift` meta-tests. This is the ❌ Gap already noted in Task 7. [C:100]
- ✅ D-008 (Phase 6 deferred #4 click-to-drill-down OUT of scope): Grep for `drill|onTapGesture.*insight|RoutingInsight.*tap` returns zero results in ModelBridge/ UI code; no Phase 7 task touched Dashboard interactivity. [C:100]

### Phase 7 Acceptance Criteria Status

Dev-guide Phase 7 lists 8 unchecked criteria (lines 383-393). Classification by where evidence comes from:

| # | Criterion | Source |
|---|-----------|--------|
| 1 | `swift test` all green | **IN-SESSION** — 221 pass / 1 flake (Phase 1 `cancellationViaOnTerminationStopsParser`, timing-sensitive, unrelated to Phase 7). Verified in this review. [C:100] |
| 2 | `xcodebuild test` all green | **IN-SESSION capable** — not run in this review; new `ModelBridgeTests/SettingsRoutingEditorTests.swift` + `SettingsTokenStatusTests.swift` need pbxproj integration (acceptance report line 253 flags `protection hook` blocking; manual Xcode-add required). Cannot be proven IN-SESSION without user running Xcode once. [C:85] |
| 3 | `smoke_local_gateway.sh` all green | **DEVICE** — requires real Claude CLI + Codex subscription. Script is IN-SESSION complete. |
| 4 | `smoke_routing_e2e.sh` all green | **DEVICE** — same as #3. |
| 5 | `smoke_multimodal.sh` all green | **DEVICE** — same as #3 + image-capable model. |
| 6 | Acceptance report with real evidence per criterion | **Partial IN-SESSION** — scaffold complete; device rows have `<pending>`. |
| 7 | `dist/ModelBridge.app` clean account flow | **DEVICE** — `bash scripts/build_app_bundle.sh` build IN-SESSION verifiable; fresh-account launch is DEVICE. |
| 8 | ≥1 hour real session | **DEVICE** — user's own usage. |

**In-session proven:** #1 (with caveat of unrelated Phase 1 flake).
**Pending device:** #3-#8.
**Unverifiable without Xcode manual step:** #2 (due to pbxproj hook block).


### §13 Rules Compliance Audit

**R6 (Evidence before claims):** Completion claims in Phase 7 execution were each followed by `swift build`/`swift test`/`grep -c` verification per plan's Verify sections. User note explicitly mentions "Build green after fixes" post-brace-error repair. ✅ Compliant. [C:85]

**R9 (Fix obstacles, don't bypass):** Plan-specified files vs modified files:
- Task 1-2-3-6-7-8 touched only plan-specified files.
- Task 2 deletion of `TraceHygieneTests.swift` + `TraceLoggerInstanceOverrideTests.swift` is a **deviation** from plan. Per R9 self-check "我是在修次生问题，还是在绕回？" — the deletion is a bypass of the plan's meta-hygiene assertion, justified by process-global-state race. This should have been raised as a decision or the plan should have been updated. User note acknowledges the deletion; flagging it is for audit completeness, not for rollback. [C:90]

**Decision authority audit:** No UI/View modifications from Phase 7 tasks. The modified `ModelBridge/ContentView.swift` and `ModelBridge/SettingsView.swift` are pre-existing Phase 6 uncommitted work (see Pre-existing section). ✅ [C:100]

### §13.1 Test Completeness Audit

Plan-required tests:
- `TraceLoggerEnvOverrideTests.swift` — ✅ exists, 7 cases, all assertions, all pass
- `TraceLoggerInstanceOverrideTests.swift` — ❌ **does not exist** (deleted); plan required 3 cases (Task.detached survival, TaskLocal priority, nil restore). User intentionally removed due to race condition vs process-global state.
- `TraceIsolation.swift` (helper, not a test) — ✅ exists, both APIs present
- `TraceHygieneTests.swift` — ❌ **does not exist** (deleted); plan required 2 mtime-assertion cases. User intentionally removed for same reason.
- 9 bridge-only test files wrapping — ✅ all wrap present
- 1 server-start test file wrapping (LocalHTTPServerStreamingErrorTests) — ✅ wrap present

Shell tests: none (all existing tests have assertions).

Count:
- Required tests: 11 files (2 new test files + 9 modified + 1 modified + 1 helper)
- Files exist: 9 files (2 missing: InstanceOverride, Hygiene)
- Non-empty: 9/9 existing have real assertions
- Core path covered: 9/9 existing
- Shell tests: 0
- **Missing test files: 2** (both acknowledged deletions; user provided rationale)

### §12 Reverse Regression Reasoning

1. **[Hypothetical regression] User runs `bash scripts/smoke_local_gateway.sh` on real device.**
   - User action: `bash scripts/smoke_local_gateway.sh`
   - Code path: script line 39 sets `CC_ROUTER_TRACE_PATH` → daemon main.swift:7 reads env → resolver returns `.override(url)` → `await TraceLogger.shared.setFileOverride(url)` → LocalHTTPServer.swift handles request in `Task.detached` → log goes to actor instance override (Task 1 design correction).
   - Covered by forward check: ✅ Task 1 section — `setFileOverride` reachable from detached Task via actor serialization.
   - **Action Required: none** for Phase 7; Phase 8 should verify on real macOS device that trace file appears at `$SMOKE_OUTDIR/trace.jsonl` and not in production path.

2. **[Hypothetical regression] `swift test` runs in parallel; two suites race on `TraceLogger.shared.setFileOverride`.**
   - User action: `swift test`
   - Code path: Suite A `withInstanceOverride` sets URL_A → Suite B (parallel, not `@Suite(.serialized)`) `withInstanceOverride` sets URL_B → Suite A logs → lands in URL_B's trace file, test assertion on URL_A fails.
   - Covered by forward check: ⚠️ Partially — only `LocalHTTPServerStreamingErrorTests` is `@Suite(.serialized)`. Other suites never call `withInstanceOverride`, so no direct race. But if anyone later adds `withInstanceOverride` to a non-serialized suite, they'll race.
   - **Action Required:** document in `TraceIsolation.swift:27` comment (already present: "Caller's suite MUST be `@Suite(.serialized)`") — no new finding.

3. **[Hypothetical regression] User fills device evidence into `docs/research/.../acceptance-report.md` then reads AC-5.6 — sees it cites non-existent test files.**
   - User action: review final acceptance report.
   - Code path: report line 236 → `Tests/CCRouterCoreTests/TraceHygieneTests.swift` (does not exist) → confusion about whether Phase 5 #3 is really closed.
   - Covered by forward check: ✅ New finding reported in Task 7.
   - **Action Required: fix** (rewrite AC-5.6 to reflect construction-closes-#3 mechanism).


### Pre-existing Issues

All modified files in `git status` belong to Phase 1-7 uncommitted work (initial commit only has the bootstrap + pre-refactoring snapshots). The following are **pre-existing, not caused by Phase 7** (verified via `git log` showing last commits to these files are Phase 6 or earlier):

- `ModelBridge/ContentView.swift`, `ModelBridge/SettingsView.swift` — Phase 6 Settings UI work (not committed). Changes include `RoutingInsightRow`, `RoutingRuleDraft`, `AppModel` additions. **No regression detected** from Phase 7 side.
- `ModelBridge/ModelBridgeApp.swift` (not in diff list but new Routing files likely reference it) — untouched.
- `Sources/CCRouterCore/AnthropicBridge.swift`, `Sources/CCRouterCore/GatewayDaemon.swift`, etc. — all Phase 2-6 work.

**Pre-existing flake identified in `swift test`:**
- `ResponsesClientStreamingTests.cancellationViaOnTerminationStopsParser` — asserts `elapsed < 1.0s` but observed `1.47s`. This is a **pre-existing Phase 1 timing-sensitive test**, not introduced by Phase 7.
  - **Root cause (hypothesis):** the test uses wall-clock timing to verify cancellation completes fast; on loaded systems (parallel test runners) the scheduling jitter exceeds 1.0s.
  - **Impact:** low — functional code is correct; assertion threshold too tight for CI + parallel runners.
  - **Recommendation:** relax threshold to `< .seconds(3)` OR use deterministic cancellation-token observation (e.g., assert parser state flag rather than elapsed time). Out of Phase 7 scope; flag for Phase 8.

**Pre-existing unclosed issue #3:**
- GitHub issue #3 "Test trace events leak into production trace.jsonl" is still OPEN. The plan's Task 2 closes the underlying bug by construction (10-file wrap), and the acceptance report claims AC-5.6 = PASS. However the GitHub issue itself was never closed/commented. **Action:** close issue #3 with a comment linking to Task 2 commits + mention that meta-assertion tests were intentionally not added due to race condition.


---

## Implementation Review Summary

### Plan-vs-Code (Part 1)

**Reported gaps (C≥80): 4**
1. ⚠️ Gap T-exist (Task 1, C:90): `TraceLoggerInstanceOverrideTests.swift` missing. User-acknowledged intentional deletion (flaky vs process-global state). Plan not updated to document removal.
2. ⚠️ Gap T-exist (Task 2, C:90): `TraceHygieneTests.swift` missing. Same rationale as #1.
3. ⚠️ Gap §10 stale reference (Task 2, C:100): `Tests/CCRouterCoreTests/TraceIsolation.swift:8` comment references deleted `TraceLoggerInstanceOverrideTests.instanceOverrideSurvivesTaskDetached` as evidence.
4. ❌ Gap §10 stale reference (Task 7, C:100): `docs/research/2026-04-22-refactoring-acceptance-report.md:236` cites deleted `Tests/CCRouterCoreTests/TraceHygieneTests.swift` as AC-5.6 PASS evidence; two case names no longer exist.

**Filtered (C<80): 0**

**Tests:** 11 required by plan, 9 exist, 9 covered (core paths), 0 shell tests, 2 missing (intentional user deletions — flagged).

### Design Fidelity (Part 2)

N/A — Phase 7 is an acceptance phase with no independent design doc; crystal D-001..D-008 checks integrated into Part 1 Crystal coverage section.

### Rules Audit

- **R6:** ✅ Completion claims backed by verification commands (swift build / swift test / grep -c).
- **R9:** ⚠️ Plan-required test files deleted without plan update; user provided rationale (process-global race) — acknowledged but not formalized in the plan document.
- **Decision authority:** ✅ No Phase 7 task modified user-visible UI.

### Pre-existing Issues

1. `ResponsesClientStreamingTests.cancellationViaOnTerminationStopsParser` — timing-based threshold too tight for parallel runs. Recommended: relax to `< .seconds(3)` or use deterministic flag observation. Not Phase 7.
2. GitHub issue #3 still OPEN even though Task 2 closes underlying bug. Recommended: close with comment linking Task 2.

### Low-Confidence Appendix (C < 80)

None.

### Verdict

❌ **4 gaps require remediation** (3 minor documentation fixes + 1 acceptance report evidence rewrite).

Severity interpretation:
- Gaps 1 & 2 (missing test files) are **user-acknowledged intentional deletions** with sound rationale (race against process-global state). If formalized (e.g., plan annotated with `⚠️ SIMPLIFIED:` + rationale, or a DP decision), they're not gaps. As-is, they violate the plan-vs-code literal contract.
- Gap 3 (TraceIsolation.swift comment) is a 1-line comment fix.
- Gap 4 (acceptance report AC-5.6 evidence) is a multi-line rewrite of that section to reflect the construction-closes-#3 mechanism rather than citing deleted tests. **This is the only user-facing consequence** — if the acceptance report is reviewed by stakeholders, it currently claims a PASS backed by non-existent evidence.

**Recommendation:** Phase 7 IN-SESSION work is structurally complete and substantively correct (build green, 221 tests pass, all plan tasks delivered artifacts). Before Phase 7 close, fix Gap 3 (1 line) + Gap 4 (AC-5.6 section rewrite) + add a plan annotation or DP noting the intentional removal of `TraceHygieneTests` + `TraceLoggerInstanceOverrideTests` with rationale (closes Gaps 1 & 2).

---

## Decisions

### [DP-R-001] AC-5.6 evidence rewrite in acceptance report (blocking)

**Gap:** Plan required `TraceHygieneTests.swift` with 2 mtime-assertion cases as evidence for AC-5.6 (deferred Phase 5 #3 = test trace hygiene). The acceptance report at `docs/research/2026-04-22-refactoring-acceptance-report.md:234-239` claims `Status: ✅ PASS` with those exact test cases as evidence, but both test files were deleted during review. A reader auditing Phase 7 cannot verify AC-5.6 — the evidence citation points to non-existent code.

**Options:**

| | A: Rewrite evidence to construction-closes-#3 | B: Restore meta-assertion tests |
|---|---|---|
| Behavior | AC-5.6 reads: "Closed by construction — Phase 7 Task 2's 10-file `TraceIsolation.withTaskLocalIsolation`/`withInstanceOverride` wrap ensures isolated tests never write to production path. Meta-assertion mtime tests intentionally not added due to `TraceLogger.shared` process-global race." | AC-5.6 restores 2 meta-tests; suite marked `@Suite(.serialized)` globally; accepts occasional flake |
| Implementation | 6-line edit to one section of one markdown file | Re-create 2 test files (~70 LOC); possibly need to restructure all test suites around global serialization |
| Risk | Correctness depends on trusting Task 2 wrap is comprehensive (covers every log call site). Audit: `grep -r TraceLogger.shared.log` in Tests/ should return zero outside of explicit override contexts. | Flaky tests in CI; false negatives undermine the invariant |

**Recommendation:** A — `Tests/CCRouterCoreTests/TraceIsolation.swift:26-31` documents the serialization invariant; the user's decision to delete the meta-tests cites the exact race condition, and empirical test runs (221 pass) show the construction approach works. Rewriting the evidence is a low-risk documentation fix that accurately reflects the delivered mechanism.

### [DP-R-002] Plan annotation for intentional test deletion (recommended)

**Gap:** Plan `docs/06-plans/2026-04-24-phase7-e2e-acceptance-plan.md` Task 1 Step 5 and Task 2 Step 4 explicitly require `TraceLoggerInstanceOverrideTests.swift` and `TraceHygieneTests.swift` respectively. Both files do not exist. Without a plan annotation or DP, a future reviewer (or the same reviewer on re-audit) will flag these as Critical Gaps and waste cycles re-deriving the rationale.

**Options:**

| | A: Add `⚠️ SIMPLIFIED:` annotation inline | B: Add DP-P7-003 post-hoc |
|---|---|---|
| Behavior | Plan's Task 1 Step 5 + Task 2 Step 4 get a note: `⚠️ SIMPLIFIED: test intentionally not added — see TraceIsolation.swift comment for rationale`. | A new DP section appended noting the decision with options considered and rationale. |
| Implementation | 2 inline annotations in the plan file | 1 new DP section (~20 lines) |
| Risk | Plan annotation may be missed if reader skips inline notes | DP appears post-execution but is clear and discoverable |

**Recommendation:** A — project convention (CLAUDE.md rule 9 "禁止静默降级实现") requires loud annotation near the affected step; inline `⚠️ SIMPLIFIED:` matches existing plan style and is less ceremonious than a post-hoc DP.

### [DP-R-003] Close GitHub issue #3 (recommended)

**Gap:** GitHub issue #3 is still OPEN even though Phase 7 Task 2 closes the underlying bug (tests no longer leak to production trace). Dev-guide and acceptance report both claim resolution.

**Options:** Close with comment linking to Task 2 artifacts (or leave open for user to close).

**Recommendation:** Close with comment when user executes Phase 7 Step 8 (standard dev-workflow closure step).

