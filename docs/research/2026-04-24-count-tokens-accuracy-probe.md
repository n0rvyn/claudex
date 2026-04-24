---
type: research
phase: 5
topic: count_tokens accuracy vs upstream
date: 2026-04-24
---

# Phase 5 V2 — count_tokens accuracy probe

## Method

For each case, the Anthropic-shape payload is sent to the local daemon's
`POST /v1/messages/count_tokens` endpoint to obtain `daemon_bpe`. A semantically
equivalent `/responses`-shape payload is sent directly to the real upstream
(`https://chatgpt.com/backend-api/codex/responses`), and the `response.completed`
event's `response.usage.input_tokens` is read as `upstream_baseline`.

Deviation = |daemon_bpe - upstream_baseline| / upstream_baseline.

Auth loaded from `~/.codex/auth.json`. Transport: zstd-compressed POST with
`accept: text/event-stream`, matching the daemon's own upstream path.

## Results

| # | Case | daemon_bpe | upstream_baseline | deviation | result |
|--:|------|-----------:|------------------:|----------:|:-------|
| 1 | Case 1: single-turn text | 8 | 13 | 38.46% | FAIL |
| 2 | Case 2: multi-turn text | 27 | 43 | 37.21% | FAIL |
| 3 | Case 3: with system prompt | 19 | 29 | 34.48% | FAIL |
| 4 | Case 4: with 16 tools | 624 | 516 | 20.93% | FAIL |
| 5 | Case 5: with tool_result | 73 | 184 | 60.33% | FAIL |

**Max deviation:** 60.33%  —  **Overall:** FAIL (threshold 10%)

## Notes

- The daemon's `countablePayload` is constructed via the same IR codec path
  used by `messageStartInputTokens`, so `count_tokens` and `message_start.usage.input_tokens`
  are byte-identical (see `AnthropicBridge.swift:248-263`).
- Semantic equivalence between Anthropic and /responses payloads is preserved
  by mirroring `buildCountablePayload`'s transformation: system → instructions,
  tool_use/tool_result → function_call/function_call_output.

## Gap analysis

The current counter (`AnthropicInputTokenCounter.swift`) uses `cl100k_base` BPE on
the concatenation of text-bearing strings (instructions, message text,
tool name/description/parameters-as-canonical-JSON). It does NOT model:

1. **Chat-format overhead.** Upstream wraps each message with role/separator
   tokens; a single short user message incurs ~5 tokens of structural overhead
   that the daemon misses. This explains the ~30-40% under-count on
   text-only cases (1-3).
2. **function_call / function_call_output structural tokens.** Case 5 shows
   the widest gap (60.33%). Upstream encodes function_call items with
   substantial wrapping (call_id tokens, name tokens, argument-type tokens,
   output framing) that the daemon counts only as raw argument string.
3. **Tokenizer mismatch.** Upstream gpt-5.4 likely uses `o200k_base`, not
   `cl100k_base`. Even on the same text, the counts differ; this is additive
   with items 1 and 2.
4. **Tool schema serialization.** Case 4 over-counts by 20.93% — the
   daemon's pretty-ish canonical JSON (sortedKeys, default whitespace via
   `JSONEncoder`) likely inflates relative to upstream's structured
   tool-schema encoding.

## Conclusion

Current `countTokensStrategy: cl100k-bpe` deviates 20-60% from upstream
`response.usage.input_tokens` on the 5 required acceptance cases. This does
not meet Phase 5's ≤ 10% acceptance criterion. The choice recorded in
DP-005 (pure Swift BPE on `cl100k_base`) was intentionally the lower-cost
option; the ≤ 10% target is not reachable without either:

- switching to `o200k_base` and adding chat-format + function_call
  overhead modeling, or
- falling back to a probe-based strategy (DP-005 Option C).

Both are substantive scope beyond DP-005's Chosen path. Recommendation:
record as deferred (GitHub issue, `deferred` + `phase-5` labels), proceed
to Phase 6 with the current heuristic documented in the Settings UI's
Token status block, and revisit in a follow-on.

