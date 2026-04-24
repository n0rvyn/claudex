# Phase 3 Upstream Protocol Probe Report — 2026-04-22

## Scope

Before locking Phase 3 implementation paths, probe 4 shapes against the real Codex ChatGPT endpoint (`https://chatgpt.com/backend-api/codex/responses`) to remove conditional branches from the plan.

## Rows

| Row | Label | status | turn_outcome | Conclusion |
|---|---|---|---|---|
| A | `input_image` in user message content (base64 data URL) | 200 | completed | ✅ Use this for 3a user-message images |
| B | `view_image` function injection via `tools` array | 200 | completed | ✅ Function injection pattern works (confirmed model dispatches it via forced tool_choice) — secondary option, not primary for 3a |
| C | `include: ["reasoning.encrypted_content", "reasoning.summary"]` | 400 | http_error | ❌ Do NOT add reasoning.summary to include (explicitly rejected with enum whitelist) |
| D | `function_call` + `function_call_output` + follow-up user message with `input_image` | 200 | completed | ✅ Use this for 3a tool_result images (MCP screenshot path) |
| E | `reasoning.summary: "auto"` as **request parameter** (not include) | 200 | completed | ✅ This IS the path to summary surfacing |
| F | `reasoning.summary: "auto"` + `include: ["reasoning.encrypted_content"]` combined | 200 | completed | ✅ Both work together; encrypted_content (1636 bytes) + summary (96 streaming deltas) preserved |

### Row A retry note

Row A's first attempt returned 503 "Tunnel connection failed" — transient network error, not an upstream rejection. Retry on same payload → 200 + `turn.completed`. Stable.

### Row C rejection details

Upstream returned explicit whitelist in error body:

```
Supported values are: 'file_search_call.results', 'web_search_call.results',
'web_search_call.action.sources', 'message.input_image.image_url',
'computer_call_output.output.image_url', 'code_interpreter_call.outputs',
'reasoning.encrypted_content', and 'message.output_text.logprobs'.
```

`reasoning.summary` is definitively not in the `include` whitelist. This rules out the "just add one entry to include" approach.

### Row E / F mechanism — summary via request param

When request payload sets `reasoning.summary: "auto"`:

- Upstream acknowledges in `response.created` envelope as `"reasoning": {"effort":"xhigh","summary":"detailed"}` (auto upgraded to detailed by upstream)
- 4 new SSE event types appear in the stream:
  - `response.reasoning_summary_part.added` — open of summary part within reasoning item
  - `response.reasoning_summary_text.delta` — per-chunk summary text delta (96 deltas for a ~500-char summary)
  - `response.reasoning_summary_text.done` — close of summary text
  - `response.reasoning_summary_part.done` — close of summary part
- Final `response.output_item.done` reasoning item contains BOTH:
  - `encrypted_content`: 1636-byte base64 string
  - `summary`: list of `{"type": "summary_text", "text": "..."}` objects (not a plain string)

Event sequence (gpt-5.4, effort xhigh, summary auto, prompt "Briefly: why 2+2=4?"):

```
response.created
response.in_progress
response.output_item.added       ← reasoning item opened
response.reasoning_summary_part.added
response.reasoning_summary_text.delta   ← ×96 delta events
response.reasoning_summary_text.done
response.reasoning_summary_part.done
response.output_item.done        ← reasoning item closed (encrypted_content + summary list both present)
response.content_part.added
response.output_text.delta       ← regular response text streaming
...
response.completed
```

## Decisions (locked by evidence)

1. **3a user-message images → `input_image` data URL**
   - Wire: `{"type": "input_image", "image_url": "data:image/png;base64,..."}` in user message content array
   - No conditional fallback needed; Row A green

2. **3a tool_result images (MCP screenshot) → split into 2 items**
   - First: `function_call_output` with `output: "[image follows in next user message]"` (or similar placeholder)
   - Second: synthetic user message with `input_image`
   - No conditional fallback needed; Row D green

3. **3b reasoning summary → request parameter, NOT include**
   - `makeResponsesPayload` adds `"summary": "auto"` to `reasoning` object
   - `include` array stays `["reasoning.encrypted_content"]` unchanged
   - 4 new SSE event types must be handled in `processUpstreamStream`

4. **3b streaming thinking to CLI**
   - Open Anthropic thinking block on `response.reasoning_summary_part.added` (content_block_start, type=thinking)
   - Emit `content_block_delta` with `{type: "thinking_delta", thinking: <delta>}` for each `response.reasoning_summary_text.delta`
   - On `response.output_item.done` (reasoning), emit final `content_block_delta` with `{type: "signature_delta", signature: <base64 encrypted_content>}` then `content_block_stop`
   - This preserves BOTH the real-time streaming UX and the encrypted_content roundtrip

5. **Summary list → string flattening**
   - Upstream summary is `[{"type": "summary_text", "text": "..."}, ...]`; Anthropic thinking.thinking is a plain string
   - Concatenate all summary_text values (separated by `\n\n`) when building the final IR block
   - For streaming path: each `reasoning_summary_text.delta` already gives plain string deltas, so use those directly

## Out of scope / deferred

None — all four sub-questions (image user content, image tool-result, reasoning summary, encrypted_content) resolved with green upstream evidence in one probe pass. No DP-BLOCK or DP-DEFER decisions needed.

## Evidence capture

Raw evidence:

- Combined probe (reasoning.summary=auto + include=encrypted_content): reasoning item in `output_item.done` had `encrypted_content_len=1636`, `summary_shape=list`, 96 summary deltas captured. Full sample text below.

Sample summary output (gpt-5.4, effort xhigh, prompt "Briefly: why 2+2=4?"):

```
**Explaining 2+2=4**

I need to provide a brief answer to why 2+2=4. The user likely wants a simple explanation.
So, I could say, "Because '2' represents two units, and when you add another two units,
you get four units." I might also reference Peano arithmetic if needed, explaining that
in this system, 2 and 4 are defined in terms of the number of units. However, since the
request is for brevity, I'll keep it straightforward.
```
