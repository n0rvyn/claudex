# reasoning.effort Probe Report — 2026-04-22

| reasoning.effort | status | first-500-chars body |
|---|---|---|
| `low` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_0e93e536386274f10169e880f238c08197861bdffa8660ca7c","object":"response","created_at":1776845042,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null,"prom` |
| `medium` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_094990ee4c9f123d0169e880f7dc1481968850bac16c34e981","object":"response","created_at":1776845047,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null,"prom` |
| `high` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_09afa42347a035f30169e880fdf15c8193ac771154c07c0bb6","object":"response","created_at":1776845054,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null,"prom` |
| `xhigh` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_0ec01a0fc2b60a3b0169e88105e32c8194860d25b8be0b8696","object":"response","created_at":1776845061,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null,"prom` |

## Conclusion

- **All 4 values accepted (200):** `low`, `medium`, `high`, `xhigh` — probed on `gpt-5.4` on 2026-04-22. No 400 rejection from the real Codex ChatGPT endpoint.
- **Phase 6 UI picker:** surface all 4 values for user selection. No runtime filtering needed.
- **Phase 2 default in `defaultTable`:** `xhigh` (unchanged from Phase 0 baseline `docs/scheme3/09 §3.2`). Users can opt into other values via Phase 6 Routing editor.
