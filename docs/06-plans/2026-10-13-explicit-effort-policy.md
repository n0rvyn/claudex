# Explicit effort policy

Status: implementation authorized; deployment and inference excluded.

Goal: preserve explicit supported client effort unless an explicit user cap forbids it. Preserve existing model identities, fixed behavior, Advisor isolation and historical spending limits.

Impact map: settings drafts → versioned routing config → count/message resolution → replay route. Existing consumers include single-model mode, ordered rules, Fable, fallback, environment overrides and catalog validation. Runtime credentials/config/release bundles remain untouched.

Diagnosis: EffortPolicy.resolve conflates reasoningEffort with ceiling and silently downgrades unsupported values. Independent read-only review confirmed this.

## Decisions

ModelRoute.reasoningEffort remains fixed-mode effort. Add defaultClientEffort (optional explicit missing/auto fallback) and maxAllowedEffort (optional ordinal cap). With neither field, follow-mode missing/auto uses verified target default_reasoning_level; no arbitrary medium/high and no inferred Claude default. Reject unknown/unavailable defaults, unsupported target intent and requests above explicit cap. The HTTP error is the observable outcome; add sanitized effort resolution diagnostics for success/rejection categories. No nearest-lower normalization.

Policy version 2 distinguishes new null caps from v1 follow routes. Decode old follow tables by materializing old effort as both fallback and cap. Fixed v1 stays fixed. Preserve caps in environment overrides and all draft conversions. Advisor remains fixed; per-request executor follow policy never changes Advisor. Tool continuation retains stored route, rejects changed explicit effort/model rather than silently claiming to follow; no re-resolution of omitted effort against changed defaults.

## Tasks

1. Implement versioned schema and pure policy with exhaustive offline cases across all supported ordinals, missing/auto, caps, target metadata, malformed controls and migration. Verify with Swift Testing.
2. Wire message/count resolution and continuation diagnostics; update catalog validation and all UI editors/draft round trips. Test configuration/migration, mock bridge continuation and Advisor.
3. Run package suite, offline smoke, isolated Xcode unit/build verification. Obtain fresh independent review and fix findings. No installed App launch/replacement.
4. Apply reviewed source-only diff to canonical repo, preserve release/deployed artifacts, deliver exact inactive routing activation JSON Patch. Do not activate, commit or push.

## Threat model

Client model/effort strings are untrusted: enum/capability validation rejects invalid inputs; log only validated levels and categorical outcomes, no raw unknown values/prompts/credentials. Metadata must match selected account. Old ceilings cannot be removed by decoding. Tests use temporary isolated paths/loopback ports and fixture clients; temp resources cleaned by defer and test-owned commands awaited. No production config loads through mutating store during verification.

## Verification limits

No real inference or runtime activation authorized. Offline tests prove policy/payload paths, not production success. Compiled test artifacts stay in /tmp; deployment diff remains a proposal.
