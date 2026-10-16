# Explicit effort policy — offline validation

Status: source implementation complete; activation and inference remain separately gated.

## Changes

Version-2 route fields separate fixed effort, optional explicit missing/auto fallback and optional spending maximum. Unset maximum does not cap supported explicit client intent. Missing/auto uses explicit fallback or verified target metadata. Unsupported target effort and cap violations reject with categorical HTTP errors; no silent downward normalization. Strict adaptive/no-budget translation remains. Diagnostics record validated effort levels and resolution/rejection categories only.

V1 follow-mode decoding materializes the previous default and ceiling so migration cannot lift historical limits. Null/absent v2 caps remain uncapped. Advanced UI/draft, fallback/Fable, and executor environment override preserve policy fields. Malformed/future policy files are preserved and block start/save rather than reset mappings and spending limits. Advisor stays fixed and continuation-pinned. Both fixed and follow token-count paths honor saved continuation routes; follow explicit changes during tool continuation reject.

## Verification

- Full Swift package: 366 tests / 47 suites passed (final offline run).
- Policy matrix includes all five ordinals, all caps/unset, every one of the 31 nonempty target effort capability subsets, omitted/auto/default metadata, malformed controls, migration and null-cap round trips.
- Mock bridge coverage includes fixed/follow payloads, count/message parity, saved continuation pinning/conflict and independent Advisor.
- Isolated Xcode build-for-testing succeeded. Separate bundle identifier `com.90percent.Claudex.EffortOfflineAudit`; derived products in /tmp. All 37 App unit tests passed, including save/default/cap round trips. First run exposed absent default metadata in DEBUG fixtures; corrected and rerun passed.
- Required `scripts/smoke_local_gateway.sh`: 77 fixture tests / 7 suites passed. No real inference or account authorization requests.
- Independent design review confirmed root cause. Independent implementation review found and verified fixes for advanced draft cap loss, malformed-config fail-open, and fixed token-count continuation mismatch. Final fresh review found no remaining actionable findings.

Sandbox initially blocked compiler cache writes, loopback tests and ephemeral RSA generation. Module caches redirected to /tmp; narrowly scoped offline verification escalations approved. No denied/pending actions remain.

## Deployment evidence and limits

The original gateway remained PID 37918 on 127.0.0.1:4317 after tests. No production configuration activation, App/gateway replacement/restart, model calls, Git commit/push or release/distribution edits. Source-only changes are not evidence of deployed behavior.

The inactive JSON Patch next to this report tests current route/Advisor metadata, sets policy v2/follow mode, and explicitly leaves fallback/max fields null. Model identities, fixed stored effort and Advisor remain unchanged. This proposal would allow supported explicit client intent and use target metadata for absent/auto; it has no user cap. It is NOT applied, and activation still requires separate approval of build/config behavior.
