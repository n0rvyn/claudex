# 上游订阅面

Date: 2026-04-20

## 1. 文档定位

本文件只记录方案三已经确认的上游订阅面。

这里把上游分成两层：

- 主推理面
- 辅助产品面

## 2. 主推理面

### 2.1 已验证路径

当前已验证的本地入口路径：

- `GET /responses`
- `POST /responses`

说明：

- 这是把 `openai_base_url` 指到本地探针后捕获到的真实请求
- 这说明本地 override 入口使用 `/responses`

当前已验证的默认真实远端路径：

- `wss://chatgpt.com/backend-api/codex/responses`
- `https://chatgpt.com/backend-api/codex/responses`

说明：

- 这是通过 `HTTPS_PROXY` 探针和默认运行路径共同捕获到的结果
- 当前证据支持把 `chatgpt.com/backend-api/codex/responses` 视为方案三真实远端主推理面

来源：

- [研究总稿第 3 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:34)
- [研究总稿 Appendix A.6](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:325)
- [研究总稿 Evidence Ledger；默认真实远端](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:38)
- [09-real-upstream-capture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/09-real-upstream-capture.md)

### 2.2 已验证认证头

当前已验证：

- `Authorization: Bearer ...`
- `chatgpt-account-id`

这两个头已同时出现在：

- `/responses`
- `/backend-api/...`

来源：

- [研究总稿第 3 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:35)

### 2.3 已验证流式和压缩特征

当前已验证：

- `codex exec` 先尝试 `ws://.../responses`
- websocket 失败后会尝试 `http://.../responses`
- `POST /responses` 已观测到：
  - `accept: text/event-stream`
  - `content-type: application/json`
  - `content-encoding: zstd`

来源：

- [研究总稿第 8 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:204)
- [研究总稿 Appendix A.6](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:333)

### 2.4 已验证最小 HTTP 成功契约

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- 单轮文本回复路径
- `features.apps=false`

在这个范围内，当前已验证：

- websocket `GET /responses` 连续 `404` 后，HTTP `POST /responses` 仍可完成当前路径
- 本地 probe 返回的以下事件顺序已被当前客户端接受：
  1. `response.created`
  2. `response.in_progress`
  3. `response.output_item.added`
  4. `response.content_part.added`
  5. `response.output_text.delta`
  6. `response.output_text.done`
  7. `response.content_part.done`
  8. `response.output_item.done`
  9. `response.completed`

补充说明：

- 当前被接受的 probe 事件没有发送 `sequence_number`
- 当前被接受的 probe 文本 part 没有发送 `annotations`
- 这只能说明“当前路径当前版本可接受这些字段缺席”

来源：

- [研究总稿 Evidence Ledger；HTTP fallback 成功](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:36)
- [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md)

### 2.4.1 已验证 HTTP-only 覆盖到 `codex exec resume`

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `codex exec resume --json`
- websocket `GET /responses` 连续 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游
- `features.apps=false`

当前已验证：

- 第一条会话：
  - 首轮提示 `Reply exactly FIRST.`
  - 续轮提示 `Reply exactly SECOND.`
  - 两轮都在 websocket 全部 `404` 后完成
  - 两轮都得到：
    - `item.completed`
    - `turn.completed`
- 第二条会话：
  - 首轮提示 `Reply exactly ALPHA.`
  - 续轮提示 `Read /etc/hosts and reply with only the first token.`
  - 续轮期间代理侧先看到一个 HTTP `POST /responses` 返回：
    - `reasoning`
    - `function_call`
  - 随后客户端再次发起第二个 HTTP `POST /responses`，请求体包含：
    - `reasoning`
    - `function_call`
    - `function_call_output`
  - 最终续轮得到：
    - 本地 `command_execution`
    - assistant 最终文本 `##`
    - `turn.completed`

当前样本还确认：

- 续轮请求当前没有设置 `previous_response_id`
- 当前续轮样本通过扩展 `input` 历史继续会话
- 续轮文本样本：
  - `input_len = 6`
- 续轮工具样本：
  - 第一个续轮请求 `input_len = 6`
  - 第二个续轮请求 `input_len = 9`

当前含义：

- 对当前非交互 CLI 路径，HTTP-only 已覆盖：
  - 单轮文本
  - 单轮工具回合
  - 多轮文本
  - 多轮续轮里的 native tool path
- 当前还不能把这个结论外推到：
  - 其他未验证 CLI 入口

来源：

- [研究总稿 Appendix A.21](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 2.4.2 已验证 HTTP-only 覆盖到交互 `features.apps=true` 首轮文本路径

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 首轮文本回复路径
- `features.apps=true`
- websocket `GET /responses` 连续 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

当前已验证：

- 当前客户端会先多次尝试 websocket `GET /responses`
- websocket 全部 `404` 后，仍继续发起 HTTP `POST /responses`
- 当前样本的 HTTP `POST /responses` 返回 `200`
- 交互终端最终输出：
  - `APPSHTTP`

当前含义：

- HTTP-only 的当前覆盖范围已经扩到交互 `features.apps=true` 首轮文本路径
- 这还不是更深 apps 回合或其他 CLI 入口都已覆盖的结论

来源：

- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)

### 2.4.3 已验证 HTTP-only 覆盖到非交互 `features.apps=true` 的 `codex exec/exec resume` 文本路径

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `codex exec resume --json`
- `features.apps=true`
- websocket `GET /responses` 连续 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

当前已验证：

- 首轮命令 `Reply exactly APPSRESUME1.` 成功完成，并输出：
  - `APPSRESUME1`
- 续轮命令 `Reply exactly APPSRESUME2.` 成功完成，并输出：
  - `APPSRESUME2`
- 两轮都得到：
  - `item.completed`
  - `turn.completed`
- 当前 paired forward log 还确认：
  - `POST /responses = 2`
  - 第 1 个请求：
    - `input_len = 3`
    - `tools_len = 21`
  - 第 2 个请求：
    - `input_len = 6`
    - `tools_len = 21`

当前含义：

- HTTP-only 的当前覆盖范围已经从交互 apps 首轮文本扩到非交互 apps 续轮文本
- 当前 apps 续轮文本路径已经有直接请求骨架证据
- 这还不是更深 apps 工具回合或交互 apps 更深回合都已覆盖的结论

来源：

- [17-exec-apps-resume-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/17-exec-apps-resume-coverage-v1.md)

### 2.5 已验证真实远端成功样本

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- 单轮文本回复路径
- websocket `404` 后走 HTTP

在这个范围内，当前已验证：

- 转发到 `https://chatgpt.com/backend-api/codex/responses` 时上游返回 `200`
- `codex exec` 成功完成本轮回复
- 真实 SSE 事件序列是：
  1. `response.created`
  2. `response.in_progress`
  3. `response.output_item.added`
  4. `response.output_item.done`
  5. `response.output_item.added`
  6. `response.content_part.added`
  7. `response.output_text.delta`
  8. `response.output_text.done`
  9. `response.content_part.done`
  10. `response.output_item.done`
  11. `response.completed`

真实样本相对本地最小契约多出的已验证内容：

- 开头一对 reasoning item
- `sequence_number`
- `logprobs`
- `obfuscation`
- reasoning `encrypted_content`
- assistant message `phase`

来源：

- [研究总稿 Evidence Ledger；真实远端成功样本](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:40)
- [09-real-upstream-capture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/09-real-upstream-capture.md)

### 2.6 已验证请求骨架

当前已验证：

- `POST /responses` 的 zstd 请求体可以被解压成标准 Responses create payload 骨架
- 当前样本顶层字段包括：
  - `model`
  - `instructions`
  - `input`
  - `tools`
  - `tool_choice`
  - `parallel_tool_calls`
  - `reasoning`
  - `store`
  - `stream`
  - `include`
  - `service_tier`
  - `prompt_cache_key`
  - `text`
  - `client_metadata`

来源：

- [研究总稿 Evidence Ledger；zstd 请求骨架](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:37)
- [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md)

### 2.6.1 当前四份首轮请求样本的顶层骨架一致

当前范围：

- 当前四份已解压首轮请求样本：
  - `/tmp/responses-forward-8797/008-request.json`
  - `/tmp/responses-forward-8797/016-request.json`
  - `/tmp/codex-apps-http-only-8806/008-request.json`
  - `/tmp/codex-interactive-errors-8821/008-request.json`

当前已验证：

- 四份样本的顶层字段完全一致：
  - `client_metadata`
  - `include`
  - `input`
  - `instructions`
  - `model`
  - `parallel_tool_calls`
  - `prompt_cache_key`
  - `reasoning`
  - `service_tier`
  - `store`
  - `stream`
  - `text`
  - `tool_choice`
  - `tools`
- 四份样本的共享值一致：
  - `model = "gpt-5.4"`
  - `stream = true`
  - `store = false`
  - `tool_choice = "auto"`
  - `parallel_tool_calls = true`
  - `include = ["reasoning.encrypted_content"]`
  - `service_tier = "priority"`
  - `prompt_cache_key` 都是字符串
  - `input_len = 3`
- 当前已验证差异集中在 `tools`：
  - 非交互两份样本：
    - `tools_len = 16`
    - 类型分布：
      - `function = 13`
      - `custom = 1`
      - `web_search = 1`
      - `namespace = 1`
  - 交互 `features.apps=true` 两份样本：
    - `tools_len = 21`
    - 类型分布：
      - `function = 13`
      - `custom = 1`
      - `web_search = 1`
      - `namespace = 6`

当前含义：

- 当前四份首轮请求样本的主骨架已经稳定
- 当前已验证差异不是顶层 payload，而是工具清单，尤其是 `features.apps=true` 引入的额外 `namespace` 工具
- 这还不包含续轮、工具回合和更深 apps 回合

来源：

- [16-request-shape-comparison-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/16-request-shape-comparison-v1.md)

### 2.7 已验证错误外观

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `features.apps=false`
- 本地 `/responses` loopback probe

当前已验证：

- `400 application/json`
  - 终端会在 websocket `404` 重连结束后输出原样 JSON 文本
  - 当前样本的最终错误是：
    - `{"detail": "forced 400 from local /responses probe"}`
- `500 application/json`
  - 当前样本的服务端 body 不会原样透传
  - 终端最终输出固定文案：
    - `We're currently experiencing high demand, which may cause temporary errors.`
  - 当前样本里观测到 `30` 次 `POST /responses`
- `200 text/event-stream` + 非法 JSON chunk
  - 终端最终输出：
    - `stream disconnected before completion: stream closed before response.completed`
  - 当前样本里观测到 `6` 次 `POST /responses`
- `200 text/event-stream` + 提前断流
  - 终端最终输出：
    - `stream disconnected before completion: stream closed before response.completed`
  - 当前样本里观测到 `6` 次 `POST /responses`

当前含义：

- 当前 `400` 和 `500` 不能共用同一类错误翻译
- 当前畸形 SSE 和当前断流在最终 CLI 外观上不可区分

来源：

- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)

### 2.7.1 交互 `features.apps=true` 首轮文本路径的 `/responses` `400` 与 `500` 外观已验证

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 首轮文本回复路径
- `features.apps=true`
- 本地 `/responses` loopback probe

当前已验证：

- 当前 `400 application/json`
  - 终端最终输出：
    - `{"detail":"forced 400 from local /responses probe"}`
  - 当前样本里观测到：
    - `POST /responses = 1`
- 当前 `500 application/json`
  - 终端最终输出：
    - `We're currently experiencing high demand, which may cause temporary errors.`
  - 当前样本里观测到：
    - `POST /responses = 30`

当前含义：

- 交互 `features.apps=true` 首轮文本路径的 `/responses` `400` 与 `500` 已有直接终端证据
- 当前 `500` 的改写结果与 `codex exec --json` 当前路径一致
- 这还不包含同一路径的畸形 SSE 与断流

来源：

- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)

### 2.8 已验证工具声明层

当前 `/responses` 样本已验证：

- 工具总数是 `16`
- 类型分布：
  - `function`: `13`
  - `custom`: `1`
  - `web_search`: `1`
  - `namespace`: `1`
- 当前样本里的函数工具使用：
  - `type`
  - `name`
  - `description`
  - `parameters`
  - `strict`

当前含义：

- 当前 `/responses` 样本的函数工具声明层
- 和 Claude 样本里的 `name + description + input_schema`
- 不是同一个顶层结构

来源：

- [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)

### 2.9 已验证代表性函数家族的上游函数回合

当前范围：

- `claude --bare -p` 抓到的 `3` 个 function tools
- 默认 `claude -p` 抓到的 `55` 个 function tools
- 本地代理把它们改写成 `/responses` function tools
- 第一段强制 `Bash`
- 第二段把 `function_call_output` 送回真实远端

当前已验证：

- 第一段真实远端返回：
  - `response.output_item.added`
    - `item.type = "function_call"`
    - `item.name = "Bash"`
  - `response.function_call_arguments.done`
    - `arguments = "{\"command\":\"true\",\"description\":\"Run no-op command\"}"`
- 第二段请求的 `input` 当前已验证包含：
  - `reasoning`
  - `function_call`
  - `function_call_output`
- 第二段真实远端返回普通 assistant message
- 当前已拿到两条成功第二段文本：
  - `Called \`Bash\` once with a minimal valid no-op command: \`true\`.`
  - `Ran a minimal Bash command successfully.`
- 两条路径里的 `codex exec` 当前都拿到了：
  - `item.completed`
  - `turn.completed`
- 默认 `55` 个 function tools 环境下，当前又拿到四条成功第二段文本：
  - `WebSearch was called with the minimal valid argument set: \`query: "AI"\`.`
  - `Invocation completed.`
  - `Called \`Read\` once with \`file_path: /etc/hosts\`.`
  - `` `Edit` was called with minimal arguments. ``

当前含义：

- 当前订阅上游不只接受改写后的函数工具声明
- 对当前 `--bare` / `Bash` 路径，也已经接受 `function_call_output` 续回
- 默认 `55` 个 function tools 的大工具集环境下，当前 `Bash` 路径也已经接受 `function_call_output` 续回
- 默认 `55` 个 function tools 的大工具集环境下，当前代表性函数家族也已经接受 `function_call_output` 续回
- 当前结论不能外推到每一个具体 `mcp__...` 工具实例或更深业务语义

来源：

- [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)
- [研究总稿 Appendix A.14](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)
- [研究总稿 Appendix A.15](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)
- [研究总稿 Appendix A.16](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 2.10 已验证 public Responses API 拒绝结果

当前已验证：

- 把当前捕获到的 `/responses` 请求
- 连同 Bearer 与 `chatgpt-account-id`
- 转发到 `https://api.openai.com/v1/responses`

会得到：

- `401 Unauthorized`
- `Missing scopes: api.responses.write`

来源：

- [研究总稿 Evidence Ledger；public API scope 拒绝](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:39)
- [09-real-upstream-capture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/09-real-upstream-capture.md)

## 3. 辅助产品面

### 3.1 已验证路径

当前已验证的辅助面路径包括：

- `/backend-api/plugins/list`
- `/backend-api/plugins/featured`
- `/backend-api/codex/analytics-events/events`

这些路径属于：

- 插件
- 目录
- 分析事件

来源：

- [研究总稿第 3 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:33)

### 3.2 当前非交互主路径不依赖已观测 sidecar 请求

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `features.apps=false`
- `/responses` 真实转发成功

当前已验证：

- 当以下 sidecar 请求统一返回 `404` 时：
  - `/backend-api/plugins/featured?platform=codex`
  - `/backend-api/plugins/list`
  - `/backend-api/codex/analytics-events/events`
  主路径仍然完成，并得到：
  - `item.completed = SIDECAR`
  - `turn.completed`
- 当同一组 sidecar 请求统一返回 `500` 时：
  - 主路径仍然完成，并得到：
    - `item.completed = SIDECAR500`
    - `turn.completed`

当前含义：

- 对当前非交互主路径，当前已观测到的 sidecar 请求不是 hard dependency
- 当前主路径的必需出口仍然是 `/responses`

来源：

- [13-sidecar-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/13-sidecar-dependency-v1.md)

### 3.2.1 当前交互 `features.apps=true` 首轮文本路径在 sidecar `404` 与 `500` 下仍能完成

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 首轮文本回复路径
- `features.apps=true`
- `/responses` 真实转发成功

当前已验证：

- 当当前已观测到的 sidecar 请求统一返回 `404` 时：
  - `/backend-api/plugins/featured?platform=codex`
  - `/backend-api/plugins/list`
  - `/backend-api/wham/apps`
  - `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
  - `/backend-api/wham/usage`
  - `/backend-api/codex/analytics-events/events`
  - 当前首轮文本路径仍然完成，并得到：
    - `APPS404`
- 当当前已观测到的 sidecar 请求统一返回 `500` 时：
  - `/backend-api/plugins/list`
  - `/backend-api/plugins/featured?platform=codex`
  - `/backend-api/wham/apps`
  - `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
  - `/backend-api/codex/analytics-events/events`
  - 当前首轮文本路径仍然完成，并得到：
    - `APPS500`
  - 当前终端还会额外出现：
    - `MCP client for \`codex_apps\` failed to start`
    - `MCP startup incomplete (failed: codex_apps)`

当前含义：

- 对当前交互 `features.apps=true` 首轮文本路径，当前已观测 sidecar 请求不是 hard dependency
- sidecar `500` 在这条路径里会暴露 `codex_apps` MCP 启动失败警告

来源：

- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)

### 3.2.2 当前非交互 `features.apps=true` 的 `exec/exec resume` 文本路径在 sidecar `404` 与 `500` 下仍能完成

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `codex exec resume --json`
- `features.apps=true`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 sidecar 请求统一返回 `404` 或统一返回 `500`

当前已验证：

- 当前已观测 sidecar 路径包括：
  - `/backend-api/codex/analytics-events/events`
  - `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
  - `/backend-api/plugins/featured?platform=codex`
  - `/backend-api/plugins/list`
  - `/backend-api/wham/apps`
- sidecar `404` 样本：
  - 首轮输出：
    - `APPSSIDE404A`
  - 续轮输出：
    - `APPSSIDE404B`
- sidecar `500` 样本：
  - 首轮输出：
    - `APPSSIDE500A`
  - 续轮输出：
    - `APPSSIDE500B`
- 两组样本都仍有：
  - `item.completed`
  - `turn.completed`
- 两组样本都额外暴露 stderr：
  - `rmcp::transport::worker ... data did not match any variant of untagged enum JsonRpcMessage ...`

当前含义：

- 当前 apps-enabled 非交互续轮文本路径也已证明：当前已观测 sidecar 请求不是 hard dependency
- 当前 sidecar 故障会暴露 stderr，但不会阻止这条主路径完成
- 这还不是 apps 业务动作、交互 apps 更深回合或未来 sidecar 新路径都不受影响的结论

来源：

- [17-exec-apps-resume-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/17-exec-apps-resume-coverage-v1.md)

### 3.2.3 当前真实 GitHub app 业务动作在 forward-only 对照下成功，但在 sidecar `404` 与 `500` 下都会失败

当前范围：

- `codex-cli 0.121.0`
- 非交互 `codex exec --json --enable apps`
- 当前真实业务动作：
  - `github_get_user_login`
- prompt 固定为：
  - `Use the GitHub app to tell me the authenticated GitHub login. Output only the login.`

当前已验证：

- 正常环境样本：
  - 终端出现真实 `mcp_tool_call`
  - `tool = github_get_user_login`
  - 工具结果：
    - `{"login":"n0rvyn","id":99057954}`
  - 最终 assistant 输出：
    - `n0rvyn`
- forward-only 对照样本：
  - `openai_base_url` 指向本地 `/responses` 透明转发
  - 不 override `chatgpt_base_url`
  - 同一工具调用仍完成
  - 最终 assistant 输出仍是：
    - `n0rvyn`
  - paired forward log 里出现：
    - `GET /responses = 7`
    - `POST /responses = 2`
    - `status 200 = 2`
- sidecar `404` 样本：
  - `/responses` forward log 里仍出现：
    - `GET /responses = 7`
    - `POST /responses = 3`
    - `status 200 = 3`
  - 终端工具错误文本包括：
    - `tool call error: failed to get client`
    - `MCP startup failed: handshaking with MCP server failed`
    - `error decoding response body`
  - 最终 assistant 输出：
    - `GitHub app error: unable to retrieve authenticated login.`
- sidecar `500` 样本：
  - `/responses` forward log 里仍出现：
    - `GET /responses = 7`
    - `POST /responses = 3`
    - `status 200 = 3`
  - 终端工具错误文本包括：
    - `tool call error: failed to get client`
    - `MCP startup failed: handshaking with MCP server failed`
    - `error decoding response body`
  - 最终 assistant 输出：
    - `无法通过 GitHub app 获取登录名；GitHub app 握手失败。`

当前含义：

- 当前文本路径与当前 GitHub app 业务动作，对 sidecar 的依赖边界不同
- 当前这条真实 GitHub app 业务动作在正常环境与 forward-only 对照下都成功，排除了“本地 `/responses` 转发本身导致失败”
- 对至少一个真实 apps 工具业务动作，当前 `/backend-api/...` sidecar 是 hard dependency

来源：

- [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)

### 3.3 当前不能扩大解释

当前证据不支持以下写法：

- “所有订阅态能力都在 `/backend-api/wham/...`”
- “方案三只需要 `/backend-api`，不需要 `/responses`”
- “`/wham/tasks` 就是 `codex exec` 的主推理入口”
- “所有入口都不依赖 `/backend-api/...`”
- “所有 `features.apps=true` 回合都能在 sidecar 故障下保持完整功能”
- “当前 GitHub app 业务动作失败是 `/responses` 本地转发造成的”

## 4. 已验证源码边界

当前源码证据支持以下分层：

- `chatgpt_base_url`
  - ChatGPT/backend 产品面
- `openai_base_url`
  - built-in `openai` provider 的上游面

来源：

- [研究总稿第 3 节；配置源码与 schema](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:34)

## 5. 当前不能写死的内容

以下内容还没有被验证完成：

- websocket 首帧和升级后的消息结构
- 多个 zstd 请求样本中的稳定字段集合
- `/responses` 成功时是否总是沿用当前 probe 已验证的 HTTP 事件顺序

这些内容进入：

- [05-validation-matrix.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/05-validation-matrix.md)
- [06-open-questions.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/06-open-questions.md)
