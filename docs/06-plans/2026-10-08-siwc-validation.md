# SIWC refactor validation — 2026-10-08

Baseline: `dev` at `e4b29ca768029fef134d67a1e2c23fe1b8a75d16`. User authorized the full local refactor. No push, release, browser login, real token exchange, or live inference was performed.

## Implemented

- Literal-loopback authenticated gateway, minimal public health and credential-free diagnostics.
- App-owned dynamic SIWC registration, PKCE/state/nonce, signed ID-token validation and granted scopes, distinct client/subject registrations, owner-only atomic credentials, cross-process refresh serialization and revocation/local sign-out.
- Model-only public Responses HTTP/SSE with no nested agent, private-backend reader or billed-key fallback.
- Full history/instructions, namespaced client tools, parallel item-ID/call-ID mapping, final argument consistency, raw encrypted reasoning/assistant-phase prefix sidecars, route pinning through tool continuations, explicit required session identity.
- Strict SSE frames, failed/incomplete/EOF rejection, replay persistence before success, client-disconnect and gateway-stop cancellation.
- Browser login/account UI, explicit account model catalog, removal of auth chooser/private endpoint/advisor controls, preserved routing configuration.
- Historical private-backend implementations remain only in the test target so existing pure-code regressions can run. Their probes are historical and must not be executed for this workflow.

## Evidence

`swift test --scratch-path /tmp/ClaudexSIWCBaseline --disable-sandbox` with temporary Swift/Clang module caches: **270 tests / 36 suites passed**. Fixtures exercise signed claims/tampered signatures, denied and mismatched callbacks, actual callback-listener readiness, concurrent refresh, credential modes, model-catalog account identity, strict multiline/malformed/truncated SSE, orphan/duplicate tool IDs, parallel argument streams, opaque reasoning and assistant phase, missing session rejection, quota failure/no retry, interrupted output/no success, persistence failure/no success, and loopback error framing.

Restricted-environment socket/key generation and compiler caches required approved sandbox escalation. One bulk-copy command was rejected as a possible destructive filename mix-up. Inspection proved the staged files distinct; explicit source-to-matching-destination copies were approved. Nothing remains blocked. The old private-backend sub-50ms wall-clock assertion was flaky under concurrent CPU work and cannot certify SIWC latency; it now verifies actual SSE message-start/delta/stop ordering. No SIWC latency claim is made.

macOS `xcodebuild ... CODE_SIGNING_ALLOWED=NO build-for-testing` compiled the app and unit-test target. The app-host test suite was not executed to avoid triggering the real app's credential/monitoring lifecycle. No Simulator/device was launched.

A temporary `NSHostingView` fixture rendered the upstream/settings view with credential tasks, monitoring and login-items operations removed; no real app was launched. [Settings capture](2026-10-08-siwc-settings.png). Native prominent-button material in a bitmap fixture is not equivalent to a live AppKit screenshot; real interaction remains unverified.

Compatibility target: installed Claude Code **2.1.292** (`~/.local/share/claude/versions/2.1.292 --version`). This pins the client version for future live validation; it does not establish live compatibility.

## Remaining gates and limits

- User must perform/authorize browser login. Account availability, direct-invocation permission, catalog details, refresh/revocation and real model eligibility have not been tested live.
- Only after authorization: at most three tiny serial smoke calls including retries; use the account-discovered lowest suitable subscription-cost eligible model and minimum supported effort. API prices/model names cannot establish subscription cost. If that choice cannot be established, stop and report rather than guessing. No automatic inference retry or billed fallback.
- No end-to-end live Claude Code tool/permission/session flow has been demonstrated. Existing saved model names/efforts remain preserved and need account verification.
- Named forced tool choices and unsupported Anthropic tool types fail explicitly. Native Anthropic web-search result conversion is explicitly rejected; no fabricated encrypted result is emitted. Generic client-tool declarations stay Claude-owned.
- Duplicate suppression is within one gateway actor for active requests; there is no exactly-once guarantee across restarts/processes. Cancellation does not prove the upstream stopped metering before disconnect. Failed/interrupted sidecars are not committed as successful output.
- Persistent replay stores raw confidential history items owner-only; retention/cleanup policy is not yet implemented. Compaction/rewrite invalidates a prefix match and reconstructs available client history; opaque data that was omitted from rewritten history cannot be recovered by guessing.

## Follow-up independent review

Fixed cancelled OAuth exchange activation and stale callback completion; refresh-task sharing is now keyed by registration and lease, with scope checks on fresh reuse. Fixed pre-header-disconnect cleanup using per-request upstream cancellation and response-release hooks; late cleanup cannot clear a newer request. Cancelled preflight never starts inference. Fixed mixed text/tool replay ordering and tested replay after bridge recreation. Rejected undeclared tool calls and malformed/unsupported image and nested-result blocks before they can be silently lost. Preserved account model metadata in an explicit details disclosure for later capability evidence; it does not calculate cost.

Remaining blind spots: real JWKS/key rotation and non-RS256 tokens; actual browser/consent/error UI; refresh/revocation under real provider failures or process death; separate-process stress; actual URLSession cancellation over the provider network; live Claude Code version-specific metadata, tool permissions and compaction; populated account-details UI. In-memory/loopback fixtures do not establish production account entitlement, native provider tool parity or post-disconnect metering behavior. Historical codec helpers still contain legacy signature mapping, but the shipping SIWC bridge does not call them or import those signatures.

## Authentication preparation — not performed

No real Claudex client registration was created or verified. Credential stores were deliberately not inspected, so a prior user registration is unknown. `dynamic_agent_client` is the documented first-registration entrypoint, not an unconfigured placeholder to replace by hand. Only a validated callback can supply and persist the issued per-user/workspace client ID. No client secret or partner API key is configured or required by this documented local flow.

The compiled app bundle exists at `/tmp/ClaudexSIWCXcode/Build/Products/Debug/Claudex.app`. Future user command: `open "/tmp/ClaudexSIWCXcode/Build/Products/Debug/Claudex.app"`. The command was not executed; real launch/sign-in interaction remains unverified. Source and fixture capture confirm Settings → Upstream → Continue with ChatGPT. User must perform this on the same Mac (or remotely operate that Mac's browser); iPhone Safari cannot complete a callback to the Mac's literal loopback address.

The app requests `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, with resource `https://api.openai.com/v1`. In the browser, the user must select the intended account/workspace, review the actual displayed permissions/terms and authorize Claudex plus ChatGPT-plan usage. No exact browser consent wording or acceptance of additional terms was observed. Official docs describe the path for open-source/local apps; paid or remotely hosted distribution uses a separate interest path. Neither existing Pro subscription nor local compilation proves account/workspace eligibility.

After user authorization, the explicit Load models available to this account action can retrieve model metadata. Before any inference, evidence must establish: eligible model slug for that selected registration/workspace; authoritative ChatGPT-plan usage cost/rate or multiplier comparison; minimum supported reasoning effort for that model on this route; function-tool capability for the intended smoke case; and configured plan-use permissions/limits. Availability order, names, API dollar prices and the documentation's example model do not establish the cheapest choice. If evidence is absent, stop and report; do not spend smoke calls searching by trial.

Approved future smoke cap remains at most three tiny serial inference calls total, including retries, after separate authorization. No parallel tests or fallback billing. Registration/catalog checks are not inference, but still require user authorization for external access and token use.
