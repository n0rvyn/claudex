# Prompt Cache Hit Metrics Probe — 2026-04-23

**Probe purpose:** Determine whether the `/responses` upstream API exposes prompt-cache-hit
indicators (e.g. `prompt_cache_hit_tokens`, `input_tokens_details.cached_tokens`) in the
`response.completed.response.usage` SSE event field.

**Scope:** Phase 4 Session Cache Stability (Task 7). This probe does NOT affect acceptance
criteria for Phase 4 — it informs Phase 6 Dashboard design.

---

## Setup

Three consecutive requests are sent to `https://chatgpt.com/backend-api/codex/responses` with:

- Identical `prompt_cache_key`: `"modelbridge-probe-2026-04-23"`
- Identical `instructions`: `"You are a helpful assistant."`
- Identical `input[0]` message content
- Identical `model`, `reasoning.effort`, `text.verbosity`
- `tool_choice: "none"`, no tools

If upstream implements prompt caching, request 1 is a cold miss, and requests 2–3 hit the
same cache partition (same `prompt_cache_key`). Cache hits are expected to show:

- Lower `input_tokens` on requests 2–3 (only new tokens counted)
- OR a dedicated subfield in `response.usage`

**Execution:**

```bash
python3 scripts/probe_prompt_cache_hit.py > /tmp/cache-hit-probe.jsonl
```

---

## Raw usage JSON

<!-- probe execution pending: user runs the script and fills in results below -->

### Request 1 (cold)

```json
{
  "request_n": 1,
  "http_status": 200,
  "usage": { /* fill from /tmp/cache-hit-probe.jsonl line 1 */ },
  "response": { /* full response object */ }
}
```

### Request 2 (cache hit expected)

```json
{
  "request_n": 2,
  "http_status": 200,
  "usage": { /* fill from /tmp/cache-hit-probe.jsonl line 2 */ },
  "response": { /* full response object */ }
}
```

### Request 3 (cache hit expected)

```json
{
  "request_n": 3,
  "http_status": 200,
  "usage": { /* fill from /tmp/cache-hit-probe.jsonl line 3 */ },
  "response": { /* full response object */ }
}
```

---

## Conclusion

<!-- fill in after executing the probe -->

**Probe status:** pending (user executes `probe_prompt_cache_hit.py`)

### Expected positive-indication fields

If the probe reveals a cache-hit metric, the relevant field name(s) and definition should be noted here:

| Field | Description | Phase 6 use |
|-------|-------------|-------------|
| `prompt_cache_hit_tokens` | Tokens served from prompt cache | Dashboard cache-hit rate metric |
| `input_tokens_details.cached_tokens` | Cached token count in input detail | Alternative cache-hit rate numerator |
| `input_tokens_details.prompt_cache_hit` | Boolean flag | Binary cache-hit indicator |

### Interpretation guide

- **All three `usage` objects identical** → no cache field exposed; upstream may not surface cache stats.
- **`input_tokens` decreases on req 2/3** → cache is active but field may not be named; Phase 6 surrogate = turn-latency delta across same-session requests.
- **`cached_tokens` or `prompt_cache_hit_tokens` present** → Phase 6 Dashboard cache-hit rate is directly implementable.
- **HTTP 422 / 400 on req 2/3** → `prompt_cache_key` may not be supported by the current upstream API version.

---

## Amendment to Scheme3 contract

> **To be filled after probe execution.**
>
> If new subfields are discovered in `response.usage`, append an amendment note to
> `docs/scheme3/08-responses-http-contract.md` under a new subsection
> `### 4.4a Prompt cache hit fields (verified 2026-04-23)`.
