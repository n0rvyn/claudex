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
