# 错误兼容矩阵 v1

Date: 2026-04-20

## 1. 文档定位

本文件只记录当前版本、当前路径下已经验证过的错误外观。

这里不写“应该怎么处理”，只写：

- 本地探针返回了什么
- CLI 终端实际看到了什么
- 当前样本发生了多少次重试或重放

## 2. 当前适用范围

本页所有结论只适用于以下范围：

- `codex-cli 0.121.0`
- `claude 2.1.114`
- 本地 loopback probe
- `codex exec --json`
- `claude --bare -p`
- 交互 TTY `codex --no-alt-screen` 的当前首轮文本路径
- 交互 TTY `codex --no-alt-screen --enable apps` 的当前 GitHub app 工具回合 sidecar 故障路径
- `features.apps=true` 的当前首轮与同会话第二轮文本路径

本页不外推到：

- Claude 交互会话
- Claude 默认 `-p` 工具路径
- 交互 TUI 的第三轮及以上回合
- 交互 `features.apps=true` 的 apps 工具回合
- 其他未验证 CLI 入口

## 3. `/responses` -> `codex exec` 错误矩阵

固定测试条件：

- `openai_base_url=http://127.0.0.1:<probe-port>`
- `features.apps=false`
- probe 固定让 `GET /responses` 返回 `404`
- CLI 提示词固定为 `reply with one short word`

| Probe mode | 服务器返回 | 当前终端外观 | 当前样本重放次数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `json-400` | `400 application/json`；body = `{"detail":"forced 400 from local /responses probe"}` | 在 5 次 websocket reconnect 提示后，终端输出 `{"type":"error","message":"{\"detail\": \"forced 400 from local /responses probe\"}"}`，随后 `turn.failed` | `POST /responses` = `1` | 当前 `400` JSON body 会被原样放进 `error.message` |
| `json-500` | `500 application/json`；body = `{"detail":"forced 500 from local /responses probe"}` | 在 websocket `404` 之后，终端进入 HTTP 重试；最终输出 `We're currently experiencing high demand, which may cause temporary errors.`，随后 `turn.failed` | `POST /responses` = `30` | 当前 `500` body 不会原样透传；CLI 会把它归一到固定高负载文案 |
| `malformed-sse` | `200 text/event-stream`；先给 `response.created`，第二个事件给非法 JSON | 终端最终输出 `stream disconnected before completion: stream closed before response.completed`，随后 `turn.failed` | `POST /responses` = `6` | 当前畸形 SSE 在 CLI 外观上被归一成“未完整结束的流” |
| `truncated-sse` | `200 text/event-stream`；给有效前缀后主动断开，不发送 `response.completed` | 终端最终输出 `stream disconnected before completion: stream closed before response.completed`，随后 `turn.failed` | `POST /responses` = `6` | 当前显式断流和畸形 SSE 在最终 CLI 外观上不可区分 |

当前含义：

- 对当前 `codex exec` 路径，网关如果要保留精确错误文案，`400` 和 `500` 不能用同一策略
- 当前 `500` 会被客户端吞掉服务端细节并改写成固定文案
- 当前流式异常面里，“坏 JSON” 和“半截流”最终都会收敛成同一类断流错误

### 3.1 `/responses` -> 交互 `codex --no-alt-screen` 首轮文本路径错误矩阵

固定测试条件：

- `openai_base_url=http://127.0.0.1:<probe-port>`
- 交互 TTY `codex --no-alt-screen`
- `features.apps=true`
- 首轮文本提示词固定为：
  - `Reply exactly ERR400.`
  - `Reply exactly ERR500.`
- probe 固定让 `GET /responses` 返回 `404`

| Probe mode | 服务器返回 | 当前终端外观 | 当前样本重放次数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `json-400` | `400 application/json`；body = `{"detail":"forced 400 from local /responses probe"}` | 终端最终输出 `{"detail":"forced 400 from local /responses probe"}` | `POST /responses` = `1` | 当前交互首轮文本路径会直接打印 `400` JSON body |
| `json-500` | `500 application/json`；body = `{"detail":"forced 500 from local /responses probe"}` | 终端最终输出 `We're currently experiencing high demand, which may cause temporary errors.` | `POST /responses` = `30` | 当前交互首轮文本路径会把 `500` 改写成固定高负载文案 |
| `malformed-sse` | `200 text/event-stream`；先给 `response.created`，第二个事件给非法 JSON | 终端最终输出 `stream disconnected before completion: stream closed before response.completed` | `POST /responses` = `6` | 当前交互首轮文本路径里，畸形 SSE 当前也收敛成“未完整结束的流” |
| `truncated-sse` | `200 text/event-stream`；给有效前缀后主动断开，不发送 `response.completed` | 终端最终输出 `stream disconnected before completion: stream closed before response.completed` | `POST /responses` = `6` | 当前交互首轮文本路径里，显式断流与畸形 SSE 当前不可区分 |

当前含义：

- 交互 `features.apps=true` 首轮文本路径的 `/responses` `400 / 500 / 畸形 SSE / 断流` 外观已经有直接终端证据
- 当前 `500` 的改写结果和 `codex exec --json` 当前路径一致
- 当前这条交互路径里，畸形 SSE 与显式断流都会收敛到同一类“未完整结束的流”文案

### 3.2 `/responses` -> 交互 `codex --no-alt-screen` 且 `features.apps=true` 同会话第二轮文本路径错误矩阵

固定测试条件：

- `openai_base_url=http://127.0.0.1:<probe-port>`
- 交互 TTY `codex --no-alt-screen`
- `features.apps=true`
- 同一交互会话先成功完成第 1 轮文本提示：
  - `Reply exactly APPERR...A.`
- 错误只注入第 `2` 个 `POST /responses`
- 第 2 轮文本提示固定为：
  - `Reply exactly APPERR...B.`

| Probe mode | 服务器返回 | 当前终端外观 | 当前样本重放次数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `json-400` | 第 `2` 个 `POST /responses` 返回 `400 application/json`；body = `{"detail":"forced 400 from local /responses proxy"}` | 第 2 轮终端最终输出 `{"detail": "forced 400 from local /responses proxy"}` | `POST /responses` = `2` | 当前同会话第二轮文本路径的 `400` 会直接终止，不发生补发 |
| `json-500` | 第 `2` 个 `POST /responses` 返回 `500 application/json`；body = `{"detail":"forced 500 from local /responses proxy"}` | 第 2 轮终端最终输出 `APPERR500B` | `POST /responses` = `3` | 当前同会话第二轮文本路径的 `500` 会触发一次补发，然后恢复成功 |
| `malformed-sse` | 第 `2` 个 `POST /responses` 返回 `200 text/event-stream`；给 `response.created` 后送非法事件 | 第 2 轮终端先显示 `Reconnecting...` 与 `Stream disconnected before completion: stream closed before response.completed`，随后最终输出 `APPERRMALB` | `POST /responses` = `3` | 当前同会话第二轮文本路径的畸形 SSE 会触发一次补发，然后恢复成功 |
| `truncated-sse` | 第 `2` 个 `POST /responses` 返回 `200 text/event-stream`；给合法前缀后主动断开，不发送 `response.completed` | 第 2 轮终端先显示 `Reconnecting...` 与 `Stream disconnected before completion: stream closed before response.completed`，随后最终输出 `APPERRTRUNCB` | `POST /responses` = `3` | 当前同会话第二轮文本路径的显式断流会触发一次补发，然后恢复成功 |

当前含义：

- 当前同会话第二轮文本路径的错误面已经和首轮文本路径分开收敛
- 当前第 2 轮里，`400` 和 `500` 的行为不同：
  - `400` 直接终止
  - `500` 当前会补发并恢复
- 当前第 2 轮里，`malformed-sse` 与 `truncated-sse` 都会先显式暴露断流，再补发恢复
- 这还不代表 apps 工具回合或第三轮及以上回合有同样行为

### 3.3 sidecar 故障 -> 非交互 GitHub app 业务动作错误外观

固定测试条件：

- `codex exec --json --enable apps`
- prompt 固定为：
  - `Use the GitHub app to tell me the authenticated GitHub login. Output only the login.`
- `/responses` 保持真实转发成功
- 仅把 `chatgpt_base_url` 指向 sidecar blocker

| Probe mode | 服务器返回 | 当前终端外观 | 当前样本重放次数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `sidecar-404` | 当前已观测 `/backend-api/plugins/featured?platform=codex`、`/backend-api/plugins/list`、`/backend-api/connectors/directory/list?tier=categorized&external_logos=true`、`/backend-api/wham/apps`、`/backend-api/codex/analytics-events/events` 统一返回 `404`；paired `/responses` 仍是 `200` | 终端先出现 `tool call error: failed to get client`、`MCP startup failed: handshaking with MCP server failed`、`error decoding response body`；随后 `github_get_profile` 也失败；最终 assistant 输出 `GitHub app error: unable to retrieve authenticated login.` | `POST /responses` = `3` | 当前非交互 GitHub app 业务动作在 sidecar `404` 下不会成功补发恢复；失败点在 MCP 客户端拿不到 sidecar 能力 |
| `sidecar-500` | 当前已观测 `/backend-api/plugins/featured?platform=codex`、`/backend-api/plugins/list`、`/backend-api/connectors/directory/list?tier=categorized&external_logos=true`、`/backend-api/wham/apps`、`/backend-api/codex/analytics-events/events` 统一返回 `500`；paired `/responses` 仍是 `200` | 终端先出现 `tool call error: failed to get client`、`MCP startup failed: handshaking with MCP server failed`、`error decoding response body`；`github_get_user_login` 重试后仍失败；最终 assistant 输出 `无法通过 GitHub app 获取登录名；GitHub app 握手失败。` | `POST /responses` = `3` | 当前非交互 GitHub app 业务动作在 sidecar `500` 下同样不会成功补发恢复；失败外观与 `404` 接近，但最终 assistant 文案不同 |

当前含义：

- 当前 apps 文本路径与当前 GitHub app 业务动作的错误面不同
- 对当前这条真实 app 业务动作，sidecar 故障会先表现成 MCP 客户端握手失败，再落到 assistant 级失败文案
- 这还不代表交互 apps 工具回合、其他 app 工具家族或第三轮及以上交互回合已有同样错误外观

### 3.4 sidecar 故障 -> 非交互 Gmail app 业务动作错误外观

固定测试条件：

- `codex exec --json --enable apps`
- prompt 固定为：
  - `Use the Gmail app to tell me the authenticated Gmail address. Output only the address.`
- `/responses` 保持真实转发成功
- 仅把 `chatgpt_base_url` 指向 sidecar blocker

| Probe mode | 服务器返回 | 当前终端外观 | 当前样本重放次数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `sidecar-404` | 当前已观测 `/backend-api/plugins/featured?platform=codex`、`/backend-api/plugins/list`、`/backend-api/connectors/directory/list?tier=categorized&external_logos=true`、`/backend-api/wham/apps`、`/backend-api/codex/analytics-events/events` 统一返回 `404`；paired `/responses` 仍是 `200` | 终端先出现 `gmail_get_profile` 的 `tool call error: failed to get client`；随后 `gmail_list_labels` 也失败；最终 assistant 输出 `Gmail connector unavailable` | `POST /responses` = `5` | 当前 Gmail app 业务动作在 sidecar `404` 下不会恢复成功；错误面已经不只限于 GitHub 家族 |
| `sidecar-500` | 当前已观测 `/backend-api/plugins/featured?platform=codex`、`/backend-api/plugins/list`、`/backend-api/connectors/directory/list?tier=categorized&external_logos=true`、`/backend-api/wham/apps`、`/backend-api/codex/analytics-events/events` 统一返回 `500`；paired `/responses` 仍是 `200` | 终端先出现两次 `gmail_get_profile` 的 `tool call error: failed to get client`；随后 agent 落到本地回退搜索，检查 `~/.codex`、`auth.json`、`state_5.sqlite`、`logs_2.sqlite` | `POST /responses` = `6` | 当前 Gmail app 业务动作在 sidecar `500` 下也不会恢复成功；当前外观比 `404` 更重，会进入本地回退搜索 |

当前含义：

- 当前 Gmail app 业务动作在 sidecar `404/500` 下都失败
- 当前 `500` 与 `404` 在终端外观上已经拉开差异：
  - `404` 当前收敛到连接器不可用
  - `500` 当前会进入本地回退搜索

### 3.5 sidecar 故障 -> 非交互 Notion app 业务动作错误外观

固定测试条件：

- `codex exec --json --enable apps`
- prompt 固定为：
  - `Use the Notion app to search Notion users for Norvyn Zhang and return only the exact name. If the tool rejects query_type=users, retry with query_type=user.`
- `/responses` 保持真实转发成功
- 仅把 `chatgpt_base_url` 指向 sidecar blocker

| Probe mode | 服务器返回 | 当前终端外观 | 当前样本重放次数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `sidecar-404` | 当前已观测 `/backend-api/plugins/featured?platform=codex`、`/backend-api/plugins/list`、`/backend-api/connectors/directory/list?tier=categorized&external_logos=true`、`/backend-api/wham/apps`、`/backend-api/codex/analytics-events/events` 统一返回 `404`；paired `/responses` 仍是 `200` | 终端先后尝试 `query_type=users` 与 `query_type=user`；两次 `notion (legacy)_search` 都以 `tool call error: failed to get client` 结束；最终 assistant 输出 `⚠️ 无法验证: Notion app MCP 启动握手失败；\`query_type=users\` 与 \`query_type=user\` 两次请求都未成功执行。` | `POST /responses` = `4` | 当前 Notion app 业务动作在 sidecar `404` 下失败点发生在 MCP 握手阶段，而不是实际查询阶段 |
| `sidecar-500` | 当前已观测 `/backend-api/plugins/featured?platform=codex`、`/backend-api/plugins/list`、`/backend-api/connectors/directory/list?tier=categorized&external_logos=true`、`/backend-api/wham/apps`、`/backend-api/codex/analytics-events/events` 统一返回 `500`；paired `/responses` 仍是 `200` | 终端两次尝试 `query_type=users` 后，又尝试 `query_type=user`；三次 `notion (legacy)_search` 都以 `tool call error: failed to get client` 结束；最终 assistant 输出 `⚠️ 无法验证：Notion app 在 \`query_type=users\` 和 \`query_type=user\` 两次调用中都在 MCP 握手阶段失败，未进入查询。` | `POST /responses` = `5` | 当前 Notion app 业务动作在 sidecar `500` 下也失败；与 `404` 的差异主要体现在重试深度，不在查询结果层 |

当前含义：

- 当前 Notion app 业务动作在 sidecar `404/500` 下都失败
- 当前 Notion 家族的失败点稳定落在 MCP 握手阶段

## 4. `/v1/messages` -> `claude --bare -p` 错误矩阵

固定测试条件：

- `ANTHROPIC_BASE_URL=http://127.0.0.1:<probe-port>`
- `ANTHROPIC_AUTH_TOKEN=test-token`
- CLI 提示词固定为 `reply with one short word`
- `/v1/messages/count_tokens` 统一返回 `200 {"input_tokens":1}`

| Probe mode | 服务器返回 | 当前终端外观 | 当前样本重放次数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `json-400` | `400 application/json`；body = `{"type":"error","error":{"type":"invalid_request_error","message":"forced 400 from local /v1/messages probe"}}` | 终端直接输出 `API Error: 400 {...}` | `POST /v1/messages` = `2` | 当前 `400` 会按 API Error 直接打印完整 JSON |
| `json-500` | `500 application/json`；body = `{"type":"error","error":{"type":"api_error","message":"forced 500 from local /v1/messages probe"}}` | 在一个本地 `15s` time-bounded run 里，终端没有产生可见错误文本；进程由本地 alarm 结束 | `POST /v1/messages` = `10` | 当前 `500` 路径存在内部重试；不能把它当成“单次请求立即返回终端错误” |
| `malformed-sse` | `200 text/event-stream`；先给合法 `message_start`，随后给非法 JSON `data: {not-json}` | 终端输出两次 `Could not parse message into JSON: {not-json}`，最后输出 `undefined is not an object (evaluating '_.input_tokens')` | `POST /v1/messages` = `4` | 当前畸形 SSE 会显式暴露 JSON 解析失败，然后落到内部空值错误 |
| `truncated-sse` | `200 text/event-stream`；给合法前缀后主动断开，不发送结束事件 | 终端输出 `undefined is not an object (evaluating '_.input_tokens')` | `POST /v1/messages` = `4` | 当前半截 Anthropic SSE 不会显示“断流”字样，最终落到内部空值错误 |

当前样本还确认：

- 简单 `claude --bare -p` 请求不是单发；当前 `400` 样本里已经观察到 `2` 个 `POST /v1/messages`
- 当前 `500` clean sample 在 `15s` 内观察到 `10` 个 `POST /v1/messages`
- 当前 `400` 和 `500` 的服务端 body 形状不同，但只有 `400` 被终端原样打印

### 4.1 `/v1/messages` -> 默认 `claude -p` tool-use 回合错误矩阵

固定测试条件：

- `ANTHROPIC_BASE_URL=http://127.0.0.1:<probe-port>`
- `ANTHROPIC_AUTH_TOKEN=test-token`
- 默认 `claude -p`
- 第 `1` 条 `/v1/messages` 固定返回 `Read` tool_use
- 第 `2` 条 `/v1/messages` 起按 probe mode 返回错误

| Probe mode | 服务器返回 | 当前终端外观 | 当前样本重放次数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `json-400` | 第 `2` 条请求返回 `400 application/json`；body = `{"type":"error","error":{"type":"invalid_request_error","message":"forced 400 from local tool-roundtrip probe"}}` | 终端直接输出 `API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"forced 400 from local tool-roundtrip probe"}}` | `POST /v1/messages` = `2` | 默认 `claude -p` tool-use 回合里的 `400` 当前也会直接打印完整 API Error JSON |
| `json-500` | 第 `2` 条请求起返回 `500 application/json`；body = `{"type":"error","error":{"type":"api_error","message":"forced 500 from local tool-roundtrip probe"}}` | 在一个本地 `30s` time-bounded PTY run 里，终端没有产生可见错误文本；进程由本地 `Ctrl-C` 结束 | `POST /v1/messages` = `8` | 默认 `claude -p` tool-use 回合里的 `500` 当前同样表现成内部重试，不能写成“立即返回终端错误” |
| `malformed-sse` | 第 `2` 条请求起返回 `200 text/event-stream`；先给合法 `message_start`，随后给非法 JSON `data: {not-json}` | 终端输出 `Could not parse message into JSON: {not-json}`、`From chunk: [ "event: content_block_delta", "data: {not-json}" ]`，最后输出 `undefined is not an object (evaluating '_.input_tokens')` | `POST /v1/messages` = `3` | 默认 `claude -p` tool-use 回合里的畸形 SSE 当前会显式暴露 JSON 解析失败，然后落到同一个内部空值错误 |
| `truncated-sse` | 第 `2` 条请求起返回 `200 text/event-stream`；给合法前缀后主动断开，不发送结束事件 | 终端输出 `undefined is not an object (evaluating '_.input_tokens')` | `POST /v1/messages` = `3` | 默认 `claude -p` tool-use 回合里的半截 SSE 当前不显示“断流”字样，最终也落到内部空值错误 |

当前含义：

- 默认 `claude -p` tool-use 回合当前已经有 `400 / 500 / 畸形 SSE / 断流` 的直接终端证据
- 当前第 `2` 条请求都已经确认带了 `tool_result`
- 默认 `claude -p` tool-use 回合和 `claude --bare -p` 当前错误外观一致；差异主要在重试次数

### 4.3 交互 GitHub app 工具回合在 sidecar `404` 与 `500` 下的当前外观

固定测试条件：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen --enable apps`
- prompt 固定为：
  - `Use the GitHub app to tell me the authenticated GitHub numeric id. Output only the digits.`
- `/responses` 主出口保持真实转发成功
- `chatgpt_base_url` 指向本地 `/backend-api` blocker

当前 `404` 样本：

- transcript 启动期出现：
  - `MCP client for \`codex_apps\` failed to start`
  - `MCP startup incomplete (failed: codex_apps)`
- blocker log 里的 sidecar 请求都带：
  - `"mode": "404"`
- paired forward log 里当前观测到：
  - `GET /responses = 7`
  - `POST /responses = 1`
- transcript 工具阶段出现：
  - `Called codex_apps.github_get_profile({})`
  - `tool call error: failed to get client`
  - `MCP startup failed: handshaking with MCP server failed`
  - `error decoding response body`

当前 `500` 样本：

- transcript 启动期同样出现：
  - `MCP client for \`codex_apps\` failed to start`
  - `MCP startup incomplete (failed: codex_apps)`
- blocker log 里的 sidecar 请求都带：
  - `"mode": "500"`
- paired forward log 里当前观测到：
  - `GET /responses = 7`
  - `POST /responses = 1`
- transcript 工具阶段同样出现：
  - `Called codex_apps.github_get_profile({})`
  - `tool call error: failed to get client`
  - `MCP startup failed: handshaking with MCP server failed`
  - `error decoding response body`

当前含义：

- 对当前交互 GitHub app 工具回合，sidecar `404` 与 sidecar `500` 的用户可见外观当前高度一致
- 当前差异主要体现在 blocker log 的 `mode`，不是终端外观

## 5. 当前结论

当前第一版错误兼容矩阵已经收敛出两条硬差异：

- `codex exec` 侧：
  - `400` 会保留服务端 JSON 文本
  - `500` 会改写成固定高负载文案
  - 流式异常会统一成“stream disconnected before completion”
  - 当前 GitHub app 业务动作在 sidecar `404/500` 下会先暴露 MCP 客户端握手失败，再落到 assistant 级失败文案
  - 当前 Gmail app 业务动作在 sidecar `404` 下会收敛到 `Gmail connector unavailable`，在 sidecar `500` 下会进入本地回退搜索
  - 当前 Notion app 业务动作在 sidecar `404/500` 下都会停在 MCP 握手失败阶段
- 交互 apps 工具回合侧：
  - 当前 GitHub app 工具回合在 sidecar `404/500` 下都会先暴露 `codex_apps` MCP 启动失败
  - 随后的工具阶段都会暴露 `failed to get client`
  - 当前终端外观上，`404` 与 `500` 没有拉开差异
- `claude --bare -p` 侧：
  - `400` 会直接打印完整 API Error JSON
  - `500` 当前表现成客户端内部重试
  - 畸形或半截 SSE 不会稳定收敛到服务端错误类型，而会落到解析失败或内部空值错误

当前还不能写死的内容：

- Claude 交互会话里的错误外观
- `codex exec resume`、交互 TUI 更深回合、交互 `features.apps=true` 更深回合与 apps 工具回合的流式异常外观
- 网关是否需要针对这些路径单独做错误翻译

## 6. 证据位置

- `/responses` probes:
  - `/tmp/responses-error-400/events.jsonl`
  - `/tmp/responses-error-500/events.jsonl`
  - `/tmp/responses-error-malformed/events.jsonl`
  - `/tmp/responses-error-truncated/events.jsonl`
  - `/tmp/codex-interactive-errors-8821/events.jsonl`
  - `/tmp/codex-interactive-errors-8822/events.jsonl`
  - `/tmp/codex-interactive-errors-8821.typescript`
  - `/tmp/codex-interactive-errors-8822.typescript`
  - `/tmp/codex-gmail-sidecar404-forward-8886/events.jsonl`
  - `/tmp/codex-gmail-sidecar404-blocker-8887/events.jsonl`
  - `/tmp/codex-gmail-sidecar500-forward-8891/events.jsonl`
  - `/tmp/codex-gmail-sidecar500-blocker-8892/events.jsonl`
  - `/tmp/codex-notion-sidecar404-blocker-8894/events.jsonl`
  - `/tmp/codex-notion-sidecar500-blocker-8895/events.jsonl`
  - `/tmp/codex-interactive-apps-malformed-8832/events.jsonl`
  - `/tmp/codex-interactive-apps-malformed-8832.expect.log`
  - `/tmp/codex-interactive-apps-truncated-8833/events.jsonl`
  - `/tmp/codex-interactive-apps-truncated-8833.expect.log`
  - `/tmp/codex-interactive-apps-errors2-400-8860/events.jsonl`
  - `/tmp/codex-interactive-apps-errors2-500-8861/events.jsonl`
  - `/tmp/codex-interactive-apps-errors2-malformed-8862/events.jsonl`
  - `/tmp/codex-interactive-apps-errors2-truncated-8863/events.jsonl`
  - `/tmp/codex-apps-github-sidecar404-forward-8870/events.jsonl`
  - `/tmp/codex-apps-github-sidecar404-blocker-8871/events.jsonl`
  - `/tmp/codex-apps-github-sidecar500-forward-8872/events.jsonl`
  - `/tmp/codex-apps-github-sidecar500-blocker-8873/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar404-8882.typescript`
  - `/tmp/codex-interactive-github-sidecar404-forward-8882/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar404-blocker-8883/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar500-8884.typescript`
  - `/tmp/codex-interactive-github-sidecar500-forward-8884/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar500-blocker-8885/events.jsonl`
- `/v1/messages` probes:
  - `/tmp/anthropic-error-400/events.jsonl`
  - `/tmp/anthropic-error-500-clean/events.jsonl`
  - `/tmp/anthropic-error-malformed/events.jsonl`
  - `/tmp/anthropic-error-truncated/events.jsonl`
  - `/tmp/anthropic-tool-error-400/events.jsonl`
  - `/tmp/anthropic-tool-error-500/events.jsonl`
  - `/tmp/anthropic-tool-error-malformed/events.jsonl`
  - `/tmp/anthropic-tool-error-truncated/events.jsonl`
