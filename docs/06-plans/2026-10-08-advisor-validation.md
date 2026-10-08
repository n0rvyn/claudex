# Claudex verification — 2026-10-08

## Verified behavior

Installed Claude Code 2.1.294 completed a real Read call against the final macOS gateway, submitted the actual local tool result, and returned `READ_OK`. Client exit 0, result subtype success, is_error false. Exactly two new upstream attempts, sequences 8 and 9, used `gpt-6-luna / low / default` (Standard). Ledger limit changed from 8 to 9 with count 7 and all seven records retained; final count 9/9. No upstream retry. Local credential validation initially stopped the helper before any client/network launch; it consumed no slot.

Evidence: `/tmp/claudex-acceptance-20261008/live-read.jsonl`, `live-read.stderr`, `ledger.json`. No credentials are included in this report. Start and Pause were exercised through the final compact popover. Final app PID 13796, executable `/tmp/ClaudexGoalXcode/Build/Products/Debug/Claudex.app/Contents/MacOS/Claudex`; gateway paused and no TCP 4317 listener. Superseded app and our offline render fixture were gracefully closed; unrelated Claude processes were not stopped.

## Request diagnosis and instruction semantics

The actual installed-client declaration is `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-5-5","defer_loading":true}`. It has no input_schema. The former function-only validator rejected it. Captured stock tool declarations are retained as an offline fixture, without prompts, credentials or headers. Advisor is now translated explicitly into a gateway-owned tool-free review; Claude still executes local tools and permission decisions.

Top-level system text uses Responses instructions. Mid-conversation system text now remains at its original position as a developer message; it is not moved into user text or hoisted. Dynamic tool changes and next-user-message instruction expiry remain independent. Provider-contract fixture rejected input role system, producing a red regression; changing only this role mapping produced green NativeSystemTurn/tool-addition continuation tests. Official SIWC support: [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations). Logs: `/tmp/claudex-system-role-red.log`, `/tmp/claudex-system-role-green.log`.

Advisor Model and Effort are independently saved under Account & model. The user-selected GPT-6 Luna / low was verified in the actual UI. Advisor never inherits or raises executor effort. Executor and Advisor routes are pinned across client-tool continuation. Regression coverage includes mixed calls, full transcript/images, provider usage aggregation, cancellation, malformed declarations, orphan results and max_uses. Native max_tokens, caching controls, programmatic callers and encrypted Anthropic Advisor results are explicitly unsupported, rather than silently dropped. Native plaintext Advisor blocks are emitted with actual advice.

## UI refinement and telemetry boundaries

The 340-point panel contains gateway/active-request status, a compact native Start/Pause control, current authentication/connection failures, a labelled five-minute recorded-request trend, recent recorded request/error counts, available last/p50/p95 latency, separately identified token/Advisor/network-byte availability, route context, and Activity/Settings shortcuts. Configuration forms live only in Settings. Both shortcuts were exercised in the running shipping app and selected the correct settings pane.

The existing SIWC bridge does not emit the timestamped anthropic_in/out trace measurements used by the legacy recent-log diagnostics. Therefore this run shows trend unavailable and no measured latency; zero log counts mean zero matching records in the recent log, not zero actual upstream traffic. Token/Advisor throughput and network bytes are not recorded by this telemetry and display unavailable. Provider token usage in protocol responses is preserved, but it is not a remaining ChatGPT-plan quota. No calls were made to populate the UI. The trend consumes at most the existing 64-record diagnostic window; it is labelled recorded requests/min, not a comprehensive traffic counter.

Native render fixtures use the same ContentView with isolated fake state and no credentials/network. Running (one active request), idle, paused and gateway-error states were inspected in both light and dark appearance. Each fits without scrolling: normal content 340×265 points; error content 340×305. Error text is limited to two lines with full hover detail. Evidence: `/tmp/claudex-panel-states/{running,idle,paused,gatewayError}-{light,dark}.png`. The actual production paused popover was also captured and inspected: `/tmp/claudex-panel-states/actual-paused-popover.png`. State fixtures verify native rendering, not a claim of eight live gateway conditions.

## Checks and isolation

- Swift package: 327 tests / 43 suites passed; `/tmp/claudex-advisor-final-full-tests.log`.
- macOS build and unit target: 32 cases passed, TEST SUCCEEDED; `/tmp/claudex-advisor-xcode-unit.log`, `/tmp/ClaudexGoalXcode/Logs/Test/Test-Claudex-2026.10.08_17-08-34-+0800.xcresult`.
- Required offline gateway smoke: 60 tests / 6 suites passed; `/tmp/claudex-final-smoke.log`.
- Installed real Claude offline Advisor → Read → actual local result → final passed using fake upstream/auth, temporary HOME/config/replay/trace and the shipping bridge.
- Final regression constructors use in-memory configuration and injected fake auth; XCTest app hosts use an offline fixture. An earlier macOS run exposed default-auth reads in test constructors; this gap was fixed before the final run. Do not treat that earlier run as credential-isolated.
- Fixed an offline listener test's readiness/port-reservation race by waiting on its own listener state, preserving address-in-use retry behavior; no production request retry added.
- AppIntents metadata extraction warning also appears in the baseline build log `/tmp/claudex-goal-xcode-build.log:272`.
- Callers were inventoried with rg; no LSP was available, and this does not establish import-alias coverage.

Thirteen tracked private-backend/probe/migration scripts were removed after consumer review, without backup copies. Useful tool, image, effort, streaming, cancellation and replay tests remain; test-only legacy fixtures were retained because they still provide useful coverage. Historical documentation is retained as history.

## Remaining limits

Real acceptance establishes the installed headless client Read/continuation path, not every interactive TUI permission prompt or long-running Claude workflow. Advisor was verified with the actual installed client offline; no additional live Advisor inference was authorized. Unsupported Anthropic-only fields fail explicitly. The telemetry availability limitations above remain. There is no authorization or budget for additional live attempts.

Automatic approval initially rejected Settings Copy both because it places a credential on the clipboard. The user explicitly approved that local action, normal approval subsequently accepted it, and the token was never printed or added to evidence. No permission/account security changes, commit or push.

## Exact working tree

Branch `dev`, HEAD `bc4eab0`; original work preserved. No staged changes. The following snapshot includes this report itself:

```text
 M CLAUDE.md
 M Claudex/ClaudexApp.swift
 M Claudex/ContentView.swift
 M Claudex/SettingsView.swift
 M ClaudexTests/ClaudexTests.swift
 M ClaudexTests/SettingsRoutingEditorTests.swift
 M ClaudexTests/SettingsTokenStatusTests.swift
 M README.md
 M Sources/CCRouterCore/AcceptanceInferenceGuard.swift
 M Sources/CCRouterCore/AnthropicProtocol.swift
 M Sources/CCRouterCore/AnthropicSSEEncoder.swift
 M Sources/CCRouterCore/EffortPolicy.swift
 M Sources/CCRouterCore/GatewayDaemon.swift
 M Sources/CCRouterCore/LocalHTTPServer.swift
 M Sources/CCRouterCore/RouterConfiguration.swift
 M Sources/CCRouterCore/SIWCBridge.swift
 M Sources/CCRouterCore/SIWCReplayStore.swift
 M Tests/CCRouterCoreTests/AcceptanceInferenceGuardTests.swift
 M Tests/CCRouterCoreTests/EffortPolicyTests.swift
 M Tests/CCRouterCoreTests/LocalHTTPServerStreamingErrorTests.swift
 M Tests/CCRouterCoreTests/RouterConfigurationStoreTests.swift
 M Tests/CCRouterCoreTests/SIWCBridgeTests.swift
 D scripts/_probe_common.py
 D scripts/forward_responses_with_converted_claude_tools.py
 D scripts/migrate_to_modelbridge.rb
 D scripts/probe_converted_tool_call.py
 D scripts/probe_converted_tool_roundtrip.py
 D scripts/probe_count_tokens_accuracy.py
 D scripts/probe_image_wire.py
 D scripts/probe_prompt_cache_hit.py
 D scripts/probe_reasoning_effort.py
 D scripts/probe_responses_advisor_bridge.py
 D scripts/probe_text_verbosity.py
 D scripts/probe_upstream_models.py
 D scripts/proxy_forward_responses.py
?? Sources/CCRouterCore/SIWCAdvisor.swift
?? Tests/CCRouterCoreTests/ClaudeConnectionSnippetTests.swift
?? Tests/CCRouterCoreTests/Fixtures/claude-code-2.1.294-advisor-tools.json
?? Tests/CCRouterCoreTests/NativeSystemTurnTests.swift
?? docs/06-plans/2026-10-08-advisor-compatibility-plan.md
?? docs/06-plans/2026-10-08-advisor-validation.md
```

## Post-acceptance normal-use correction
The guarded app process was mistakenly left as the user-facing app. Manual Start restarted its gateway but retained the process-level 9/9 acceptance guard, rejecting the user’s own request before upstream transport. This was a delivery error. After the user reported it, process 13796 was gracefully closed and the same final binary was launched without CC_ROUTER_ACCEPTANCE_* variables. Start was exercised through the native popover. PID 15471 is the sole listener on 127.0.0.1:4317; ledger remains 9/9. No model request was sent during restoration. The earlier paused PID observation above is historical; this paragraph records the current running state.

## Follow-up verification: working user session and real telemetry
This section supersedes the earlier telemetry-unavailable limitation and popover layout description.

The user's Siphon session `fee7d2b0-f4e5-48d9-b6c1-a85224e85cf6.jsonl` records server_tool_use advisor at 09:27:00Z, advisor_tool_result at 09:27:05Z and the final project description at 09:27:09Z (17:27 local). Latest app-owned saved replay confirms executor and Advisor routes `gpt-6-luna / low`; it contains the real Advisor function call/output and final message. Claude's visible Opus name is its client-facing model role. No credential files were read to verify this.

The all-zero display was a Claudex measurement bug: the shipping SIWC path did not emit the legacy anthropic_in/out records used by the diagnostic-tail counter. The only records in trace.jsonl were 28 subscription-refresh writeback failures, not traffic. The previous report's unavailable display was insufficient for the requested operational panel.

A bridge-owned metadata recorder now logs each incoming Claude message request, each executor/Advisor/resume attempt, actual provider-reported input/output usage, request completion latency and failures. Separate request and model-call counters prevent double counting. A single completed-request lease prevents duplicate errors on stream failure/release. User cancellation is excluded from failures. Local authentication rejection and pre-inference schema rejection count as gateway failures; count_tokens/health probes do not count as Claude message requests. Five one-minute buckets and totals use current wall-clock last-five-minute boundaries, not the newest log line, and are not truncated to 64 arbitrary log records. Safe metadata persists in Replay/traffic.jsonl across process restarts, with owner-only directory/file permissions. Recorder location follows the isolated replay/config location in tests; no production Activity writes or credentials.

Only reported usage is summed. Missing usage is shown as unavailable, or `+` when the known total is partial. Advisor tokens are a subset of total reported tokens. No estimated local input-token value or ChatGPT-plan quota is presented as provider usage. Historical requests without these records were not backfilled or fabricated. The initial window is labelled Since [measurement start], then Last 5 min.

The lower panel now shows Requests/Tokens/Errors with a compact model-call/Advisor summary and small shortcuts. Recent log, p50/p95, unavailable network-byte fields and route boilerplate were removed from this panel. Detailed diagnostics remain in Activity. Actual native renders inspected all eight state/appearance combinations, using metadata exported from the offline real-bridge regression: two Claude requests, four model calls, 69 reported tokens plus one unreported call, 23 Advisor tokens. These are clearly isolated fixture values, never production display data. Final normal/error sizes: 340×240 / 340×280 points. Chart label overlap found during render inspection was corrected. Current actual running popover was also captured and inspected; no invented traffic was added to populate it.

Final checks:
- 330 tests / 44 core suites passed, including the installed Claude offline Advisor/Read loop; `/tmp/claudex-traffic-full-tests.log`.
- 30 macOS tests passed, confirmed by xcresulttool summary (0 failures); `/tmp/ClaudexGoalXcode/Logs/Test/Test-Claudex-2026.10.08_17-52-44-+0800.xcresult`.
- 63 tests / 7 offline smoke suites passed; `/tmp/claudex-traffic-smoke.log`.
- Final macOS build succeeded; `/tmp/claudex-traffic-final-build.log`.
- Render evidence: `/tmp/claudex-panel-states/{running,idle,paused,gatewayError}-{light,dark}.png`; latest actual running capture is `/tmp/claudex-panel-states/actual-paused-popover.png` (the helper retained its filename; image shows running).
- One debug fixture parameter declaration failed compilation during development; corrected, then final build/tests passed. No unresolved introduced warnings or test failures.
- New recorder expiry, restart, duplicate result, malformed/future timestamp and missing-usage tests cover the useful removed legacy-trend test cases.

The previously idle normal app was gracefully replaced with the updated build and Start was exercised through the popover. PID 18977 is the sole listener on 127.0.0.1:4317, without acceptance environment variables. Acceptance ledger remains 9/9. No agent-initiated live model calls were made for this refinement. Callers were collected with rg, not LSP; import aliases were not independently covered. No commit or push.

### Current exact working-tree snapshot

Branch dev, HEAD bc4eab0, no staged changes:

```text
 M CLAUDE.md
 M Claudex/ClaudexApp.swift
 M Claudex/ContentView.swift
 M Claudex/SettingsView.swift
 M ClaudexTests/ClaudexTests.swift
 M ClaudexTests/SettingsRoutingEditorTests.swift
 M ClaudexTests/SettingsTokenStatusTests.swift
 M README.md
 M Sources/CCRouterCore/AcceptanceInferenceGuard.swift
 M Sources/CCRouterCore/AnthropicProtocol.swift
 M Sources/CCRouterCore/AnthropicSSEEncoder.swift
 M Sources/CCRouterCore/DoctorSnapshot.swift
 M Sources/CCRouterCore/EffortPolicy.swift
 M Sources/CCRouterCore/GatewayDaemon.swift
 M Sources/CCRouterCore/LocalHTTPServer.swift
 M Sources/CCRouterCore/RouterConfiguration.swift
 M Sources/CCRouterCore/SIWCBridge.swift
 M Sources/CCRouterCore/SIWCReplayStore.swift
 M Tests/CCRouterCoreTests/AcceptanceInferenceGuardTests.swift
 M Tests/CCRouterCoreTests/EffortPolicyTests.swift
 M Tests/CCRouterCoreTests/LocalHTTPServerStreamingErrorTests.swift
 M Tests/CCRouterCoreTests/RouterConfigurationStoreTests.swift
 M Tests/CCRouterCoreTests/SIWCBridgeTests.swift
 D scripts/_probe_common.py
 D scripts/forward_responses_with_converted_claude_tools.py
 D scripts/migrate_to_modelbridge.rb
 D scripts/probe_converted_tool_call.py
 D scripts/probe_converted_tool_roundtrip.py
 D scripts/probe_count_tokens_accuracy.py
 D scripts/probe_image_wire.py
 D scripts/probe_prompt_cache_hit.py
 D scripts/probe_reasoning_effort.py
 D scripts/probe_responses_advisor_bridge.py
 D scripts/probe_text_verbosity.py
 D scripts/probe_upstream_models.py
 D scripts/proxy_forward_responses.py
?? Sources/CCRouterCore/SIWCAdvisor.swift
?? Sources/CCRouterCore/SIWCTraffic.swift
?? Tests/CCRouterCoreTests/ClaudeConnectionSnippetTests.swift
?? Tests/CCRouterCoreTests/Fixtures/claude-code-2.1.294-advisor-tools.json
?? Tests/CCRouterCoreTests/NativeSystemTurnTests.swift
?? Tests/CCRouterCoreTests/SIWCTrafficTests.swift
?? docs/06-plans/2026-10-08-advisor-compatibility-plan.md
?? docs/06-plans/2026-10-08-advisor-validation.md
```

Final consumer audit also connected Activity successes, success/error ratio, last outcome and p50/p95 to the same recorder. Ratios use completed requests, rather than dividing completed failures by request arrivals; in-flight and cancelled requests do not fabricate success. Final core/macOS checks passed after this change. The final macOS test target rebuilt the app; the separate build log listed earlier preceded this last consumer wiring. Current normal app PID 18977 was started through the popover and its actual rendered panel inspected. No user requests were in flight at either graceful refresh.
