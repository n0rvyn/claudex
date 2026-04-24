# Claude Code CLI + OpenAI Subscription Router

Date: 2026-04-20

## 1. Scope

This document evaluates one problem only:

- Frontend must remain `Claude Code CLI`
- Backend billing must go through an `OpenAI subscription`, not the public OpenAI API billing path

This document excludes any claim that was not validated twice.

## 2. Validation Method

Each conclusion below is backed by at least two artifacts chosen from:

- official vendor documentation
- official open-source source code
- local CLI output
- local runtime probe
- official-doc search results

Searches were run on `2026-04-20`.

## 3. Evidence Ledger

| Claim | Evidence A | Evidence B | Result |
| --- | --- | --- | --- |
| Claude Code can target a custom gateway, but the gateway must speak Claude-compatible API shapes | Anthropic `LLM gateway` docs require `/v1/messages` and `/v1/messages/count_tokens`, and require forwarding `anthropic-beta` and `anthropic-version`: <https://code.claude.com/docs/en/llm-gateway> | Local runtime probe captured a real `claude` request to `POST /v1/messages?beta=true` with `anthropic-beta`, `anthropic-version`, and `X-Claude-Code-Session-Id` headers | Confirmed |
| Claude Code is not satisfied by a generic OpenAI endpoint; it expects Anthropic Messages semantics | Anthropic `LLM gateway` docs define the accepted formats and the required Anthropic headers: <https://code.claude.com/docs/en/llm-gateway> | The local runtime probe showed Claude Code sending an Anthropic-style request body with `model`, `messages`, `system`, `tools`, `thinking`, `context_management`, and `stream: true` to `/v1/messages?beta=true` | Confirmed |
| Codex can authenticate with a ChatGPT subscription, not only an API key | OpenAI Codex CLI docs: “Authenticate with your ChatGPT account or an API key” and “ChatGPT Plus, Pro, Business, Edu, and Enterprise plans include Codex”: <https://developers.openai.com/codex/cli> | Local `codex login status` output: `Logged in using ChatGPT`; official `login.rs` also prints `Logged in using ChatGPT` for `AuthMode::Chatgpt | AuthMode::ChatgptAuthTokens`: <https://github.com/openai/codex/blob/main/codex-rs/cli/src/login.rs> | Confirmed |
| Codex has a dedicated ChatGPT backend surface under `/backend-api` | Official source `backend-client/src/client.rs` normalizes `https://chatgpt.com` and `https://chat.openai.com` to include `/backend-api`, then switches path style to `/wham/...`: <https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client.rs> | Local runtime probe with `chatgpt_base_url="http://127.0.0.1:8767/backend-api"` captured `GET /backend-api/plugins/list`, `GET /backend-api/plugins/featured`, and `POST /backend-api/codex/analytics-events/events` | Confirmed |
| Codex also has a direct model/inference surface under `openai_base_url`, and the built-in `openai` provider calls `/responses`, not `/wham/tasks`, during `codex exec` | Official config schema and source define `chatgpt_base_url` as “Base URL for requests to ChatGPT (as opposed to the OpenAI API)” and `openai_base_url` as the override for the built-in `openai` provider: <https://github.com/openai/codex/blob/main/codex-rs/config/src/config_toml.rs>, <https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json> | Local runtime probe with `openai_base_url="http://127.0.0.1:8767"` captured repeated `GET /responses` and `POST /responses`; `codex exec` failed with `unexpected status 404 Not Found ... url: http://127.0.0.1:8767/responses` after the override | Confirmed |
| In ChatGPT login mode, Codex sends `Authorization: Bearer ...` and `chatgpt-account-id` on both `/backend-api/...` and `/responses` requests | Official source `chatgpt_client.rs` sends bearer auth and `chatgpt-account-id` to the ChatGPT backend API: <https://github.com/openai/codex/blob/main/codex-rs/chatgpt/src/chatgpt_client.rs> | Local probe log `/tmp/codex-probe3.log` captured `has_authorization: true`, `authorization_prefix: "Bearer"`, and `has_chatgpt_account_id: true` for `GET /backend-api/plugins/list`, `GET /responses`, and `POST /responses` | Confirmed |
| For the current `codex-cli 0.121.0` non-interactive single-turn text path, websocket failure at `/responses` does not block completion; HTTP SSE is sufficient | Official source `core/src/client.rs` says a turn uses one or more Responses API requests, prewarm websocket failure is handled by “normal stream retry/fallback logic,” and websocket fallback can be forced to HTTP for the session: <https://raw.githubusercontent.com/openai/codex/main/codex-rs/core/src/client.rs> | Local probe on `127.0.0.1:8768` returned repeated `404` on `GET /responses` and then a minimal SSE success stream on `POST /responses`; `codex exec` still completed with `item.completed` text `Okay` and `turn.completed` | Confirmed for the current probed path |
| A real captured `POST /responses` body can be decompressed from zstd into a standard Responses create payload skeleton | OpenAI Responses API reference documents request fields such as `model`, `instructions`, `input`, `tools`, `tool_choice`, `parallel_tool_calls`, `reasoning`, `store`, `stream`, and `service_tier`: <https://platform.openai.com/docs/api-reference/responses/compact?api-mode=responses> | Local captured `/tmp/codex-responses-body.zst` decompressed to JSON containing those fields plus `prompt_cache_key`, `text`, and `client_metadata`; the sample had `model: "gpt-5.4"`, `stream: true`, `store: false`, `tool_choice: "auto"`, and `reasoning.effort: "xhigh"` | Confirmed for the captured sample |
| The current ChatGPT-login default direct route targets `chatgpt.com/backend-api/codex/responses`, not the public `api.openai.com/v1/responses` path | Local proxy-probe run with `HTTPS_PROXY` forced `CONNECT chatgpt.com:443`; the resulting Codex errors named `wss://chatgpt.com/backend-api/codex/responses` and `https://chatgpt.com/backend-api/codex/responses` | A local forwarding proxy to `https://chatgpt.com/backend-api/codex/responses` returned `200` and streamed a successful response, while the same request forwarded to `https://api.openai.com/v1/responses` returned `401 Unauthorized` with `Missing scopes: api.responses.write` | Confirmed for the current machine and CLI path |
| A raw ChatGPT-auth bearer plus `chatgpt-account-id` is not accepted by the public Responses API for writes | Local forwarding proxy to `https://api.openai.com/v1/responses` relayed the captured `/responses` request unchanged except for transport headers | The upstream JSON error body explicitly said `Missing scopes: api.responses.write` and `codex exec` terminated with `turn.failed` on `401 Unauthorized` | Confirmed for the current machine |
| The real upstream success stream is a superset of the local minimal contract; it adds a reasoning item before the assistant message and includes extra sequencing fields | OpenAI streaming docs list `response.created`, `response.output_item.added`, `response.content_part.added`, `response.output_text.delta`, `response.output_item.done`, and `response.completed` event types: <https://platform.openai.com/docs/guides/streaming-responses>, <https://platform.openai.com/docs/api-reference/responses-streaming/response/output_text/delta?lang=javascript> | Real upstream capture from `https://chatgpt.com/backend-api/codex/responses` produced the sequence `response.created -> response.in_progress -> response.output_item.added(reasoning) -> response.output_item.done(reasoning) -> response.output_item.added(message) -> response.content_part.added -> response.output_text.delta -> response.output_text.done -> response.content_part.done -> response.output_item.done(message) -> response.completed`; sampled events included `sequence_number`, `logprobs`, `obfuscation`, and reasoning `encrypted_content` | Confirmed for the captured sample |
| For the current `codex exec --json` single-turn text path, the real upstream sample can be reduced to the local minimal SSE contract and still complete successfully | Local replay experiments ran ten variants derived from the real upstream sample; `baseline`, `drop_sequence_number`, `drop_reasoning_item`, `drop_annotations`, `drop_annotations_logprobs`, `drop_obfuscation`, `drop_response_extras`, `drop_all_optional`, `drop_reasoning_and_optional`, and `probe_minimal` all ended with `turn.completed` | The final `probe_minimal` variant removed reasoning items, all observed `sequence_number`, `annotations`, `logprobs`, `obfuscation`, and extra response metadata, yet `codex exec` still returned `item.completed` and `turn.completed` | Confirmed for the current probed path |
| Claude default mode and bare mode expose different tool inventories, and the current Claude/Codex tool names have no direct overlap | Local capture of `claude` against a loopback `/v1/messages` server recorded 4 tools: `Bash`, `Edit`, `Read`, and `advisor`; local capture of `claude` recorded 56 tools with 55 `function` plus 1 `advisor_20260301` | Comparing the captured default Claude tool names with the current `/responses` tool names from the zstd request body produced an empty intersection; the current `/responses` sample has 16 tools with types `function`, `custom`, `web_search`, and `namespace` | Confirmed for the current machine and CLI path |
| The current subscription-backed `/responses` endpoint accepts Claude-derived function tool declarations after envelope rewriting | A local forwarding proxy replaced the real `/responses` request's `tools` array with 3 converted function tools from the captured `claude` request and `codex exec` still ended with `turn.completed` | The same proxy pattern replaced `tools` with 55 converted function tools from the captured default `claude` request; the persisted log `/tmp/codex-claude-tool-rewrite-full.log` ended with `item.completed` and `turn.completed` | Confirmed for the current text path |
| The current subscription-backed `/responses` endpoint accepts a Claude-style function roundtrip using `function_call_output` | OpenAI function-calling docs say a tool result is sent back as an input item with `type: "function_call_output"`, `call_id`, and `output`, and show appending those results back into the next Responses call: <https://developers.openai.com/api/docs/guides/function-calling> | A local two-step proxy forced the converted `Bash` tool on the first `/responses` call, captured a real upstream `function_call` named `Bash`, then sent a second `/responses` call with `reasoning + function_call + function_call_output`; this completed once with the bare 3-tool set and once with the default 55-function-tool set, and both `codex exec` runs ended with `turn.completed` | Confirmed for the current function-tool roundtrip path |
| The current subscription-backed `/responses` endpoint also accepts representative Claude function families beyond `Bash` and at least one high-risk concrete `mcp__...` instance | OpenAI function-calling docs define the same multi-turn contract for all function tools: return the tool result as `function_call_output` with the model-provided `call_id`: <https://developers.openai.com/api/docs/guides/function-calling> | Local two-step probes forced `WebSearch`, `Agent`, `Read`, `Edit`, `Write`, `TodoWrite`, `AskUserQuestion`, `mcp__claude_ai_Google_Drive__authenticate`, and `mcp__plugin_Notion_notion__authenticate` under the default Claude tool inventory; each run produced a real upstream `function_call`, accepted a second request containing `reasoning + function_call + function_call_output`, and ended with `codex exec` `turn.completed` | Confirmed for the current representative set and one concrete high-risk `mcp__...` instance; this is not proof that every individual tool instance or mcp schema works |
| The current subscription-backed `/responses` endpoint rejects raw passthrough of Claude's `advisor_20260301` tool shape | Local Claude capture recorded the raw advisor object exactly as `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-4-7"}` in the default `claude` request body | A local forwarding proxy appended that raw object to the rewritten `tools` array; the first upstream `https://chatgpt.com/backend-api/codex/responses` call returned `400 Bad Request` with body `{"detail":"Unsupported tool type: advisor_20260301"}`, and `codex exec` ended with `turn.failed` | Confirmed for the current raw-passthrough path; this does not rule out a separate adapter strategy |
| Anthropic now publishes an official Advisor tool contract, and it defines advisor as a single-request server-side tool | Official `Advisor tool` docs specify the request shape `{"type":"advisor_20260301","name":"advisor","model":"..."}`, the response blocks `server_tool_use` and `advisor_tool_result`, and require carrying `advisor_tool_result` forward on later turns: <https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool> | Local `claude` probe against a loopback Anthropic mock accepted `server_tool_use + advisor_tool_result`, and a follow-up `claude -r` request replayed both blocks verbatim in assistant history | Confirmed |
| A local Anthropic-compatible gateway can preserve advisor semantics for Claude Code by returning `server_tool_use + advisor_tool_result` without any client-side tool roundtrip | Official Advisor docs say the advisor call stays inside one `/v1/messages` request and the client must carry `advisor_tool_result` forward on later turns: <https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool> | Local probe server on `127.0.0.1:8781` returned those blocks, `claude` completed with `Advisor consulted. Final answer from the first turn.`, and the resumed request contained assistant content blocks `server_tool_use` and `advisor_tool_result` | Confirmed |
| The subscription-backed `/responses` path can bridge advisor by translating it to a synthetic zero-arg function plus a local subcall | OpenAI function-calling docs define the `function_call_output` roundtrip shape: <https://developers.openai.com/api/docs/guides/function-calling> | Local bridge probe on `127.0.0.1:8782` forced a synthetic `advisor` function call, executed a second real `/responses` subcall to obtain advice text, then sent `function_call_output` back into the main turn; both `gpt-5.4 -> gpt-5.4` and `gpt-5.3-codex -> gpt-5.4` samples ended with `turn.completed` | Confirmed for the current bridge prototype |
| The ChatGPT-subscription `/responses` endpoint accepts some model IDs and rejects others when called through Codex account auth | Official OpenAI model docs describe `gpt-5.4` as the flagship model and `gpt-5.3-codex` as an agentic coding model: <https://developers.openai.com/api/docs/models>, <https://developers.openai.com/api/docs/models/gpt-5.3-codex> | Local direct probes to `https://chatgpt.com/backend-api/codex/responses` with ChatGPT auth returned `200` for `gpt-5.4`, `gpt-5.4-mini`, and `gpt-5.3-codex`, and `400` with explicit unsupported-model errors for `gpt-5.2-codex` and `gpt-5.1-codex-max` | Confirmed for the current machine |
| HTTP-only `/responses` currently covers non-interactive multi-turn text and resumed native tool paths | Official `codex exec resume` CLI exists and resumes a previous session by id: local `codex exec resume --help` | Local transparent proxy on `127.0.0.1:8784` returned `404` for every websocket `GET /responses` and transparently forwarded only HTTP `POST /responses`; both `Reply exactly FIRST. -> Reply exactly SECOND.` and `Reply exactly ALPHA. -> Read /etc/hosts and reply with only the first token.` sessions completed, and the resumed tool path showed a first HTTP response with `function_call(name=\"exec_command\")` followed by a second HTTP request carrying `function_call_output` | Confirmed for current non-interactive CLI paths |
| HTTP-only `/responses` also covers the current interactive TUI `features.apps=true` first-turn text path | Local interactive `codex --no-alt-screen -c 'features.apps=true'` run printed `APPSHTTP` after repeated websocket `404` retries | Paired forward log on `127.0.0.1:8806` showed repeated `GET /responses` websocket attempts followed by `POST /responses -> 200` | Confirmed for the current interactive first-turn text path |
| HTTP-only `/responses` also covers the current interactive TUI `features.apps=true` same-session second-turn text path | A validated interactive run recorded same-session outputs `APPDEEP1` and `APPDEEP2` under `codex --no-alt-screen --enable apps` | Paired forward log on `127.0.0.1:8850` showed `GET /responses = 7`, `POST /responses = 2`, and `200` responses = `2` | Confirmed for the current interactive second-turn text path |
| The current `/responses` and `/v1/messages` error surfaces do not normalize the same way | Local `/responses` loopback probes showed that `400` preserves the JSON body, `500` is rewritten to a fixed high-demand message, and malformed SSE plus truncated SSE both end as `stream disconnected before completion` in `codex exec --json` | Local `/v1/messages` loopback probes showed that `400` prints `API Error: 400 {...}`, malformed SSE exposes JSON parse errors before failing on `_.input_tokens`, truncated SSE fails on the same `_.input_tokens` path, and a clean `500` sample produced 10 POST retries within 15 seconds without terminal error text | Confirmed for current CLI paths |
| The currently observed `/backend-api` sidecar requests are not required for the current non-interactive main path | Local blocker on `127.0.0.1:8796` forced `404` on `/backend-api/plugins/list`, `/backend-api/plugins/featured`, and `/backend-api/codex/analytics-events/events` while `/responses` still forwarded successfully; `codex exec` still ended with `item.completed` text `SIDECAR` and `turn.completed` | Local blocker on `127.0.0.1:8798` forced `500` on the same `/backend-api` paths while `/responses` still forwarded successfully; `codex exec` still ended with `item.completed` text `SIDECAR500` and `turn.completed` | Confirmed for the current non-interactive CLI path |
| The currently observed `/backend-api` sidecar requests are also not hard dependencies for the current interactive `features.apps=true` first-turn text path | Local blocker on `127.0.0.1:8808` forced `404` on `/backend-api/plugins/featured?platform=codex`, `/backend-api/plugins/list`, `/backend-api/wham/apps`, `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`, `/backend-api/wham/usage`, and `/backend-api/codex/analytics-events/events`; the interactive TUI still printed `APPS404`, and the paired `/responses` forward log on `127.0.0.1:8807` showed `POST /responses -> 200` | Local blocker on `127.0.0.1:8810` forced `500` on `/backend-api/plugins/list`, `/backend-api/plugins/featured?platform=codex`, `/backend-api/wham/apps`, `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`, and `/backend-api/codex/analytics-events/events`; the interactive TUI printed `MCP client for \`codex_apps\` failed to start`, `MCP startup incomplete (failed: codex_apps)`, then `APPS500`, and the paired `/responses` forward log on `127.0.0.1:8809` showed `POST /responses -> 200` | Confirmed for the current interactive first-turn text path |
| The currently observed `/backend-api` sidecar requests are also not hard dependencies for the current interactive `features.apps=true` same-session second-turn text path | A validated interactive run with a `404` blocker recorded same-session outputs `APPDEEP4041` and `APPDEEP4042`; the paired `/responses` forward log on `127.0.0.1:8851` showed `POST /responses = 2` and `200` responses = `2`, while the blocker log on `127.0.0.1:8852` captured `/backend-api/codex/analytics-events/events`, `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`, `/backend-api/plugins/featured?platform=codex`, `/backend-api/plugins/list`, `/backend-api/wham/apps`, and `/backend-api/wham/usage` | A validated interactive run with a `500` blocker recorded same-session outputs `APPDEEP5001` and `APPDEEP5002`; the paired `/responses` forward log on `127.0.0.1:8853` showed `POST /responses = 2` and `200` responses = `2`, while the blocker log on `127.0.0.1:8854` captured the same sidecar paths and the TUI exposed `MCP client for \`codex_apps\` failed to start` and `MCP startup incomplete (failed: codex_apps)` | Confirmed for the current interactive second-turn text path |
| The current GitHub app business action `github_get_user_login` succeeds under direct normal routing and under a forward-only `/responses` control, but fails under sidecar `404` and sidecar `500` even while `/responses` stays healthy | Official source separates `openai_base_url` from `chatgpt_base_url`, so `/responses` and `/backend-api/...` can be controlled independently: <https://github.com/openai/codex/blob/main/codex-rs/config/src/config_toml.rs> | Local direct run completed with `mcp_tool_call github_get_user_login` and structured result `{"login":"n0rvyn","id":99057954}`; local forward-only control on `127.0.0.1:8874` completed with the same result and forward log `GET /responses = 7`, `POST /responses = 2`, `200 = 2`; sidecar blocker runs on `127.0.0.1:8871/backend-api` and `127.0.0.1:8873/backend-api` kept `/responses` healthy but both failed with `tool call error: failed to get client` and assistant-level GitHub login failure text | Confirmed for the current GitHub app action |
| The current interactive `features.apps=true` first-turn text path now has direct `/responses` `400` and `500` terminal evidence | Local loopback probe on `127.0.0.1:8821` forced websocket `404` and HTTP `400 {"detail":"forced 400 from local /responses probe"}`; the saved transcript `/tmp/codex-interactive-errors-8821.typescript` normalized to `■{"detail":"forced400fromlocal/responsesprobe"}`, and the probe log recorded `POST /responses = 1` | Local loopback probe on `127.0.0.1:8822` forced websocket `404` and HTTP `500 {"detail":"forced 500 from local /responses probe"}`; the saved transcript `/tmp/codex-interactive-errors-8822.typescript` normalized to `■We'recurrentlyexperiencinghighdemand,whichmaycausetemporaryerrors.`, and the probe log recorded `POST /responses = 30` | Confirmed for the current interactive first-turn text path |
| The current interactive `features.apps=true` first-turn text path now also has direct `/responses` malformed-SSE and truncated-SSE terminal evidence | Local loopback probe on `127.0.0.1:8832` forced websocket `404` and HTTP `malformed-sse`; the saved expect log `/tmp/codex-interactive-apps-malformed-8832.expect.log` ended with `■ stream disconnected before completion: stream closed before response.completed`, and the probe log recorded `POST /responses = 6` with last response kind `malformed-sse` | Local loopback probe on `127.0.0.1:8833` forced websocket `404` and HTTP `truncated-sse`; the saved expect log `/tmp/codex-interactive-apps-truncated-8833.expect.log` ended with `■ stream disconnected before completion: stream closed before response.completed`, and the probe log recorded `POST /responses = 6` with last response kind `truncated-sse` | Confirmed for the current interactive first-turn text path |
| The current first-turn `/responses` request skeleton is stable across four decoded samples; current structural differences are concentrated in tool inventory | Four decoded request bodies from `/tmp/responses-forward-8797/008-request.json`, `/tmp/responses-forward-8797/016-request.json`, `/tmp/codex-apps-http-only-8806/008-request.json`, and `/tmp/codex-interactive-errors-8821/008-request.json` had identical top-level keys `client_metadata, include, input, instructions, model, parallel_tool_calls, prompt_cache_key, reasoning, service_tier, store, stream, text, tool_choice, tools` | The same four samples also shared `model:"gpt-5.4"`, `stream:true`, `store:false`, `tool_choice:"auto"`, `parallel_tool_calls:true`, `include:["reasoning.encrypted_content"]`, `service_tier:"priority"`, `prompt_cache_key` as a string, and `input_len = 3`; the verified differences were `tools_len = 16` vs `21` and `namespace` inventory changes under `features.apps=true` | Confirmed for the current four first-turn samples |
| The current non-interactive `features.apps=true` `codex exec/exec resume` text path also completes over HTTP-only after websocket `404` | Local forward proxy on `127.0.0.1:8823` forced websocket `GET /responses` to `404` and transparently forwarded HTTP `POST /responses`; first turn `Reply exactly APPSRESUME1.` ended with `item.completed` text `APPSRESUME1` and `turn.completed` | The resumed turn `Reply exactly APPSRESUME2.` against the same thread also ended with `item.completed` text `APPSRESUME2` and `turn.completed`; the paired log recorded `POST /responses = 2`, request 1 `input_len = 3`, request 2 `input_len = 6`, and both requests `tools_len = 21` with 6 `namespace` tools | Confirmed for the current non-interactive apps text path |
| The current non-interactive `features.apps=true` `codex exec/exec resume` text path does not treat the observed sidecar calls as hard dependencies | Local blocker on `127.0.0.1:8825` forced `404` on `/backend-api/codex/analytics-events/events`, `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`, `/backend-api/plugins/featured?platform=codex`, `/backend-api/plugins/list`, and `/backend-api/wham/apps`; first turn still ended with `APPSSIDE404A`, resumed turn still ended with `APPSSIDE404B`, and the paired `/responses` forwarder recorded two successful POSTs | Local blocker on `127.0.0.1:8827` forced the same sidecar paths to `500`; first turn still ended with `APPSSIDE500A`, resumed turn still ended with `APPSSIDE500B`, and both runs exposed only stderr from `rmcp::transport::worker ... data did not match any variant of untagged enum JsonRpcMessage ...` without blocking `turn.completed` | Confirmed for the current non-interactive apps text path |
| The current interactive `features.apps=true` same-session second-turn text path has a different `/responses` error surface than the first-turn text path | Local `400` injection on the second `POST /responses` at `127.0.0.1:8860` produced terminal output `{"detail": "forced 400 from local /responses proxy"}` with `POST /responses = 2` | Local `500`, `malformed-sse`, and `truncated-sse` injections on the second `POST /responses` at `127.0.0.1:8861`, `127.0.0.1:8862`, and `127.0.0.1:8863` all triggered one reconnect/replay and then recovered with terminal outputs `APPERR500B`, `APPERRMALB`, and `APPERRTRUNCB`; each log recorded `POST /responses = 3` | Confirmed for the current interactive second-turn text path |
| The current tested Claude CLI paths did not call `/v1/messages/count_tokens` | Anthropic gateway docs require the endpoint, and Anthropic `Count tokens in a Message` docs define a response containing `input_tokens`: <https://code.claude.com/docs/en/llm-gateway>, <https://platform.claude.com/docs/en/api/messages/count_tokens> | Local loopback success probes for `claude`, default `claude`, `claude` plus `-r` resume, interactive `claude --bare`, default interactive `claude`, `claude --continue`, a real `claude` tool-use roundtrip, and `claude` all recorded only `POST /v1/messages`; all eight paths had `0` observed `POST /v1/messages/count_tokens` | Confirmed for current tested Claude paths |
| The default `claude` tool-use path now has direct `400 / 500 / malformed-sse / truncated-sse` terminal evidence on the second `/v1/messages` call | Local loopback tool-roundtrip probe on `127.0.0.1:8840` forced a first-turn `Read` tool_use and a second-call `400 {"type":"error","error":{"type":"invalid_request_error","message":"forced 400 from local tool-roundtrip probe"}}`; the terminal printed `API Error: 400 ...`, and the probe log recorded `POST /v1/messages = 2` with the second request already carrying `tool_result` | Local loopback tool-roundtrip probes on `127.0.0.1:8841`, `8842`, and `8843` showed: `500` produced `POST /v1/messages = 8` with no visible terminal error text in a local `30s` time-bounded PTY run; `malformed-sse` printed `Could not parse message into JSON: {not-json}` then `undefined is not an object (evaluating '_.input_tokens')` with `POST /v1/messages = 3`; `truncated-sse` printed `undefined is not an object (evaluating '_.input_tokens')` with `POST /v1/messages = 3`; all three probes confirmed the second request already carried `tool_result` | Confirmed for the current default tool-use path |
| The primary direct route is model-like, not task-like | Official source `cloud-tasks-client/src/http.rs` shows `/wham/tasks` is used by the cloud-task helper layer, while the built-in provider is separately configurable via `openai_base_url`: <https://github.com/openai/codex/blob/main/codex-rs/cloud-tasks-client/src/http.rs>, <https://github.com/openai/codex/blob/main/codex-rs/config/src/config_toml.rs> | Local probe of `codex exec` with both overrides hit `/responses` for inference and did not rely on `/wham/tasks` before the turn failed | Confirmed |
| `codex app-server` is a stateful agent/control protocol, not a plain model API | Official README: `codex app-server` powers rich interfaces; protocol is JSON-RPC with `Thread`, `Turn`, and `Item`: <https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md> | Local `codex app-server --help` exposes an experimental server process; the README also documents `turn/start`, streaming `item/*` events, approvals, and auth/account endpoints | Confirmed |
| `codex app-server` is subscription-aware | Official README documents `account/updated`, `planType`, and `account/rateLimits/read`: <https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md> | Local `codex login status` confirms this machine is currently running on the ChatGPT auth path, not the API key path | Confirmed |
| `codex mcp-server` is also a control plane, not a model endpoint | Official MCP interface docs describe JSON-RPC methods such as `thread/start`, `turn/start`, `account/read`, `account/rateLimits/read`: <https://github.com/openai/codex/blob/main/codex-rs/docs/codex_mcp_interface.md> | Local `codex mcp-server --help` shows only an MCP server process; no HTTP model endpoint is exposed | Confirmed |
| I did not find official documentation for a public “subscription-backed model API” that external apps can call directly with ChatGPT/Codex subscription entitlement | Official-doc searches for `site:developers.openai.com/docs "ChatGPT account" "Responses API"`, `site:developers.openai.com/docs "ChatGPT Plus" "API key" "Responses API"`, and `site:developers.openai.com/docs "subscription" "API key" "ChatGPT" "Responses API"` returned no results | OpenAI model docs for GPT-5-Codex document token pricing and API usage tiers for the Responses API, which is an API-billed surface: <https://developers.openai.com/api/docs/models/gpt-5-codex> | Confirmed as a search result; this is not proof of nonexistence, only proof that no official public documentation was found |

## 4. Runtime Probe

The local Claude probe was run against a mock server on `127.0.0.1`.

Observed request:

- path: `/v1/messages?beta=true`
- headers included:
  - `anthropic-beta`
  - `anthropic-version: 2023-06-01`
  - `X-Claude-Code-Session-Id`
  - `x-api-key`
- body included:
  - `model`
  - `messages`
  - `system`
  - `tools`
  - `thinking`
  - `context_management`
  - `stream: true`

This matters because any replacement backend for Claude Code must either:

- implement these Anthropic-facing semantics directly, or
- sit behind a local adapter that implements them

## 5. What Is Ruled Out

### 5.1 Direct OpenAI Responses API

This route conflicts with the hard billing constraint.

Validated reason:

- the OpenAI model docs present `Responses API` as a token-priced API surface with API usage tiers: <https://developers.openai.com/api/docs/models/gpt-5-codex>
- no official OpenAI docs were found for using ChatGPT/Codex subscription entitlement as a drop-in substitute for that public API

### 5.2 LiteLLM or any OpenAI-API-billed proxy

This route conflicts with the same billing constraint.

Validated reason:

- Claude Code does support an LLM gateway: <https://code.claude.com/docs/en/llm-gateway>
- but using a proxy in front of the public OpenAI API still lands on API billing, not ChatGPT subscription billing

### 5.3 Codex MCP Server as the main backend

This route does not satisfy Claude Code’s model requirement.

Validated reason:

- Claude Code still needs a model-compatible gateway
- `codex mcp-server` exposes a tool/control interface, not a model endpoint

## 6. Confirmed Public-Surface Options

After verification, only two options remain inside the set of publicly documented and locally verified surfaces.

| Rank | Option | Why it survives verification | Main cost |
| --- | --- | --- | --- |
| 1 | `Anthropic Messages <-> codex app-server` semantic bridge | Claude Code can point at a custom gateway; Codex app-server is subscription-aware and remotely controllable | Heavy protocol translation between model semantics and agent semantics |
| 2 | `Anthropic Messages <-> codex exec` process bridge | `codex exec` exists and runs non-interactively; ChatGPT login is supported locally | Weaker structure, weaker streaming fidelity, weaker session control |

## 7. Option Detail

### 7.1 Option 1: `Anthropic Messages <-> codex app-server`

#### Architecture

- A local macOS daemon exposes:
  - `POST /v1/messages`
  - `POST /v1/messages/count_tokens`
- Claude Code CLI talks only to this daemon through `ANTHROPIC_BASE_URL`
- The daemon connects to `codex app-server`
- The daemon maps:
  - Claude request -> `thread/start` or `turn/start`
  - Codex `item/agentMessage/delta` stream -> Anthropic-compatible SSE stream
  - auth/quota visibility -> app-server account endpoints

#### Why this option is valid

- Claude Code’s gateway contract is documented and was observed at runtime
- Codex app-server is officially documented and exposes subscription-aware account endpoints

#### Hard problem

This is not a plain proxy.

Validated reason:

- Claude Code expects model-style tool semantics inside a single `/v1/messages` exchange
- Codex app-server exposes a higher-level agent runtime with its own turns, approvals, and side effects

Practical consequence:

- the bridge has to translate between two different abstraction layers
- tool ownership, approval flow, and streaming granularity are the hardest parts

#### Assessment

This is the strongest fully verified route.

It is not the cleanest architecture in the abstract, but it is the best route that stays inside:

- `Claude Code CLI`
- `OpenAI subscription`
- `officially documented surfaces`

### 7.2 Option 2: `Anthropic Messages <-> codex exec`

#### Architecture

- A local macOS daemon still exposes Anthropic Messages
- Instead of talking to app-server, it launches `codex exec` for each request or for a managed session
- The daemon scrapes structured output from `codex exec --json` or last-message output files

#### Why this option is valid

- `codex exec` exists locally and supports non-interactive execution
- local machine is already authenticated through ChatGPT

#### Hard problem

- CLI process control is weaker than app-server control
- session continuity is weaker
- streaming and tool-event fidelity are weaker
- mapping Claude Code’s message contract onto process I/O is fragile

#### Assessment

This option is useful as a probe harness and fallback research tool.

It is not the best product architecture.

## 8. Validated Direct Route; Undocumented but Real

### Direct subscription adapter on top of `openai_base_url` + `chatgpt_base_url`

Definition:

- a local Anthropic-compatible gateway that reuses the same ChatGPT-managed auth pattern that Codex uses after ChatGPT login
- local model requests go to the direct `/responses` surface behind `openai_base_url`
- the currently verified remote target behind that surface is `https://chatgpt.com/backend-api/codex/responses`
- auxiliary subscription/account/product requests can go to `chatgpt_base_url` under `/backend-api/...` when needed

Validated architecture boundary:

- `Claude Code CLI -> local Anthropic-compatible gateway -> upstream /responses`
- optional sidecar calls from the gateway to `/backend-api/...` for account/rate-limit/product state

Validated reason:

- local probe proved that `codex exec` under ChatGPT login sends the main inference traffic to `/responses`
- local probe proved that those `/responses` requests carry `Authorization: Bearer ...` and `chatgpt-account-id`
- local probe also proved that ChatGPT/backend product traffic is split out to `/backend-api/...`
- proxy-probe capture proved the default remote host is `chatgpt.com`, and the direct responses endpoint is `https://chatgpt.com/backend-api/codex/responses`
- forwarding the same request to the public `https://api.openai.com/v1/responses` path fails with `401 Unauthorized` and `Missing scopes: api.responses.write`

Why it still matters as a design target:

- it would remove the “agent-on-agent” mismatch introduced by `app-server`
- it places the adapter at the correct abstraction boundary: Anthropic Messages on one side, model-like `/responses` on the other
- it matches the user-facing requirement more directly than translating Claude turns into Codex agent turns

Hard problem:

- no official public docs define the stability contract for this subscription-backed `/responses` path
- source and runtime now prove websocket-first behavior with HTTP fallback, and the current `codex exec --json` text path succeeds over HTTP SSE after websocket `404`; wider path coverage is still unverified
- request bodies are sent with `content-encoding: zstd`; one real sample has now been decompressed, but stability across turns and tool paths is still unverified
- the remote endpoint is not the public Responses API write surface; a direct public-API forward with the captured ChatGPT auth material is rejected by scope checks

Assessment:

- this is no longer an unverified idea
- this is the cleanest architecture under the two hard user constraints
- this is not a public contract; treat it as a source-backed, runtime-backed integration target with version-tracking risk

## 9. Decision

### Verified decision

If the project must stay inside public, documented, repeatable surfaces, build:

- `Claude Code CLI -> local Anthropic-compatible gateway -> codex app-server`

If the project must optimize for the cleanest architecture under the user’s hard constraints, build:

- `Claude Code CLI -> local Anthropic-compatible gateway -> upstream /responses with ChatGPT-managed bearer + chatgpt-account-id`

This second route is now validated as a real surface, but not as a public contract.

### Verified non-decision

Do not build the first version on:

- OpenAI public API billing
- LiteLLM as a billing solution
- Codex MCP Server as the main backend
- undocumented upstream assumptions presented as if they were confirmed

## 10. Next Validation Tasks

The next round of work should produce implementation-grade evidence for the direct adapter:

1. Extend the current tested apps coverage from the current non-interactive GitHub sample and the current interactive GitHub sample to other app families and other interactive business actions.
2. Extend the current four-sample `/responses` request comparison to more apps tool-roundtrip requests and other higher-risk paths.
3. Extend current error-surface coverage from the current interactive GitHub sample to other interactive app families and other untested entrances.
4. Expand tool-layer work from family-level acceptance to higher-risk concrete tool instances and business semantics.

The app-server bridge remains the documented fallback. The direct adapter is now the architecture target. It now has a verified local success contract, a verified real upstream success capture, a verified required-field reduction for the current text path, verified HTTP-only coverage across current non-interactive resume paths, current non-interactive `features.apps=true` `exec/exec resume` text paths, the current interactive `features.apps=true` first-turn plus same-session second-turn and third-turn text paths, and one interactive GitHub app business action, a validated error-compatibility matrix for the current Claude and Codex CLI paths plus direct interactive `/responses` `400 / 500 / malformed-sse / truncated-sse` evidence for the current `features.apps=true` first-turn and same-session second-turn text paths, direct default `claude` tool-use `400 / 500 / malformed-sse / truncated-sse` evidence on the Anthropic edge, and direct sidecar `404 / 500` evidence for one interactive GitHub app tool round, a four-sample decoded request-body comparison for current first-turn paths, a verified answer that the currently observed `/backend-api` sidecar requests are not hard dependencies for the current non-interactive main path, the current non-interactive `features.apps=true` text resume path, or the current interactive `features.apps=true` first-turn plus same-session second-turn and third-turn text paths, and a verified split result that one real GitHub app business action still hard-depends on sidecar even though the paired `/responses` path stays healthy; it still needs more app families and higher-risk tool-instance coverage before it becomes implementation-ready.

## 11. Source Index

- Anthropic Claude Code gateway docs: <https://code.claude.com/docs/en/llm-gateway>
- Anthropic Messages count_tokens docs: <https://platform.claude.com/docs/en/api/messages/count_tokens>
- Anthropic Claude Code model config docs: <https://code.claude.com/docs/en/model-config>
- OpenAI Codex CLI docs: <https://developers.openai.com/codex/cli>
- OpenAI GPT-5-Codex model docs: <https://developers.openai.com/api/docs/models/gpt-5-codex>
- OpenAI Codex app-server README: <https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md>
- OpenAI Codex login source: <https://github.com/openai/codex/blob/main/codex-rs/cli/src/login.rs>
- OpenAI Codex MCP interface docs: <https://github.com/openai/codex/blob/main/codex-rs/docs/codex_mcp_interface.md>

## Appendix A. Local Command Artifacts

### A.1 Local versions

```text
$ claude --version
2.1.114 (Claude Code)

$ codex --version
codex-cli 0.121.0
```

### A.2 Local subscription auth state

```text
$ codex login status
Logged in using ChatGPT
```

### A.3 Local server surfaces

```text
$ codex app-server --help
[experimental] Run the app server or related tooling

$ codex mcp-server --help
Start Codex as an MCP server (stdio)

$ codex exec --help
Run Codex non-interactively
```

### A.4 Claude runtime probe

Probe result excerpt:

```text
PATH /v1/messages?beta=true
HEADERS ... "anthropic-beta": "...", "anthropic-version": "2023-06-01", "X-Claude-Code-Session-Id": "...", "x-api-key": "test-token" ...
BODY {"model":"claude-sonnet-4-6", ... "tools":[...], ... "stream":true}
```

### A.5 Official-doc zero-result searches

These searches were run against `developers.openai.com/docs` and returned no results:

```text
site:developers.openai.com/docs "ChatGPT account" "Responses API"
site:developers.openai.com/docs "ChatGPT Plus" "API key" "Responses API"
site:developers.openai.com/docs "subscription" "API key" "ChatGPT" "Responses API"
```

### A.6 Direct Codex subscription probe

Probe configuration:

```text
$ codex exec --skip-git-repo-check \
    -c 'features.apps=false' \
    -c 'chatgpt_base_url="http://127.0.0.1:8767/backend-api"' \
    -c 'openai_base_url="http://127.0.0.1:8767"' \
    --json 'reply with one short word'
```

Observed local probe log excerpt:

```text
{"method":"GET","path":"/backend-api/plugins/list","has_authorization":true,"authorization_prefix":"Bearer","has_chatgpt_account_id":true}
{"method":"GET","path":"/responses","has_authorization":true,"authorization_prefix":"Bearer","has_chatgpt_account_id":true}
{"method":"POST","path":"/responses","has_authorization":true,"authorization_prefix":"Bearer","has_chatgpt_account_id":true,"accept":"text/event-stream","content_type":"application/json","content_encoding":"zstd"}
```

Observed Codex failure when `openai_base_url` was redirected to the probe:

```text
failed to connect to websocket: ... url: ws://127.0.0.1:8767/responses
unexpected status 404 Not Found: {"error": "not found", "path": "/responses"}, url: http://127.0.0.1:8767/responses
```

### A.7 Local success probe for HTTP fallback and zstd body capture

Probe configuration:

```text
$ codex exec --skip-git-repo-check \
    -c 'features.apps=false' \
    -c 'chatgpt_base_url="http://127.0.0.1:8769/backend-api"' \
    -c 'openai_base_url="http://127.0.0.1:8769"' \
    --json 'reply with one short word'
```

Observed local probe log excerpt:

```text
{"n":11,"method":"POST","path":"/responses","headers":{"authorization":"present","chatgpt-account-id":"present","accept":"text/event-stream","content-type":"application/json","content-encoding":"zstd"},"body_len":44664}
```

Observed `codex exec` completion after repeated websocket `404`:

```text
failed to connect to websocket: ... url: ws://127.0.0.1:8769/responses
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Okay"}}
{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}
```

Minimal SSE event order returned by the probe and accepted by `codex exec`:

```text
response.created
response.in_progress
response.output_item.added
response.content_part.added
response.output_text.delta
response.output_text.done
response.content_part.done
response.output_item.done
response.completed
```

Decoded request-body skeleton from `/tmp/codex-responses-body.zst`:

```text
top_level_keys:
  model
  instructions
  input
  tools
  tool_choice
  parallel_tool_calls
  reasoning
  store
  stream
  include
  service_tier
  prompt_cache_key
  text
  client_metadata
model: gpt-5.4
stream: true
store: false
input_len: 3
tools_len: 16
tool_choice: auto
parallel_tool_calls: true
reasoning: {"effort":"xhigh"}
include: ["reasoning.encrypted_content"]
```

### A.8 Forwarding the captured request to the public Responses API fails

Forwarding setup:

```text
openai_base_url -> local proxy -> https://api.openai.com/v1/responses
```

Observed upstream error body:

```text
{
  "error": {
    "message": "You have insufficient permissions for this operation. Missing scopes: api.responses.write. ...",
    "type": "invalid_request_error",
    "param": null,
    "code": null
  }
}
```

Observed `codex exec` failure:

```text
turn.failed
unexpected status 401 Unauthorized: ... Missing scopes: api.responses.write ...
```

### A.9 Default remote host probe under ChatGPT login

Probe configuration:

```text
$ env HTTPS_PROXY=http://127.0.0.1:8772 HTTP_PROXY=http://127.0.0.1:8772 ALL_PROXY=http://127.0.0.1:8772 \
    codex exec --skip-git-repo-check -c 'features.apps=false' --json 'reply with one short word'
```

Observed proxy log excerpt:

```text
CONNECT chatgpt.com:443
```

Observed Codex error excerpt:

```text
failed to connect to websocket: ... url: wss://chatgpt.com/backend-api/codex/responses
stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses)
```

### A.10 Real upstream success capture from ChatGPT backend

Forwarding setup:

```text
openai_base_url -> local proxy -> https://chatgpt.com/backend-api/codex/responses
```

Observed proxy metadata:

```text
{"method":"POST","path":"/responses","request_headers":{"accept":"text/event-stream","content-type":"application/json","content-encoding":"zstd","has_authorization":true,"has_chatgpt_account_id":true},"request_body_len":44665}
{"upstream_status":200,"upstream_transfer_encoding":"chunked"}
```

Observed `codex exec` success:

```text
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Yes"}}
{"type":"turn.completed","usage":{"input_tokens":29748,"cached_input_tokens":6528,"output_tokens":129}}
```

Observed real SSE event sequence:

```text
response.created
response.in_progress
response.output_item.added      # reasoning
response.output_item.done       # reasoning
response.output_item.added      # assistant message
response.content_part.added
response.output_text.delta
response.output_text.done
response.content_part.done
response.output_item.done       # assistant message
response.completed
```

### A.11 Required-field reduction from the real upstream sample

Batch replay matrix:

```text
baseline                      turn.completed
drop_sequence_number          turn.completed
drop_reasoning_item           turn.completed
drop_annotations              turn.completed
drop_annotations_logprobs     turn.completed
drop_obfuscation              turn.completed
drop_response_extras          turn.completed
drop_all_optional             turn.completed
drop_reasoning_and_optional   turn.completed
```

Strict minimal replay derived from the real sample:

```text
response.created
  response: {id, object, created_at, status, model, output}
response.in_progress
  response: {id, object, created_at, status, model, output}
response.output_item.added
  item: {id, type, status, role, content}
response.content_part.added
  part: {type, text}
response.output_text.delta
  {item_id, output_index, content_index, delta}
response.output_text.done
  {item_id, output_index, content_index, text}
response.content_part.done
  part: {type, text}
response.output_item.done
  item: {id, type, status, role, content[{type,text}]}
response.completed
  response: {id, object, created_at, status, model, output, usage{input_tokens,output_tokens,total_tokens}}
```

Observed strict-minimal success:

```text
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Yes"}}
{"type":"turn.completed","usage":{"input_tokens":29748,"cached_input_tokens":0,"output_tokens":129}}
```

### A.12 Claude tool inventory and current `/responses` tool inventory

Observed `claude` capture:

```text
tools_len: 4
Bash
Edit
Read
advisor (type advisor_20260301)
```

Observed `claude` capture:

```text
tools_len: 56
type counts: function=55, advisor_20260301=1
sample names:
Agent
AskUserQuestion
Bash
Edit
Glob
Grep
Read
TodoWrite
WebFetch
WebSearch
Write
...
```

Observed current `/responses` tool inventory:

```text
tools_len: 16
type counts: function=13, custom=1, web_search=1, namespace=1
sample names:
exec_command
write_stdin
list_mcp_resources
apply_patch
view_image
spawn_agent
...
```

Observed set intersection:

```text
intersection []
claude_only_count 56
responses_only_count 15
```

### A.13 Declaration-level acceptance of converted Claude function tools

Accepted bare tool subset:

```text
converted tools: 3
source: claude
result:
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Done"}}
{"type":"turn.completed","usage":{"input_tokens":20203,"cached_input_tokens":0,"output_tokens":143}}
```

Accepted default Claude tool inventory:

```text
converted tools: 55
source: claude
result:
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Yes"}}
{"type":"turn.completed","usage":{"input_tokens":46352,"cached_input_tokens":0,"output_tokens":98}}
```

Conversion rule used in both cases:

```text
Anthropic function tool:
  {name, description, input_schema}

rewritten as Responses function tool:
  {type:"function", name, description, parameters: input_schema, strict:false}
```

### A.14 Bare `Bash` roundtrip using `function_call_output`

Official guide excerpt:

```text
input_messages.append({
    "type": "function_call_output",
    "call_id": tool_call.call_id,
    "output": str(result)
})
```

First upstream roundtrip state:

```text
first_status: 200
response_id: resp_0178fdfdbcbcc9510169e60abf6eb48197b36f00f7f6209121
call_id: call_etkICXh0kwyc7bm6ty3DGNsy
function_name: Bash
function_arguments: {"command":"true","description":"Run no-op command"}
```

Observed first-response tool events:

```text
response.output_item.added
  item.type = function_call
  item.name = Bash
response.function_call_arguments.done
  arguments = {"command":"true","description":"Run no-op command"}
response.output_item.done
  item.type = function_call
```

Second upstream request input shape:

```text
second_input_item_types:
- reasoning
- function_call
- function_call_output
tool_output: success
```

Observed second-response completion:

```text
response.output_text.done
  text = Called `Bash` once with a minimal valid no-op command: `true`.
response.output_item.done
  item.type = message
response.completed
```

Observed `codex exec` result:

```text
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Called `Bash` once with a minimal valid no-op command: `true`."}}
{"type":"turn.completed","usage":{"input_tokens":6780,"cached_input_tokens":0,"output_tokens":21}}
```

### A.15 Default 55-function-tool inventory with forced `Bash` roundtrip

First upstream roundtrip state:

```text
first_status: 200
response_id: resp_0481bd4b67fe06760169e60c01af1481939fab640f6a023273
call_id: call_WB8Dhdy1NWa7DHxOQmuIdsge
function_name: Bash
function_arguments: {"command":"true","description":"Run a no-op command"}
```

Second upstream request input shape:

```text
tool_count: 55
second_input_item_types:
- reasoning
- function_call
- function_call_output
tool_output: success
```

Observed second-response completion:

```text
response.output_text.done
  text = Ran a minimal Bash command successfully.
response.output_item.done
  item.type = message
response.completed
```

Observed `codex exec` result:

```text
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Ran a minimal Bash command successfully."}}
{"type":"turn.completed","usage":{"input_tokens":33090,"cached_input_tokens":0,"output_tokens":11}}
```

### A.16 Representative function-family roundtrips under the default 55-function-tool inventory

`WebSearch`:

```text
function_arguments: {"query":"AI"}
second_response_text: WebSearch was called with the minimal valid argument set: `query: "AI"`.
codex_result: turn.completed
```

`Agent`:

```text
function_arguments: {"description":"Minimal agent call","prompt":"No task beyond confirming this invocation. Reply briefly."}
second_response_text: Invocation completed.
codex_result: turn.completed
```

`Read`:

```text
function_arguments: {"file_path":"/etc/hosts"}
second_response_text: Called `Read` once with `file_path: /etc/hosts`.
codex_result: turn.completed
```

`Edit`:

```text
function_arguments: {"file_path":"/tmp/x","old_string":"a","new_string":"b"}
second_response_text: `Edit` was called with minimal arguments.
codex_result: turn.completed
```

`Write`:

```text
function_arguments: {"file_path":"/tmp/a","content":""}
second_response_text: ""
codex_result: turn.completed
```

`TodoWrite`:

```text
function_arguments: {"todos":[]}
second_response_text: Completed.
codex_result: turn.completed
```

`AskUserQuestion`:

```text
function_arguments: {"questions":[{"question":"Which option do you prefer?","header":"Choice","options":[{"label":"Option 1","description":"Select the first option."},{"label":"Option 2","description":"Select the second option."}],"multiSelect":false}],"metadata":{"source":"developer"}}
second_response_text: ""
codex_result: turn.completed
```

`mcp__claude_ai_Google_Drive__authenticate`:

```text
function_arguments: {}
second_response_text: Google Drive is already authenticated in this session. The Drive MCP tools should now be available.
codex_result: turn.completed
```

### A.17 Raw `advisor_20260301` passthrough rejection

Observed raw advisor object from the captured default Claude request:

```json
{
  "type": "advisor_20260301",
  "name": "advisor",
  "model": "claude-opus-4-7"
}
```

Observed state file from the passthrough probe:

```json
{
  "first_status": 400,
  "first_error_body_utf8": "{\"detail\":\"Unsupported tool type: advisor_20260301\"}"
}
```

Observed captured first upstream response body:

```text
{"detail":"Unsupported tool type: advisor_20260301"}
```

Observed `codex exec` terminal result:

```text
{"type":"error","message":"{\"detail\":\"Unsupported tool type: advisor_20260301\"}"}
{"type":"turn.failed","error":{"message":"{\"detail\":\"Unsupported tool type: advisor_20260301\"}"}}
```

### A.18 Official advisor contract plus local Claude acceptance

Official Advisor docs now state:

- request tool shape:
  - `{"type":"advisor_20260301","name":"advisor","model":"..."}`
- response content blocks:
  - `server_tool_use`
  - `advisor_tool_result`
- both happen inside one `/v1/messages` request
- later turns must include prior `advisor_tool_result` blocks

Local probe result with a loopback Anthropic mock:

```text
claude --session-id 22222222-2222-4222-8222-222222222222 ...
result: "Advisor consulted. Final answer from the first turn."
```

Observed resumed request body included:

```json
{
  "role": "assistant",
  "content": [
    {"type": "text", "text": "Let me consult the advisor first."},
    {"type": "server_tool_use", "id": "srvtoolu_probe_advisor_01", "name": "advisor", "input": {}},
    {"type": "advisor_tool_result", "tool_use_id": "srvtoolu_probe_advisor_01", "content": {"type": "advisor_result", "text": "Break the work into small verified steps."}},
    {"type": "text", "text": "Advisor consulted. Final answer from the first turn."}
  ]
}
```

### A.19 `/responses` synthetic advisor bridge success

Observed bridge state for `gpt-5.4 -> gpt-5.4`:

```json
{
  "first_status": 200,
  "function_name": "advisor",
  "function_arguments": "{}",
  "advisor_status": 200,
  "advisor_model": "gpt-5.4",
  "advisor_text": "Start by tightening the objective into a concrete success criterion...",
  "final_input_item_types": ["function_call", "function_call_output"]
}
```

Observed `codex exec` result:

```text
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"What do you need help with?"}}
{"type":"turn.completed", ...}
```

Observed bridge state for `gpt-5.3-codex -> gpt-5.4`:

```json
{
  "first_status": 200,
  "function_name": "advisor",
  "function_arguments": "{}",
  "advisor_status": 200,
  "advisor_model": "gpt-5.4",
  "advisor_text": "Clarify the exact success condition first...",
  "final_input_item_types": ["reasoning", "function_call", "function_call_output"]
}
```

Observed first upstream response header lines showed:

```text
event: response.created
data: {... "model":"gpt-5.3-codex", ... "tool_choice":{"type":"function","name":"advisor"} ...}
```

Observed `codex exec` result:

```text
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Advisor called, and the task is complete."}}
{"type":"turn.completed", ...}
```

### A.20 ChatGPT-subscription model probe results

Observed direct probe results against `https://chatgpt.com/backend-api/codex/responses` with ChatGPT auth:

```json
{"model":"gpt-5.4","status":200}
{"model":"gpt-5.4-mini","status":200}
{"model":"gpt-5.3-codex","status":200}
{"model":"gpt-5.2-codex","status":400,"error":"{\"detail\":\"The 'gpt-5.2-codex' model is not supported when using Codex with a ChatGPT account.\"}"}
{"model":"gpt-5.1-codex-max","status":400,"error":"{\"detail\":\"The 'gpt-5.1-codex-max' model is not supported when using Codex with a ChatGPT account.\"}"}
```

### A.21 HTTP-only resume coverage on current non-interactive CLI paths

Observed first resumed text session:

```text
turn 1 prompt: Reply exactly FIRST.
turn 1 result: FIRST
turn 2 prompt: Reply exactly SECOND.
turn 2 result: SECOND
```

Observed proxy-side request summary:

```text
008-request.json: previous_response_id = null, input_len = 3, last_input_text = Reply exactly FIRST.
016-request.json: previous_response_id = null, input_len = 6, last_input_text = Reply exactly SECOND.
```

Observed resumed native-tool session:

```text
turn 1 prompt: Reply exactly ALPHA.
turn 1 result: ALPHA
turn 2 prompt: Read /etc/hosts and reply with only the first token.
turn 2 result: ##
```

Observed proxy-side request summary:

```text
024-request.json: previous_response_id = null, input_len = 3, last_input_text = Reply exactly ALPHA.
032-request.json: previous_response_id = null, input_len = 6, last_input_text = Read /etc/hosts and reply with only the first token.
033-request.json: previous_response_id = null, input_len = 9, includes reasoning + function_call + function_call_output.
```

Observed resumed tool function call:

```json
{
  "type": "function_call",
  "name": "exec_command",
  "arguments": "{\"cmd\":\"awk 'NF{print $1; exit}' /etc/hosts\",\"yield_time_ms\":1000,\"max_output_tokens\":200}"
}
```

Observed final assistant message after the second HTTP POST:

```json
{
  "type": "message",
  "content": [
    {
      "type": "output_text",
      "text": "##"
    }
  ]
}
```

### A.22 Current error-compatibility matrix probes

Observed `/responses` probe results for `codex exec --json`:

```text
json-400:
  final terminal error: {"detail": "forced 400 from local /responses probe"}
  POST /responses count: 1

json-500:
  final terminal error: We're currently experiencing high demand, which may cause temporary errors.
  POST /responses count: 30

malformed-sse:
  final terminal error: stream disconnected before completion: stream closed before response.completed
  POST /responses count: 6

truncated-sse:
  final terminal error: stream disconnected before completion: stream closed before response.completed
  POST /responses count: 6
```

Observed `/v1/messages` probe results for `claude`:

```text
json-400:
  terminal error: API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"forced 400 from local /v1/messages probe"}}
  POST /v1/messages count: 2

json-500:
  15-second bounded sample produced no terminal error text before local alarm termination
  POST /v1/messages count within that sample: 10

malformed-sse:
  terminal stderr:
    Could not parse message into JSON: {not-json}
    From chunk: [ "event: content_block_delta", "data: {not-json}" ]
    undefined is not an object (evaluating '_.input_tokens')
  POST /v1/messages count: 4

truncated-sse:
  terminal stderr:
    undefined is not an object (evaluating '_.input_tokens')
  POST /v1/messages count: 4
```

### A.23 Current sidecar-dependency probes

Observed `404` sidecar-blocker run:

```text
chatgpt_base_url -> http://127.0.0.1:8796/backend-api
openai_base_url  -> http://127.0.0.1:8797
prompt           -> Reply exactly SIDECAR.
result           -> item.completed text "SIDECAR" + turn.completed
```

Observed sidecar requests during that run:

```text
GET  /backend-api/plugins/featured?platform=codex -> 404
GET  /backend-api/plugins/list -> 404
POST /backend-api/codex/analytics-events/events -> 404
```

Observed `500` sidecar-blocker run:

```text
chatgpt_base_url -> http://127.0.0.1:8798/backend-api
openai_base_url  -> http://127.0.0.1:8797
prompt           -> Reply exactly SIDECAR500.
result           -> item.completed text "SIDECAR500" + turn.completed
```

Observed sidecar requests during that run:

```text
GET  /backend-api/plugins/list -> 500
GET  /backend-api/plugins/featured?platform=codex -> 500
POST /backend-api/codex/analytics-events/events -> 500
```

### A.24 Current `count_tokens` observation probes

Observed `claude` run:

```text
probe           -> http://127.0.0.1:8799
prompt          -> reply with exactly BARE_CT_OK
observed calls  -> 2 x POST /v1/messages
count_tokens    -> 0 x POST /v1/messages/count_tokens
shape           -> haiku title request + sonnet main request
```

Observed default `claude` run:

```text
probe           -> http://127.0.0.1:8800
prompt          -> reply with exactly DEFAULT_CT_OK
observed calls  -> 1 x POST /v1/messages
count_tokens    -> 0 x POST /v1/messages/count_tokens
shape           -> single sonnet request with 56 tools
```

Observed `claude` + `-r` resume run:

```text
probe           -> http://127.0.0.1:8801
first prompt    -> reply with exactly RESUME_CT_OK
resume prompt   -> reply with exactly RESUME2_CT_OK
observed calls  -> 3 x POST /v1/messages
count_tokens    -> 0 x POST /v1/messages/count_tokens
shape           -> first run: haiku title + sonnet main; resumed run: 1 sonnet request with 3 messages
```

Observed interactive `claude --bare` run:

```text
probe           -> http://127.0.0.1:8802
prompt          -> reply with exactly INTERACTIVE_CT_OK
observed calls  -> 2 x POST /v1/messages
count_tokens    -> 0 x POST /v1/messages/count_tokens
shape           -> haiku title request + sonnet main request
```

### A.25 Current interactive `features.apps=true` coverage probes

Observed HTTP-only interactive run:

```text
openai_base_url  -> http://127.0.0.1:8806
mode             -> codex --no-alt-screen -c 'features.apps=true'
prompt           -> Reply exactly APPSHTTP.
ws               -> repeated GET /responses -> 404
http             -> POST /responses -> 200
result           -> terminal output APPSHTTP
```

Observed interactive sidecar `404` run:

```text
chatgpt_base_url -> http://127.0.0.1:8808/backend-api
openai_base_url  -> http://127.0.0.1:8807
mode             -> codex --no-alt-screen -c 'features.apps=true'
prompt           -> Reply exactly APPS404.
sidecar          -> /plugins/featured, /plugins/list, /wham/apps, /connectors/directory/list, /wham/usage, /codex/analytics-events/events -> 404
http             -> POST /responses -> 200
result           -> terminal output APPS404
```

Observed interactive sidecar `500` run:

```text
chatgpt_base_url -> http://127.0.0.1:8810/backend-api
openai_base_url  -> http://127.0.0.1:8809
mode             -> codex --no-alt-screen -c 'features.apps=true'
prompt           -> Reply exactly APPS500.
sidecar          -> /plugins/list, /plugins/featured, /wham/apps, /connectors/directory/list, /codex/analytics-events/events -> 500
terminal warning -> MCP client for `codex_apps` failed to start
terminal warning -> MCP startup incomplete (failed: codex_apps)
http             -> POST /responses -> 200
result           -> terminal output APPS500
```

Observed default interactive `claude` run:

```text
probe           -> http://127.0.0.1:8803
cli version     -> 2.1.116 (Claude Code)
prompt          -> reply with exactly DEFAULT_INTERACTIVE_CT_OK
observed calls  -> 2 x POST /v1/messages
count_tokens    -> 0 x POST /v1/messages/count_tokens
shape           -> haiku title request + sonnet main request with 33 tools
```

Observed `claude --continue` run:

```text
probe           -> http://127.0.0.1:8804
seed prompt     -> reply with exactly CONTINUE_SEED_OK
continue prompt -> reply with exactly CONTINUE2_OK
observed calls  -> 2 x POST /v1/messages
count_tokens    -> 0 x POST /v1/messages/count_tokens
shape           -> first run: 1 sonnet request; continue run: 1 sonnet request with 3 messages
```

Observed default `claude` tool roundtrip:

```text
probe           -> http://127.0.0.1:8805
prompt          -> reply with exactly TOOL_ROUND_OK after any required tool use
observed calls  -> 2 x POST /v1/messages
count_tokens    -> 0 x POST /v1/messages/count_tokens
shape           -> first run returned Read tool_use; second request carried final user content type tool_result
```

Observed `claude` run:

```text
probe            -> http://127.0.0.1:8896
invalid command  -> claude
invalid result   -> Error: legacy non-interactive probe required verbose mode
valid command    -> claude
observed calls   -> 1 x POST /v1/messages
count_tokens     -> 0 x POST /v1/messages/count_tokens
shape            -> /v1/messages?beta=true; response completed successfully
```

### A.26 Current interactive `features.apps=true` `/responses` 400 and 500 probes

Observed interactive `400` run:

```text
openai_base_url -> http://127.0.0.1:8821
mode            -> codex --no-alt-screen -c 'features.apps=true'
prompt          -> Reply exactly ERR400.
ws              -> repeated GET /responses -> 404
http            -> POST /responses = 1
server body     -> {"detail":"forced 400 from local /responses probe"}
transcript      -> ■{"detail":"forced400fromlocal/responsesprobe"}
```

Observed interactive `500` run:

```text
openai_base_url -> http://127.0.0.1:8822
mode            -> codex --no-alt-screen -c 'features.apps=true'
prompt          -> Reply exactly ERR500.
ws              -> repeated GET /responses -> 404
http            -> POST /responses = 30
server body     -> {"detail":"forced 500 from local /responses probe"}
transcript      -> ■We'recurrentlyexperiencinghighdemand,whichmaycausetemporaryerrors.
```

### A.27 Current four-sample `/responses` request comparison

Observed decoded request samples:

```text
/tmp/responses-forward-8797/008-request.json
/tmp/responses-forward-8797/016-request.json
/tmp/codex-apps-http-only-8806/008-request.json
/tmp/codex-interactive-errors-8821/008-request.json
```

Shared top-level keys:

```text
client_metadata
include
input
instructions
model
parallel_tool_calls
prompt_cache_key
reasoning
service_tier
store
stream
text
tool_choice
tools
```

Shared values:

```text
model                -> gpt-5.4
stream               -> true
store                -> false
tool_choice          -> auto
parallel_tool_calls  -> true
include              -> ["reasoning.encrypted_content"]
service_tier         -> priority
prompt_cache_key     -> string
input_len            -> 3
```

Current verified tool-inventory difference:

```text
non-interactive tools_len -> 16
interactive apps tools_len -> 21
non-interactive namespace -> mcp__pencil__
interactive apps namespaces -> mcp__codex_apps__adobe_photoshop, mcp__codex_apps__figma, mcp__codex_apps__github, mcp__codex_apps__gmail, mcp__codex_apps__notion__legacy, mcp__pencil__
```

### A.28 Current non-interactive `features.apps=true` `exec/exec resume` HTTP-only probes

Observed first turn:

```text
openai_base_url -> http://127.0.0.1:8823
mode            -> codex exec --json --enable apps
prompt          -> Reply exactly APPSRESUME1.
ws              -> repeated GET /responses -> 404
http            -> POST /responses -> 200
result          -> item.completed APPSRESUME1
```

Observed resumed turn:

```text
openai_base_url -> http://127.0.0.1:8823
mode            -> codex exec resume --json --enable apps
prompt          -> Reply exactly APPSRESUME2.
ws              -> repeated GET /responses -> 404
http            -> POST /responses -> 200
result          -> item.completed APPSRESUME2
```

Observed paired forward-log summary:

```text
POST_COUNT      -> 2
request 1       -> input_len 3, tools_len 21
request 2       -> input_len 6, tools_len 21
type_counts     -> {'function': 13, 'custom': 1, 'web_search': 1, 'namespace': 6}
namespaces      -> mcp__codex_apps__adobe_photoshop, mcp__codex_apps__figma, mcp__codex_apps__github, mcp__codex_apps__gmail, mcp__codex_apps__notion__legacy, mcp__pencil__
```

### A.29 Current non-interactive `features.apps=true` sidecar `404` and `500` probes

Observed sidecar `404` run:

```text
chatgpt_base_url -> http://127.0.0.1:8825/backend-api
openai_base_url  -> http://127.0.0.1:8824
mode             -> codex exec/exec resume --json --enable apps
first result     -> APPSSIDE404A
resume result    -> APPSSIDE404B
responses posts  -> 2
sidecar paths    -> /backend-api/codex/analytics-events/events, /backend-api/connectors/directory/list?tier=categorized&external_logos=true, /backend-api/plugins/featured?platform=codex, /backend-api/plugins/list, /backend-api/wham/apps
stderr           -> rmcp::transport::worker ... data did not match any variant of untagged enum JsonRpcMessage ...
```

Observed sidecar `500` run:

```text
chatgpt_base_url -> http://127.0.0.1:8827/backend-api
openai_base_url  -> http://127.0.0.1:8826
mode             -> codex exec/exec resume --json --enable apps
first result     -> APPSSIDE500A
resume result    -> APPSSIDE500B
responses posts  -> 2
sidecar paths    -> /backend-api/codex/analytics-events/events, /backend-api/connectors/directory/list?tier=categorized&external_logos=true, /backend-api/plugins/featured?platform=codex, /backend-api/plugins/list, /backend-api/wham/apps
stderr           -> rmcp::transport::worker ... data did not match any variant of untagged enum JsonRpcMessage ...
```

### A.30 Current interactive `features.apps=true` malformed-SSE probe

Observed malformed-SSE run:

```text
openai_base_url -> http://127.0.0.1:8832
mode            -> codex --no-alt-screen --enable apps
prompt          -> Reply exactly IERRMAL.
ws              -> repeated GET /responses -> 404
http            -> POST /responses = 6
last kind       -> malformed-sse
expect tail     -> ■ stream disconnected before completion: stream closed before response.completed
```

### A.31 Current interactive `features.apps=true` truncated-SSE probe

Observed truncated-SSE run:

```text
openai_base_url -> http://127.0.0.1:8833
mode            -> codex --no-alt-screen --enable apps
prompt          -> Reply exactly IERRTRUNC.
ws              -> repeated GET /responses -> 404
http            -> POST /responses = 6
last kind       -> truncated-sse
expect tail     -> ■ stream disconnected before completion: stream closed before response.completed
```

### A.32 Current interactive `features.apps=true` same-session second-turn HTTP-only and sidecar probes

Observed HTTP-only run:

```text
openai_base_url -> http://127.0.0.1:8850
mode            -> codex --no-alt-screen --enable apps
turn 1 result   -> APPDEEP1
turn 2 result   -> APPDEEP2
forward log     -> GET /responses = 7, POST /responses = 2, 200 responses = 2
```

Observed sidecar `404` run:

```text
chatgpt_base_url -> http://127.0.0.1:8852/backend-api
openai_base_url  -> http://127.0.0.1:8851
mode             -> codex --no-alt-screen --enable apps
turn 1 result    -> APPDEEP4041
turn 2 result    -> APPDEEP4042
forward log      -> GET /responses = 7, POST /responses = 2, 200 responses = 2
sidecar paths    -> /backend-api/codex/analytics-events/events, /backend-api/connectors/directory/list?tier=categorized&external_logos=true, /backend-api/plugins/featured?platform=codex, /backend-api/plugins/list, /backend-api/wham/apps, /backend-api/wham/usage
```

Observed sidecar `500` run:

```text
chatgpt_base_url -> http://127.0.0.1:8854/backend-api
openai_base_url  -> http://127.0.0.1:8853
mode             -> codex --no-alt-screen --enable apps
turn 1 result    -> APPDEEP5001
turn 2 result    -> APPDEEP5002
forward log      -> GET /responses = 7, POST /responses = 2, 200 responses = 2
warning          -> MCP client for `codex_apps` failed to start
warning          -> MCP startup incomplete (failed: codex_apps)
sidecar paths    -> /backend-api/codex/analytics-events/events, /backend-api/connectors/directory/list?tier=categorized&external_logos=true, /backend-api/plugins/featured?platform=codex, /backend-api/plugins/list, /backend-api/wham/apps, /backend-api/wham/usage
```

### A.33 Current interactive `features.apps=true` same-session second-turn error probes

Observed `400` run:

```text
openai_base_url -> http://127.0.0.1:8860
mode            -> codex --no-alt-screen --enable apps
turn 1 result   -> APPERR400A
turn 2 output   -> {"detail": "forced 400 from local /responses proxy"}
responses log   -> POST 1 = 200, POST 2 = 400 json-error
```

Observed `500` run:

```text
openai_base_url -> http://127.0.0.1:8861
mode            -> codex --no-alt-screen --enable apps
turn 1 result   -> APPERR500A
turn 2 result   -> APPERR500B
responses log   -> POST 1 = 200, POST 2 = 500 json-error, POST 3 = 200
```

Observed `malformed-sse` run:

```text
openai_base_url -> http://127.0.0.1:8862
mode            -> codex --no-alt-screen --enable apps
turn 1 result   -> APPERRMALA
turn 2 output   -> Reconnecting...; Stream disconnected before completion: stream closed before response.completed; APPERRMALB
responses log   -> POST 1 = 200, POST 2 = malformed-sse, POST 3 = 200
```

Observed `truncated-sse` run:

```text
openai_base_url -> http://127.0.0.1:8863
mode            -> codex --no-alt-screen --enable apps
turn 1 result   -> APPERRTRUNCA
turn 2 output   -> Reconnecting...; Stream disconnected before completion: stream closed before response.completed; APPERRTRUNCB
responses log   -> POST 1 = 200, POST 2 = truncated-sse, POST 3 = 200
```

### A.34 Current non-interactive GitHub app business-action control and sidecar probes

Observed direct normal run:

```text
mode            -> codex exec --json --enable apps
prompt          -> Use the GitHub app to tell me the authenticated GitHub login. Output only the login.
tool            -> github_get_user_login
tool result     -> {"login":"n0rvyn","id":99057954}
final output    -> n0rvyn
```

Observed forward-only control run:

```text
openai_base_url -> http://127.0.0.1:8874
mode            -> codex exec --json --enable apps
tool            -> github_get_user_login
tool result     -> {"login":"n0rvyn","id":99057954}
final output    -> n0rvyn
forward log     -> GET /responses = 7, POST /responses = 2, 200 responses = 2
request 008     -> input_len = 3, tools_len = 21, last_input_type = message
request 009     -> input_len = 7, tools_len = 21, last_input_type = function_call_output
```

Observed sidecar `404` run:

```text
chatgpt_base_url -> http://127.0.0.1:8871/backend-api
openai_base_url  -> http://127.0.0.1:8870
mode             -> codex exec --json --enable apps
tool             -> github_get_user_login
tool error       -> failed to get client
stderr           -> MCP startup failed: handshaking with MCP server failed
stderr           -> error decoding response body
retry tool       -> github_get_profile
final output     -> GitHub app error: unable to retrieve authenticated login.
forward log      -> GET /responses = 7, POST /responses = 3, 200 responses = 3
request 008      -> input_len = 3, last_input_type = message
request 009      -> input_len = 7, last_input_type = function_call_output
request 010      -> input_len = 11, last_input_type = function_call_output
sidecar paths    -> /backend-api/connectors/directory/list?tier=categorized&external_logos=true, /backend-api/plugins/featured?platform=codex, /backend-api/plugins/list, /backend-api/codex/analytics-events/events, /backend-api/wham/apps
```

### A.35 Current interactive `features.apps=true` third-turn and GitHub app-action probes

Observed forward-only same-session run:

```text
openai_base_url -> http://127.0.0.1:8881
mode            -> codex --no-alt-screen --enable apps
turn 1 result   -> APPROUND3A
turn 2 result   -> APPROUND3B
turn 3 result   -> APPROUND3C
turn 4 tool     -> codex_apps.github_get_profile
turn 4 result   -> 99057954
forward log     -> GET /responses = 7, POST /responses = 5, 200 responses = 5
```

Observed interactive sidecar `404` run:

```text
chatgpt_base_url -> http://127.0.0.1:8883/backend-api
openai_base_url  -> http://127.0.0.1:8882
mode             -> codex --no-alt-screen --enable apps
startup warning  -> MCP client for `codex_apps` failed to start
startup warning  -> MCP startup incomplete (failed: codex_apps)
tool             -> github_get_profile
tool error       -> failed to get client
stderr           -> MCP startup failed: handshaking with MCP server failed
stderr           -> error decoding response body
forward log      -> GET /responses = 7, POST /responses = 1
blocker mode     -> 404
```

Observed interactive sidecar `500` run:

```text
chatgpt_base_url -> http://127.0.0.1:8885/backend-api
openai_base_url  -> http://127.0.0.1:8884
mode             -> codex --no-alt-screen --enable apps
startup warning  -> MCP client for `codex_apps` failed to start
startup warning  -> MCP startup incomplete (failed: codex_apps)
tool             -> github_get_profile
tool error       -> failed to get client
stderr           -> MCP startup failed: handshaking with MCP server failed
stderr           -> error decoding response body
forward log      -> GET /responses = 7, POST /responses = 1
blocker mode     -> 500
```

### A.36 Current non-interactive Gmail app business-action probes

Observed forward-only control run:

```text
openai_base_url -> http://127.0.0.1:8890
mode            -> codex exec --json --enable apps
tool            -> gmail_get_profile
tool result     -> {"email":"norvynzhang@gmail.com","id":"101031995657594086611","name":"Norvyn Zhang"}
final output    -> norvynzhang@gmail.com
forward log     -> GET /responses = 7, POST /responses = 2, 200 responses = 2
```

Observed sidecar `404` run:

```text
chatgpt_base_url -> http://127.0.0.1:8887/backend-api
openai_base_url  -> http://127.0.0.1:8886
mode             -> codex exec --json --enable apps
tool             -> gmail_get_profile
tool error       -> failed to get client
retry tool       -> gmail_get_profile
probe tool       -> gmail_list_labels
probe tool error -> failed to get client
final output     -> Gmail connector unavailable
forward log      -> GET /responses = 7, POST /responses = 5, 200 responses = 5
blocker mode     -> 404
```

Observed sidecar `500` run:

```text
chatgpt_base_url -> http://127.0.0.1:8892/backend-api
openai_base_url  -> http://127.0.0.1:8891
mode             -> codex exec --json --enable apps
tool             -> gmail_get_profile
tool error       -> failed to get client
retry tool       -> gmail_get_profile
fallback         -> ls/find ~/.codex
fallback         -> rg gmail-related config
fallback         -> read ~/.codex/auth.json
fallback         -> read state_5.sqlite
fallback         -> read logs_2.sqlite
forward log      -> GET /responses = 7, POST /responses = 6, 200 responses = 6
blocker mode     -> 500
```

### A.37 Current non-interactive Notion app business-action probes

Observed forward-only control run:

```text
openai_base_url -> http://127.0.0.1:8893
mode            -> codex exec --json --enable apps
tool            -> notion (legacy)_search
first args      -> {"query":"Norvyn Zhang","query_type":"users"}
first result    -> schema validation error; expected internal|user
retry args      -> {"query":"Norvyn Zhang","query_type":"user"}
retry result    -> <user ... name="Norvyn Zhang" email="norvynzhang@gmail.com"/>
final output    -> Norvyn Zhang
forward log     -> GET /responses = 14, POST /responses = 6, 200 responses = 6
```

Observed sidecar `404` run:

```text
chatgpt_base_url -> http://127.0.0.1:8894/backend-api
openai_base_url  -> http://127.0.0.1:8893
mode             -> codex exec --json --enable apps
tool             -> notion (legacy)_search
first args       -> {"query":"Norvyn Zhang","query_type":"users"}
retry args       -> {"query":"Norvyn Zhang","query_type":"user"}
tool error       -> failed to get client
final output     -> ⚠️ 无法验证: Notion app MCP 启动握手失败；`query_type=users` 与 `query_type=user` 两次请求都未成功执行。
forward delta    -> GET /responses = 7, POST /responses = 4, 200 responses = 4
blocker mode     -> 404
```

Observed sidecar `500` run:

```text
chatgpt_base_url -> http://127.0.0.1:8895/backend-api
openai_base_url  -> http://127.0.0.1:8893
mode             -> codex exec --json --enable apps
tool             -> notion (legacy)_search
first args       -> {"query":"Norvyn Zhang","query_type":"users"}
retry args       -> {"query":"Norvyn Zhang","query_type":"users"}
fallback args    -> {"query":"Norvyn Zhang","query_type":"user"}
tool error       -> failed to get client
final output     -> ⚠️ 无法验证：Notion app 在 `query_type=users` 和 `query_type=user` 两次调用中都在 MCP 握手阶段失败，未进入查询。
forward delta    -> GET /responses = 7, POST /responses = 5, 200 responses = 5
blocker mode     -> 500
```

### A.38 Current `count_tokens` probe

Observed `claude` run:

```text
probe            -> http://127.0.0.1:8896
invalid command  -> claude
invalid result   -> Error: legacy non-interactive probe required verbose mode
valid command    -> claude
observed calls   -> 1 x POST /v1/messages
count_tokens     -> 0 x POST /v1/messages/count_tokens
shape            -> /v1/messages?beta=true; response completed successfully
```

### A.39 Current high-risk concrete `mcp__...` tool roundtrip probe

Observed `mcp__plugin_Notion_notion__authenticate` run:

```text
probe            -> http://127.0.0.1:8897
forced tool      -> mcp__plugin_Notion_notion__authenticate
first_status     -> 200
function_name    -> mcp__plugin_Notion_notion__authenticate
function_args    -> {}
second input     -> reasoning + function_call + function_call_output
second count     -> 3
final output     -> Notion authentication flow started. Open the authorization URL shown by the tool result in your client, complete the login, then send me the callback URL from your browser address bar so I can finish setup.
result           -> turn.completed
```
