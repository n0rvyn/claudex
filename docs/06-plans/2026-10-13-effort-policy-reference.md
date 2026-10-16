# Effort policy v2 — inactive implementation

## Fields

`routingTable.allowClientEffort=false` uses `route.reasoningEffort` as a fixed executor effort. Advisor always uses its separately configured `reasoningEffort`.

`allowClientEffort=true` preserves a supported explicit client level. `route.maxAllowedEffort` is an optional, independent ordinal spending cap; missing/null means no additional cap. A request above the cap rejects with `effort_cap_exceeded`, never silently downgrades.

For omitted effort or `auto`, `route.defaultClientEffort` is an optional explicit proxy fallback; missing/null uses the selected account model's verified `default_reasoning_level`. Unknown or unsupported defaults reject. The fixed `reasoningEffort` does not become a fallback or ceiling in v2 follow mode. Default and maximum are independent; a default above an explicit cap causes omitted/auto requests to reject.

Supported scalar levels are `low`, `medium`, `high`, `xhigh`, `max`. Target capability metadata must support the resolved level. Unsupported target intent, unknown/non-string input, or invalid cap explicitly rejects. Adaptive thinking without budget is accepted as ordinal input; fixed budgets, enabled/disabled thinking are not translated in follow mode. This does not equate Claude and OpenAI compute at the same ordinal.

## Migration and continuation

Decoding v1 (missing version or version 1) follow tables materializes each route's old `reasoningEffort` as both `defaultClientEffort` and `maxAllowedEffort`, retaining historical limits. Version 2 is encoded thereafter; null caps remain null/missing across saves. V1 fixed mode stays fixed. Existing model IDs and Advisor are preserved. Executor environment override retains explicit default/cap while changing only fallback target identity as historically configured by that override.

A saved tool turn pins executor/Advisor model and resolved effort. Client effort changes during tool continuation use the pinned effort and take effect when a new user turn starts (compatibility correction, 2026-10-16). New user turns resolve current policy. Count-token and message requests share continuation resolution. Internal executor continuation after Advisor uses the same executor payload; Advisor never follows client effort.

Malformed/unsupported config remains untouched on disk; gateway startup and saving the synthetic readback defaults are blocked until the file is repaired. No reset to higher-spend defaults.

## Protocol evidence

- [Claude Code model configuration](https://code.claude.com/docs/en/model-config): per-model defaults, explicit overrides, adaptive thinking and per-model settings. Installed CLI 2.1.296 includes top-level/per-turn output_config effort and the per-turn-control beta. User-level legacy effortLevel high does not uniformly determine 5.5 effort; it is not assumed to be current wire effort.
- [Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort): top-level and per-message ordinal intent. Public per-message control activates at next user; installed native SDK control applies immediately, including tail controls. Role and content validation remains strict. Supported system text, temporary instructions and tool changes do not require beta headers; native per-turn effort still uses its beta to distinguish activation semantics.
- [OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning): model-dependent supported effort/defaults. Follow missing/auto uses account metadata rather than an assumed universal medium/high. Public model defaults do not override explicit migrated proxy fallback.

## Deployment boundary

No production config read through mutating store, inference calls, gateway/app replacement, restart, Git commit/push, or release bundle changes. Activation is a separate reviewed source/build/config action. A prepared JSON Patch is inactive and has precondition tests; current fixed low remains deployed.


## Compatibility correction — 2026-10-16

User report: Claude Code 2.1.301 returned `effort_continuation_conflict` and `mid-conversation system beta is required` through Claudex.

User constraint: “we we test those new changes, use a different port. the current runnning Claudex is working at this time. FYI.” Test listeners use dynamically reserved loopback ports; the running app, its listener, configuration and acceptance ledger are not changed. No live inference is authorized or performed.

Tool continuation keeps the saved executor/Advisor route even if the current request carries a different effort. New user turns resolve current policy. Supported system text, temporary instructions and tool changes are validated by content rather than rejected for absent beta headers. Native per-turn effort activation still uses its distinct beta; public next-user activation is unchanged.

Regression evidence: the pre-fix source rejects the new effort/system fixtures; the corrected full Swift suite passes 370 tests across 47 suites. The HTTP fixture sends real loopback requests to `/v1/messages` and `/v1/messages/count_tokens` with a synthetic upstream. It verifies missing system beta and changed continuation effort without contacting a model. A separate fixture keeps two distinct sessions in flight and checks duplicate-request rejection. This does not establish live provider acceptance or change the running app.

Final validation: offline smoke script passes 80 tests across 7 suites; Release Xcode app build succeeds in `/tmp/claudex-fix-20261016/AppBuild/Build/Products/Release/Claudex.app`. The app is ad hoc signed and signature verification succeeds. It has not been launched or substituted for the running app. Logs: `/tmp/claudex-fix-20261016/{baseline,full-final,smoke,app-build}.log`.
