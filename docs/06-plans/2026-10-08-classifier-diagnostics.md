# Redacted classifier diagnostics

This change diagnoses the unavailable auto-mode classifier; it does not implement a safety classifier or change permission decisions. No live request, authentication/configuration change, app launch/replacement, commit or push is part of this validation.

## Capture the next user request

The already-running Xcode app has not been replaced. These hooks become active when the user next builds and runs Claudex from the current checkout in Xcode. Then reproduce the intended `cx` action normally. Do not add a model call solely to populate diagnostics.

Open Settings → Activity → Trace log. Only entries with `stage: classifier_diagnostic` are needed. In the sandboxed Xcode build, the default trace is `~/Library/Containers/com.90percent.Claudex/Data/Library/Application Support/Claudex/trace.jsonl`; a configured trace override takes precedence. Do not share the entire legacy trace, configuration file or credential store.

Each request has a generated `diagnostic_id`. Events include ingress, resolved_route, upstream_http, gateway_response, bridge_failure, stream_review_fields, stream_finished and stream_failed. Presence flags report review fields/headers, session header, thinking and output format. No header values, prompts, tool contents, account IDs, arbitrary error descriptions or response text are recorded. Known endpoint/model values are retained; unknown endpoint paths and client model labels are masked. Error categories are fixed labels.

A 404 gateway response without an upstream_http event identifies an unsupported endpoint. A bridge_failure without upstream_http identifies a local preflight failure; missing_session and unsupported_thinking have distinct categories. Upstream status failures are recorded numerically. A successful upstream/gateway stream without review metadata supports a protocol mismatch investigation; it does not prove a valid classifier verdict. Absence of ingress for a classifier attempt means the request may have used another transport; this trace cannot diagnose requests that never reach Claudex.

The stream observer forwards original bytes, finish calls, release callback and thrown errors. It detects message_stop and review fields in the gateway encoder's complete SSE frames. Metadata parsing is diagnostic only and does not synthesize a verdict or alter response schemas.

## Offline verification

Regression tests cover sentinel redaction, fixed error categorization, buffered response identity, exact stream bytes, finish/release behavior and preservation of thrown errors. Core suite, offline gateway smoke and separate macOS build results are reported alongside the change.

## Owner retry and protocol repair

The owner rebuilt in Xcode and retried `/commit`. PID 22233 served 4317 and emitted the new diagnostic events. At 11:32:05 UTC the main streaming Sonnet request carried a review field, routed to gpt-6-luna / low, completed with HTTP 200 and message_stop, and emitted no review-result diagnostic. At 11:32:26.785 UTC a non-streaming Sonnet request with no thinking/output format reached the same route and received HTTP 200 followed by SSE/message_stop. Claude Code recorded automode-unavailable at 11:32:30.140 UTC. Other fallback-shaped requests repeated this mismatch. The isolated earlier 404 was a HEAD request on a masked other endpoint, not a failed Messages classifier POST.

Confirmed transport defect: the bridge buffered only explicit `stream: false`; omission incorrectly selected SSE. Anthropic Messages defaults to a buffered JSON Message. The bridge now streams only when `stream == true`. Offline reproduction failed before the fix (SSE rather than JSON and a premature 200 on an upstream failure), then passed after it. A rejection response remains unchanged and failed provider output remains an error; no synthetic allow verdict is introduced. Diagnostics now distinguish absent stream fields and buffered/streaming responses. This repairs a confirmed classifier-fallback transport incompatibility; real classifier completion still requires an owner retry with the rebuilt app and has not been claimed from fixtures alone.

Independent SendMessage defect: Claude Code's saved original wire arguments had only `to` and `message`; the recipient contained `@`, and exactly matched the recipient Claude Code validated. The bridge did not add the invalid address. Later sends used a bare recipient but hit automode-unavailable instead. The existing client tool description already instructs use of bare names. A regression preserves SendMessage schema, description and invalid recipient bytes; the gateway must not silently rewrite them. Correct model/workflow recipient selection remains the caller's responsibility; external plugin/skill files were not edited.

The owner's attempt reached a final assistant response at 11:35:38.203 UTC and advanced repository HEAD to c05018aad43a5a1066012c3eb070307b12e5e7ca. This worker did not commit or push. The subsequent transport repair remains uncommitted. Final validation: 338 core tests / 45 suites; 66 offline smoke tests / 7 suites; 30 macOS unit tests with zero failures. The user-running PID 22233 has not been restarted or replaced. Acceptance ledger remains 9/9; no additional agent inference was performed.

## Safe activation after owner completion

Refreshed owner session evidence confirmed exactly one bare-recipient error and two classifier-unavailable errors in the completed 11:32–11:35 UTC run. That run was served by the earlier binary; none of its ingress records had the new stream_field_present flag. Command completion was not counted as classifier success.

The final omitted/false/true regression matrix passed in the full 339-test core suite. Explicit false returns JSON; true preserves SSE/message_stop; omitted returns JSON; failed non-streaming output remains an error; SendMessage schema, description and recipient are preserved. Earlier production-identical validation also passed 66 offline smoke tests and 30 macOS unit tests. The owner's existing Xcode DerivedData Debug build was rebuilt using its unchanged signing settings and passed signature verification outside the command sandbox.

With user authorization to activate after their request completed, the exact PID 22233 was verified Idle through Accessibility (the displayed count reads the bridge inflight count), gracefully terminated, and the same normally signed Xcode bundle reopened. PID 24225 is now the sole 127.0.0.1:4317 listener and reports Idle. GET /health returned service Claudex/status running and emitted the new diagnostic fields, confirming the updated instrumentation is active. No credentials/configuration were read or changed, no security settings changed, no model request was issued, and the acceptance ledger remains 9/9. Real auto-mode classifier success remains pending the owner's next normal attempt.
