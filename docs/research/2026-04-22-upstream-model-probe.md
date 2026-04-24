# Upstream Model ID Probe Report — 2026-04-22

| Upstream Model ID | status | first-500-chars body |
|---|---|---|
| `gpt-5.4` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_0d12539d4c8536050169e880d6bf64819695e498370c4e91fd","object":"response","created_at":1776845014,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null,"prom` |
| `gpt-5.4-mini` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_07b6a735a860df390169e880dcf07c819086ba0c8d39519008","object":"response","created_at":1776845020,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4-mini-2026-03-17","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_respons` |
| `gpt-5.3-codex` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_0102f43e97087e8b0169e880de84b081948503da66ddc606ea","object":"response","created_at":1776845022,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.3-codex","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null` |
| `gpt-4.5` | 400 | `{"detail":"The 'gpt-4.5' model is not supported when using Codex with a ChatGPT account."}` |
| `gpt-5.3-codex-spark` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_00636ebd33b229cf0169e880e79c2c81939bc2bbbf4d4ad633","object":"response","created_at":1776845031,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.3-codex-spark","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id` |

## Conclusion

- **Add to default routing table:**
  - `gpt-5.3-codex-spark` — per DP-002 Option B (chosen 2026-04-22), `haiku` rule in `Sources/CCRouterCore/ModelRouting.swift` `defaultTable` now maps to this ID, delivering the user-requested routing immediately.
- **Keep as fallback / available manual pick (Phase 6 UI):**
  - `gpt-5.4` — retained for `opus` / `sonnet` rules + table fallback.
  - `gpt-5.4-mini` — available for manual selection in Phase 6 UI; upstream resolves to `gpt-5.4-mini-2026-03-17`.
  - `gpt-5.3-codex` — available for manual selection in Phase 6 UI.
- **Reject (do NOT route to):**
  - `gpt-4.5` — confirmed 400 with `"The 'gpt-4.5' model is not supported when using Codex with a ChatGPT account."` Excluded from default table and from Phase 6 UI picker.
