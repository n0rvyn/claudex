# 2026-04-23 Tool Continuation History Recovery

## Changed

- Added `ToolContinuationHistory`, a pure tail analyzer that derives the active continuation slice from Anthropic request history instead of flattening every historical `tool_result` into the current turn.
- Reworked `AnthropicBridge` continuation reconciliation around four explicit branches: `pending_cache_match`, `history_recovered`, `pending_cache_stale_cleared`, and local preflight rejection for orphaned or unresolved continuations.
- Changed matched-pending continuations to keep using the stored pending tool contract even when the incoming Claude CLI continuation request carries a drifted `tools` list; the bridge now treats that request-side drift as non-authoritative and preserves the original upstream contract.
- Changed pending-state error handling so accepted continuation retries keep their cached pending turn after an upstream stream abort; only newly stored pending state from the current request is rolled back on failure.
- Added stale-cache healing trace rows plus active replay/tool-result call-id logging, so runtime diagnosis now shows whether the bridge matched cache, recovered from history, or cleared stale cache.

## Tests

- Added `ToolContinuationHistoryTests` for mixed old/current `tool_result` history, multi-result order preservation, orphan detection, resolved-history detection, and cached-pending relation classification.
- Added bridge regressions for historical `tool_result` filtering, history-only continuation recovery, stale cache clearing, and advisor second-pass continuation continuity.
- Replaced the old tool-contract-mismatch rejection test with coverage that proves continuation tool drift still reuses the stored pending contract and reaches upstream successfully.
- Updated streaming integration coverage so accepted continuation aborts are retryable under the same session instead of degrading into `no pending tool turn`.

## Runtime Validation

- Started a fresh daemon from the updated workspace build on `127.0.0.1:4318`.
- Ran a real Claude CLI session against that daemon using the same base URL and auth token that `co` exports.
- Observed a full live tool round in trace session `08b42547-5595-4782-a3bf-989aa5c0b448`: initial request, pending tool-turn storage, history-backed continuation with `2` matching call/output pairs, and final `anthropic_out` success `200`.
- Confirmed the post-fix live session did not emit `stream_aborted`, `continuation_preflight_rejected`, or `no pending tool turn for tool_result continuation`.
