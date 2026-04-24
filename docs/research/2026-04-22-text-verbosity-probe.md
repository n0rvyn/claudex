# text.verbosity Probe Report — 2026-04-22

| text.verbosity | status | first-500-chars body |
|---|---|---|
| `low` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_0d0d06b666bef55b0169e881121a4c8193a5c3fd8932ac4cb6","object":"response","created_at":1776845074,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null,"prom` |
| `medium` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_09ea65a8ebc4285c0169e88118573c8193b5cdba18666f5ddb","object":"response","created_at":1776845080,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null,"prom` |
| `high` | 200 | `event: response.created
data: {"type":"response.created","response":{"id":"resp_066b627deb7389b20169e8811f79a881939982fa91b8ec74f9","object":"response","created_at":1776845087,"status":"in_progress","background":false,"completed_at":null,"error":null,"frequency_penalty":0.0,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"max_tool_calls":null,"model":"gpt-5.4","moderation":null,"output":[],"parallel_tool_calls":false,"presence_penalty":0.0,"previous_response_id":null,"prom` |

## Conclusion

- **All 3 values accepted (200):** `low`, `medium`, `high` — probed on `gpt-5.4` on 2026-04-22. No 400 rejection.
- **Phase 6 UI picker:** surface all 3 values for user selection.
- **Phase 2 default in `defaultTable`:** `low` (unchanged from Phase 0 baseline `docs/scheme3/16 §3`). Users can opt into other values via Phase 6 Routing editor.
