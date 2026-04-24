---
name: ModelBridge trace isolation quirk
description: Phase 7 uses actor-instance override on TraceLogger because TaskLocal does not cross Task.detached; meta-hygiene tests on mtime are flaky due to process-global state
type: project
---

**Fact:** `Sources/CCRouterCore/TraceLogger.swift` is an actor with `TraceLogger.shared` as process-global singleton. Phase 7 Task 1 added `setFileOverride(_:)` instance-level override because `@TaskLocal overrideFileURL` does not propagate through `Task.detached` (used by `LocalHTTPServer` connection handler). Effective priority: TaskLocal → instance override → default.

**Why:** Phase 7 verifier cycle 1 found that earlier plan using `TaskLocal.withValue { runDaemon() }` at daemon entry failed because `LocalHTTPServer.swift:214-218` spawns per-connection `Task.detached` that breaks TaskLocal propagation.

**How to apply:** When reviewing Phase 7+ changes touching trace isolation:
1. Tests that start real LocalHTTPServer must use `TraceIsolation.withInstanceOverride` and be `@Suite(.serialized)`; pure bridge tests use `withTaskLocalIsolation`.
2. Positive "mtime does not change" assertion tests on process-global TraceLogger are prone to race under parallel Swift Testing. Phase 7 intentionally removed 2 such meta-tests (`TraceHygieneTests`, `TraceLoggerInstanceOverrideTests`). If future plans propose such meta-tests, flag as likely flaky.
3. Deferred issue #3 "Test trace events leak into production trace.jsonl" (GitHub) is closed **by construction** (10-file wrap), not by meta-assertion tests. Acceptance report evidence text must reflect the construction mechanism, not the deleted tests.
