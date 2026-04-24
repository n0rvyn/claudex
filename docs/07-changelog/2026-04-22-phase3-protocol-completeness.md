# Phase 3: Protocol Completeness — Changelog

**Date:** 2026-04-23
**Status:** Complete
**Plan:** `docs/06-plans/2026-04-22-phase3-protocol-completeness-plan.md`
**Verification:** 121/121 tests pass (17 ThinkingBlockEmissionTests + 13 ToolUseHistoryReplayTests added this phase; 91 pre-existing)

---

## Summary

Phase 3 closes three classes of protocol translation gaps:

- **3a — Image wire fidelity**: Image blocks are now encoded as `input_image` data URLs in `/responses` input, matching the upstream-validated wire shape (probe Row A). Tool-result images are split into `function_call_output` + synthetic user message with `input_image` (probe Row D).
- **3b — Thinking surface + streaming**: Thinking blocks emit `signature` (base64 of `encrypted_content`) in SSE responses (Scheme E). The `reasoning.summary: auto` request parameter enables a new SSE event stream (`reasoning_summary_part.added` / `reasoning_summary_text.delta` / `reasoning_summary_part.done`) that surface thinking text incrementally to the CLI. The `output_item.done` reasoning item carries `signature_delta` after the summary stream.
- **3c — History replay**: `encodeFullHistory` correctly interleaves message-nested blocks (text/image) with top-level replay items (reasoning/function_call/function_call_output) preserving temporal order across message boundaries.

---

## Scheme E: encrypted_content / signature Roundtrip

**Problem:** Claude Code CLI sessions that include `thinking` blocks in their conversation history must send those blocks back verbatim on subsequent turns. The `signature` field in an Anthropic `thinking` block is an opaque cryptographic value derived from the `encrypted_content` in the upstream `/responses` output item.

**Solution (Scheme E):**

1. **Downstream decode** (`IRAnthropicCodec.decodeRequestBlocks`): Extract `signature` field from incoming Anthropic request, decode base64, store as `Data?` in `.thinking(encryptedContent: Data?, summary: String?)`.
2. **Upstream encode** (`IRAnthropicCodec.encodeResponseBlock`): Re-encode `encryptedContent` as base64 into the `signature` field when emitting a thinking block to the CLI SSE stream. If `encryptedContent` is nil or empty, the `signature` field is omitted entirely.
3. **Replay encode** (`IRResponsesCodec.encodeReplayBlocks`, `encodeFullHistory`): On continuation turns, emit `encrypted_content` as base64 in the `/responses` reasoning input item. The `summary` field uses a list-of-objects shape `[{"type":"summary_text","text":"..."}]` to match the upstream real shape (probe Row F).
4. **Request parameter** (`AnthropicBridge.makeResponsesPayload`): `reasoning: {effort: <route-effort>, summary: "auto"}` — `summary: "auto"` enables the SSE delta stream without requiring `include: ["reasoning.summary"]` (upstream rejects that include path per probe Row C).

**Evidence:** `docs/research/2026-04-22-image-wire-probe.md` Rows E/F; `docs/research/2026-04-22-cli-signature-passthrough.md` (inconclusive from public source, falls back to Anthropic public docs assumption + [D-006] degradation path).

---

## New SSE Event Handling

The `/responses` upstream now emits four additional event types when `reasoning.summary: "auto"` is set:

| Upstream event | Bridge action |
|---|---|
| `response.reasoning_summary_part.added` | Open a thinking content block (`startThinkingBlock`) |
| `response.reasoning_summary_text.delta` | Emit `content_block_delta` with `thinking_delta` type |
| `response.reasoning_summary_part.done` | No-op (block remains open for signature_delta) |
| `response.output_item.done` (reasoning) | If `inStreamingThinking`: emit `signature_delta` + `content_block_stop`; else: atomic `emitThinkingBlock` fallback |

The `inStreamingThinking` local flag prevents double-emitting the summary text (deltas already covered the summary; only the signature needs to be appended).

---

## Summary List Shape

Upstream `/responses` emits the reasoning summary as a list of `{type: "summary_text", text: "..."}` objects, not a plain string. The `flattenReasoningSummary` helper handles both shapes (list or legacy string) for decode compatibility. On replay, `encodeReplayBlocks` and `encodeFullHistory` always emit the list shape.

---

## Changed Files

### Core

- `Sources/CCRouterCore/IR/IRAnthropicCodec.swift`
  - `decodeRequestBlocks`: `case "thinking"` now decodes `signature` via `Data(base64Encoded:)`
  - `encodeResponseBlock`: `case .thinking` emits `signature` field as base64 when `encryptedContent` is non-nil/non-empty; omitted otherwise

- `Sources/CCRouterCore/IR/IRResponsesCodec.swift`
  - `decodeOutputItem`: reasoning case uses `flattenReasoningSummary` helper
  - `encodeInputItems`: `case .image` emits `input_image` with data URL; MIME whitelist `["image/png","image/jpeg","image/webp","image/gif"]`; unsupported types log to stderr and return nil
  - `splitToolResult` (new private helper): splits tool_result into `function_call_output` + optional synthetic user message with `input_image`
  - `encodeReplayBlocks`: summary emitted as `[{type:"summary_text", text:...}]` not plain string
  - `encodeFullHistory` (new): flush-based walk with role/block guard rules; `.thinking` emits top-level reasoning item, text/image go into buffered message content, tool_use/tool_result flush and emit top-level items

- `Sources/CCRouterCore/AnthropicBridge.swift`
  - `runInitialTurn`: `encodeInputItems` replaced with `encodeFullHistory`
  - `makeResponsesPayload`: `reasoning` now has `summary: "auto"`; `include` unchanged (still `["reasoning.encrypted_content"]`)
  - `processUpstreamStream`: three new switch cases for `reasoning_summary_part.added`, `reasoning_summary_text.delta`, `reasoning_summary_part.done`; `.thinking` branch in `output_item.done` dispatches to streaming or atomic path

- `Sources/CCRouterCore/AnthropicSSEEncoder.swift`
  - `startThinkingBlock()` (new): opens a thinking content block
  - `emitThinkingDelta(_ delta: String)` (new): emits `thinking_delta` content_block_delta
  - `emitSignatureDelta(encryptedContent: Data)` (new): emits `signature_delta` content_block_delta
  - `emitThinkingBlock`: retained as fallback for upstream versions without summary streaming

- `Sources/CCRouterCore/LocalHTTPServer.swift` (bug fix surfaced by Phase 3 smoke validation)
  - `sendStreamBody`: success path now calls `writer.finish()` to emit the chunked-transfer terminator `0\r\n\r\n` (RFC 9112 §7.1). Prior Phase 1 implementation only called `finish()` on the error path, leaving success responses without a terminal chunk. HTTP clients (including `claude --bare`) reported "socket closed unexpectedly" even though the SSE payload was complete. Smoke test `scripts/smoke_local_gateway.sh` now passes.

- `Sources/CCRouterCore/IR/IRResponsesCodec.swift` (runtime-test bug fix)
  - Added `decodeTolerantBase64(_:)` helper and wired it in for `encrypted_content` decode. Upstream emits `encrypted_content` as **URL-safe base64** (`-`/`_` instead of `+`/`/`). Swift's `Data(base64Encoded:)` only accepts the standard alphabet — even with `.ignoreUnknownCharacters` the URL-safe chars are silently skipped, producing a corrupt-length string and a nil result. The runtime thinking test (curl with `thinking: {type:"enabled"}`) caught this: upstream sent 1508-char URL-safe base64, decoder returned nil, `signature_delta` never emitted. Fix: remap `-`→`+` and `_`→`/` before decoding, and strip whitespace before padding arithmetic. Regression tests: `decodeOutputItem_reasoningWithUrlSafeBase64_decodesEncryptedContent` + `decodeTolerantBase64_acceptsStandardAndUrlSafeAlphabets`.
  - `encodeInputItems` / `encodeFullHistory` text block encoding is now **role-aware**: assistant role → `output_text`, user/system → `input_text`. Upstream rejects `input_text` in assistant-role message content (400: "Invalid value: 'input_text'. Supported values are: 'output_text' and 'refusal'"). This regression surfaced in the runtime tool-history-replay test (history containing assistant text block). Regression tests: `encodeFullHistory_userAndAssistantText_usesCorrectTextType` + `encodeInputItems_assistantText_usesOutputText`.

- `Sources/CCRouterCore/IR/IRAnthropicCodec.swift`
  - `image.source.data` and `thinking.signature` decode sites switched to `IRResponsesCodec.decodeTolerantBase64` so URL-safe base64 and whitespace are tolerated end-to-end.

### Tests

- `Tests/CCRouterCoreTests/ThinkingBlockEmissionTests.swift` (new, 17 tests)
  - `encodeResponseBlock`: signature emission, nil/empty omission
  - `decodeRequestBlocks`: signature → encryptedContent, invalid base64 handling
  - Roundtrip: 256-byte encryptedContent preserved through encode → decode
  - `makeResponsesPayload`: `summary: "auto"` confirmed, `include` only `reasoning.encrypted_content`
  - `processUpstreamStream`: streaming summary delta events produce expected SSE sequence; fallback path for older upstream
  - `thinkingEnabledRequestField_doesNotOverrideRoute`: Decision C regression
  - `decodeOutputItem`: summary list flattening, legacy string passthrough, empty list
  - `encodeReplayBlocks`: summary list shape, empty summary

- `Tests/CCRouterCoreTests/ToolUseHistoryReplayTests.swift` (new, 13 tests)
  - `encodeFullHistory`: baselines (text-only, tool_use-only), interleaving, multi-turn ordering
  - Thinking/tool_use in user role → dropped silently
  - Summary list shape regression for assistant thinking in history

- `Tests/CCRouterCoreTests/IRBlockConversionTests.swift` (modified)
  - Deleted `irImageInMessageContentFallsBackToPlaceholderText` (Phase 1 placeholder, incompatible with real `input_image` shape)
  - Updated `responsesReasoningDecodesAndEncodesBackToAnthropicThinking` to expect `signature` field
  - Updated `irThinkingEncodedViaEncodeReplayBlocks` to expect list-format summary

- `Tests/CCRouterCoreTests/ImageBlockConversionTests.swift` (new, 13 tests — added Phase 3 Task 11)

### Probes & Research

- `scripts/probe_image_wire.py` (new)
- `docs/research/2026-04-22-image-wire-probe.md` (new)
- `docs/research/2026-04-22-cli-signature-passthrough.md` (new)

---

## Known Limitations

1. **Pre-Phase-3 sessions**: Thinking blocks in conversation history that lack a `signature` field (sessions started before Phase 3) will have `encryptedContent: nil` and be dropped per [D-006] on replay. This is a deliberate design choice; sessions started under Phase 3 will have full reasoning continuity.

2. **`reasoning.summary: auto` support**: The thinking streaming path requires upstream support for `reasoning.summary: auto` (gpt-5.4 confirmed, see probe). Older upstream versions will fall back to the atomic `emitThinkingBlock` path (no incremental summary streaming; signature_delta still emitted).

3. **CLI signature passthrough**: Public source inspection inconclusive; Phase 3 proceeds under the Anthropic docs assumption that CLI verbatim-preserves the `signature` field. Real-machine validation steps documented in `docs/research/2026-04-22-cli-signature-passthrough.md`.

4. **`thinking.enabled` request field**: Per Decision C, the `thinking` field in the incoming Anthropic request does not override `reasoning.effort` from the routing table. This prevents client-side effort override attacks.

---

## Next Steps (Phase 4)

- **Session state stability**: `pendingToolTurn` TTL, session deduplication
- **Prompt cache key**: deterministic key construction for repeated same-prompt scenarios
- **`pendingToolTurn` continuation filter audit**: verify `runStreamingTurn` correctly excludes non-replay items from continuation payloads
- **Advisor bridge**: `runAdvisorSubcall` still uses non-streaming `perform`; Phase 4 may add advisor streaming

---

## Decisions Resolved

| Decision | Status |
|---|---|
| [D-001] Image wire shape: `input_image` data URL | Resolved (probe Row A) |
| [D-002] Tool_result image: split into function_call_output + synthetic message | Resolved (probe Row D) |
| [D-004] Thinking SSE: `signature` field emitted to CLI | Resolved (Scheme E) |
| [D-005] Thinking decode: `signature` → `encryptedContent` base64 | Resolved (Task 3) |
| [D-006] Thinking replay drop: nil/empty `encryptedContent` → silent drop | Resolved (Design decision) |
| [D-007] CLI signature passthrough | Inconclusive; fallback + real-machine validation steps documented |
