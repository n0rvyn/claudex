# 方案三已验证基线

Date: 2026-04-20

## 1. 适用范围

本文件只记录已经被二次验证的事实。

所有条目都要能回到：

- 官方文档
- OpenAI 官方开源代码
- 本机运行态探针

主证据稿：

- [研究总稿](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

## 2. 硬约束

以下约束来自用户，不属于待讨论范围：

- 前端必须是 `Claude Code CLI`
- 认证与计费必须走 `OpenAI subscription`

## 3. 已验证事实

### 3.1 Claude 入口面

- Claude Code 可通过 `ANTHROPIC_BASE_URL` 指向自定义网关
- Claude Code 网关必须提供 `POST /v1/messages` 和 `POST /v1/messages/count_tokens`
- Claude Code 会发送 Anthropic 风格头和 Anthropic 风格请求体

证据：

- [研究总稿第 3 节与第 4 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:28)

### 3.2 Codex 订阅登录态

- `codex` 支持 ChatGPT 登录
- 当前机器已经是 ChatGPT 登录态

证据：

- [研究总稿第 3 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:32)
- [研究总稿 Appendix A.2](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:275)

### 3.3 方案三的主推理面

- 方案三的主推理面是 `openai_base_url` 下的 `/responses`
- 当前默认真实远端已验证为 `https://chatgpt.com/backend-api/codex/responses`
- 当前证据不支持把 `/wham/tasks` 当成主推理面

证据：

- [研究总稿第 3 节；`openai_base_url` 与 `/responses`](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:34)
- [研究总稿 Evidence Ledger；默认真实远端](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:38)
- [研究总稿第 3 节；任务面不是主推理面](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:38)

### 3.4 方案三的辅助产品面

- `chatgpt_base_url` 管理的是 ChatGPT/backend 产品面请求
- 已捕获的路径包括：
  - `/backend-api/plugins/list`
  - `/backend-api/plugins/featured`
  - `/backend-api/codex/analytics-events/events`

证据：

- [研究总稿第 3 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:33)

### 3.5 上游认证形状

- 在 ChatGPT 登录态下，`/responses` 和 `/backend-api/...` 都携带：
  - `Authorization: Bearer ...`
  - `chatgpt-account-id`

证据：

- [研究总稿第 3 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:35)
- [研究总稿 Appendix A.6](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:325)

### 3.6 当前已捕获的流式和压缩特征

- `codex exec` 在 `/responses` 上先尝试 websocket
- websocket 失败后会回落到 HTTP `/responses`
- HTTP 请求当前已观测到：
  - `accept: text/event-stream`
  - `content-type: application/json`
  - `content-encoding: zstd`

证据：

- [研究总稿 Appendix A.6](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:333)
- [研究总稿第 8 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:204)

### 3.7 当前单轮文本路径的 HTTP-only 可行性

- 当前 `codex-cli 0.121.0`
- 当前 `codex exec --json`
- 当前单轮文本回复路径
- 当前 `features.apps=false`

在这个范围内，已验证：

- websocket `GET /responses` 连续 `404` 不会阻止完成回复
- 只要后续 `POST /responses` 返回被客户端接受的 SSE 事件序列，当前路径就会完成
- 当前成功输出已观测到：
  - `item.completed`
  - `turn.completed`

证据：

- [研究总稿 Evidence Ledger；HTTP fallback 成功](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:36)
- [研究总稿 Appendix A.7](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:342)

### 3.8 当前已解开的 `/responses` 请求骨架

对一条真实 `POST /responses` 请求体做 zstd 解压后，当前样本已验证：

- 顶层字段包括：
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
- 当前样本值包括：
  - `model: "gpt-5.4"`
  - `stream: true`
  - `store: false`
  - `tool_choice: "auto"`
  - `parallel_tool_calls: true`
  - `reasoning.effort: "xhigh"`
  - `include: ["reasoning.encrypted_content"]`

证据：

- [研究总稿 Evidence Ledger；zstd 请求骨架](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:37)
- [研究总稿 Appendix A.7](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:342)

### 3.9 Public Responses API 直转发当前不可用

在当前机器和当前登录态下，已验证：

- 把捕获到的 `/responses` 请求
- 连同 Bearer 与 `chatgpt-account-id`
- 直接转发到 `https://api.openai.com/v1/responses`

会得到：

- `401 Unauthorized`
- 错误正文明确写 `Missing scopes: api.responses.write`

证据：

- [研究总稿 Evidence Ledger；public API scope 拒绝](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:39)
- [09-real-upstream-capture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/09-real-upstream-capture.md)

### 3.10 真实上游成功样本已经拿到

在当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- 单轮文本回复路径
- websocket `404` 后走 HTTP

已验证：

- 转发到 `https://chatgpt.com/backend-api/codex/responses` 时
- 上游返回 `200`
- `codex exec` 完成并输出最终消息

证据：

- [研究总稿 Evidence Ledger；真实远端成功样本](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:40)
- [09-real-upstream-capture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/09-real-upstream-capture.md)

### 3.11 当前文本路径的必需字段集合已经收敛

在当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- 单轮文本回复路径
- `features.apps=false`
- websocket `404` 后走 HTTP `/responses`

已验证：

- 真实上游样本里的 reasoning item、`sequence_number`、`annotations`、`logprobs`、`obfuscation`、多余 response 级字段
- 在当前路径都不是必需字段
- 把真实样本裁到 [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md) 的最小契约后，`codex exec` 仍得到 `item.completed` 与 `turn.completed`

证据：

- [09-real-upstream-capture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/09-real-upstream-capture.md)
- [研究总稿 Appendix A.11](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.12 Claude function tools 的声明层重写已被真实远端接受

在当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- 单轮文本回复路径
- websocket `404` 后走 HTTP
- 以真实 `/responses` 成功请求为底稿

已验证：

- 把 `tools` 数组替换成从 `claude` 样本转换来的 `3` 个 function tools 后，真实远端仍返回成功
- 把 `tools` 数组替换成从默认 `claude` 样本转换来的 `55` 个 function tools 后，真实远端仍返回成功
- 当前转换规则是：
  - `type: "function"`
  - `name`
  - `description`
  - `parameters = input_schema`
  - `strict: false`

当前含义：

- 方案三的函数工具声明层改写已经有真实远端接受性证据
- 这不是 tool call / tool result 回合层已经跑通的结论

证据：

- [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)
- [研究总稿 Appendix A.13](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.13 `Bash` 的 tool call / tool result 往返已被真实远端接受

在当前范围：

- `claude`
- 当前 `3` 个 function tools
- 默认 `claude` 抓到的 `55` 个 function tools
- 第一段强制 `Bash`
- 第二段 `tool_output = "success"`
- websocket `404` 后走 HTTP

已验证：

- 第一段真实远端返回了 `name = "Bash"` 的 `function_call`
- 第一段参数完成事件当前样本是：
  - `{"command":"true","description":"Run no-op command"}`
- 第二段把 `reasoning + function_call + function_call_output` 送回真实远端后
- 真实远端返回了普通 assistant message
- 当前已拿到两条第二段最终文本：
  - `Called \`Bash\` once with a minimal valid no-op command: \`true\`.`
  - `Ran a minimal Bash command successfully.`
- 两条路径里的 `codex exec` 最终都得到：
  - `item.completed`
  - `turn.completed`

当前含义：

- 方案三的工具回合层不再是纯猜测；当前 `Bash` 路径已经在两种函数工具集环境下闭环
- 未解决范围已经收窄到：
  - 默认 `claude` 里的其它具体工具实例
  - `advisor_20260301`

证据：

- [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)
- [研究总稿 Appendix A.14](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)
- [研究总稿 Appendix A.15](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.14 代表性函数家族与补充工具家族的 tool call / tool result 往返已被真实远端接受

在当前范围：

- 默认 `claude` 抓到的 `55` 个 function tools
- 第一段强制单个函数工具
- 第二段 `tool_output = "success"`
- websocket `404` 后走 HTTP

已验证的代表性函数家族：

- `WebSearch`
  - 第一段参数：`{"query":"AI"}`
  - 第二段最终文本：
    - `WebSearch was called with the minimal valid argument set: \`query: "AI"\`.`
- `Agent`
  - 第一段参数：
    - `{"description":"Minimal agent call","prompt":"No task beyond confirming this invocation. Reply briefly."}`
  - 第二段最终文本：
    - `Invocation completed.`
- `Read`
  - 第一段参数：
    - `{"file_path":"/etc/hosts"}`
  - 第二段最终文本：
    - `Called \`Read\` once with \`file_path: /etc/hosts\`.`
- `Edit`
  - 第一段参数：
    - `{"file_path":"/tmp/x","old_string":"a","new_string":"b"}`
  - 第二段最终文本：
    - `` `Edit` was called with minimal arguments. ``
- `Write`
  - 第一段参数：
    - `{"file_path":"/tmp/a","content":""}`
  - 第二段结果：
    - `item.completed`
    - `turn.completed`
- `TodoWrite`
  - 第一段参数：
    - `{"todos":[]}`
  - 第二段最终文本：
    - `Completed.`
- `AskUserQuestion`
  - 第一段参数：
    - `{"questions":[{"question":"Which option do you prefer?","header":"Choice","options":[{"label":"Option 1","description":"Select the first option."},{"label":"Option 2","description":"Select the second option."}],"multiSelect":false}],"metadata":{"source":"developer"}}`
  - 第二段结果：
    - `item.completed`
    - `turn.completed`
- `mcp__claude_ai_Google_Drive__authenticate`
  - 第一段参数：
    - `{}`
  - 第二段最终文本：
    - `Google Drive is already authenticated in this session. The Drive MCP tools should now be available.`

这些路径里的 `codex exec` 最终都得到：

- `item.completed`
- `turn.completed`

当前含义：

- 方案三的工具回合层已经覆盖了代表性函数家族，不再只是一条 `Bash` 样本
- 当前剩余边界已经收窄到：
  - 更深的参数语义
  - 未来新增工具实例，而不是当前家族级或实例级可行性

证据：

- [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)
- [研究总稿 Appendix A.16](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.15 raw `advisor_20260301` passthrough 会在第一段 `/responses` 被真实远端拒绝

在当前范围：

- 默认 `claude` 抓到的真实工具样本包含：
  - `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-4-7"}`
- 本地两段代理把这个对象原样追加到改写后的 `tools` 数组
- 第一段仍强制 `Bash`
- websocket `404` 后走 HTTP

已验证：

- 第一段 `/responses` 请求直接返回：
  - `400 Bad Request`
- 错误体当前样本是：
  - `{"detail":"Unsupported tool type: advisor_20260301"}`
- 这次请求没有进入第二段 `function_call_output` 往返
- `codex exec` 最终得到：
  - `turn.failed`

当前含义：

- 对当前观测路径，Claude 抓到的 raw `advisor_20260301` 形状不能直接透传到订阅上游
- `advisor_20260301` 的问题已经从“是否能 raw passthrough”收敛成“如何保留 Anthropic server-side 语义并在 `/responses` 侧桥接”

证据：

- [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)
- [研究总稿 Appendix A.17](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.16 官方 `Advisor tool` 契约已经确认

Anthropic 官方 `Advisor tool` 文档当前已明确：

- `advisor` 的请求定义就是当前捕获到的：
  - `{"type":"advisor_20260301","name":"advisor","model":"..."}`
- 这是 server-side tool，不走客户端 `tool_result` 往返
- 执行器调用时，响应内容里会出现：
  - `server_tool_use`
  - `advisor_tool_result`
- 这两个 block 都发生在同一个 `/v1/messages` 请求内
- 多轮续回时，必须把 `advisor_tool_result` 一起带回；否则会 `400`

当前含义：

- `advisor` 不再是“无公开契约”的未知项
- 方案三要保的不是 raw passthrough，而是 Anthropic 侧这组 server-side block 语义

证据：

- [11-advisor-bridge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/11-advisor-bridge.md)

### 3.17 真实 `claude` 已接受 `server_tool_use + advisor_tool_result`，并在续轮原样回传

本机本地 mock 验证当前已确认：

- 第 1 个 `/v1/messages` 请求是标题生成请求，不含工具
- 第 2 个请求才是主请求，包含 `advisor_20260301`
- 当本地 mock 在主请求的 SSE 里返回：
  - `text`
  - `server_tool_use`
  - `advisor_tool_result`
  - `text`
- `claude` 正常完成，并输出：
  - `Advisor consulted. Final answer from the first turn.`
- 用同一 `session_id` 续轮后：
  - Claude 的第 3 个请求会把上一轮 assistant content 中的
    - `server_tool_use`
    - `advisor_tool_result`
    原样带回

当前含义：

- 方案三在 Anthropic 入口面保留 advisor 语义是可行的
- 不需要把 advisor 降成客户端 `tool_result` 回合

证据：

- [11-advisor-bridge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/11-advisor-bridge.md)

### 3.18 `/responses` synthetic advisor bridge 已验证成功

当前已验证两条桥接样本：

1. `gpt-5.4 -> gpt-5.4 advisor`
2. `gpt-5.3-codex -> gpt-5.4 advisor`

桥接方式当前样本是：

- 不把 raw `advisor_20260301` 透传给 `/responses`
- 改为注入一个零参数 function：
  - `name = "advisor"`
- 第一段强制上游调用这个 synthetic advisor function
- 本地收到真实 `function_call(name="advisor")` 后，再发起一次真实 `/responses` 子调用拿建议文本
- 第三段把该建议文本作为 `function_call_output` 送回主请求

当前结果：

- 两条样本都得到：
  - `item.completed`
  - `turn.completed`
- 当前样本的 advisor 子调用文本已经落盘

当前含义：

- `advisor` 的替代映射已经不再停留在设计阶段
- 对方案三，`advisor` 当前已有一条被真实订阅上游接受的 bridge 路径

证据：

- [11-advisor-bridge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/11-advisor-bridge.md)

### 3.19 当前 ChatGPT 订阅面已验证可用模型集合

对 `https://chatgpt.com/backend-api/codex/responses` 的最小写请求，当前已验证：

- 可用：
- `gpt-5.4`
- `gpt-5.4-mini`
- `gpt-5.3-codex`
- 不可用：
- `gpt-5.2-codex`
- `gpt-5.1-codex-max`

### 3.20 HTTP-only 已覆盖当前非交互多轮路径

当前已验证两条透明转发样本：

1. `Reply exactly FIRST.` -> `Reply exactly SECOND.`
2. `Reply exactly ALPHA.` -> `Read /etc/hosts and reply with only the first token.`

这两条会话都满足：

- websocket `GET /responses` 连续 `404`
- 真实远端仍通过 HTTP `POST /responses` 完成会话
- `codex exec` / `codex exec resume` 最终都得到：
  - `item.completed`
  - `turn.completed`

第二条会话还额外验证：

- 续轮第一段返回真实 `function_call`
  - `name = "exec_command"`
- 客户端随后通过第二个 HTTP `POST /responses` 送回：
  - `reasoning`
  - `function_call`
  - `function_call_output`
- 最终 assistant 文本是：
  - `##`

当前样本还确认：

- 续轮请求当前没有设置 `previous_response_id`
- 当前续轮样本通过扩展 `input` 历史继续会话

当前含义：

- `V-09` 对当前非交互 CLI 路径已经收敛
- 当前 HTTP-only 覆盖到：
  - 单轮文本
  - 单轮工具回合
  - 多轮文本
  - 多轮续轮里的 native tool path
- 剩余未知收窄到：
  - 交互 TUI
  - `features.apps=true`
  - 其他未验证 CLI 入口

其中当前错误体已明确写出：

- `The 'gpt-5.2-codex' model is not supported when using Codex with a ChatGPT account.`
- `The 'gpt-5.1-codex-max' model is not supported when using Codex with a ChatGPT account.`

当前含义：

- 方案三确实存在“执行器模型”和“advisor 子调用模型”做分工的空间
- 当前最强、且已被官方模型页描述为 `Best intelligence at scale` 的模型是 `gpt-5.4`
- 当前已验证可跑的一组“执行器 / advisor”分工样本是：
  - `gpt-5.3-codex -> gpt-5.4`

证据：

- [11-advisor-bridge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/11-advisor-bridge.md)

### 3.21 当前错误兼容矩阵已经形成第一版

当前范围：

- `codex-cli 0.121.0`
- `claude 2.1.114`
- `codex exec --json`
- `claude`
- 本地 loopback probe

已验证：

- `/responses` -> `codex exec`
  - `400` 会把服务端 JSON 文本原样放进 `error.message`
  - `500` 不保留服务端 body；当前样本被改写成固定文案：
    - `We're currently experiencing high demand, which may cause temporary errors.`
  - 畸形 SSE 与断流都会收敛成：
    - `stream disconnected before completion: stream closed before response.completed`
- `/v1/messages` -> `claude`
  - `400` 直接打印：
    - `API Error: 400 {...}`
  - `500` 当前样本表现成内部重试；在一个 `15s` time-bounded clean sample 里，终端没有产生可见错误文本，但服务端观测到 `10` 个 `POST /v1/messages`
  - 畸形 SSE 会先打印：
    - `Could not parse message into JSON: {not-json}`
    随后落到：
    - `undefined is not an object (evaluating '_.input_tokens')`
  - 半截 SSE 当前样本直接落到：
    - `undefined is not an object (evaluating '_.input_tokens')`

当前含义：

- 方案三需要把 Anthropic 边和 `/responses` 边当成两套错误外观来处理
- 当前 `/responses` 的 `400` 和 `500` 不能共用同一类错误翻译
- 当前 Claude 边的流式异常不能简单等同于 HTTP 错误；它会表现成解析错误或内部空值错误

证据：

- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)

### 3.22 当前非交互主路径不依赖已观测 sidecar 请求

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `features.apps=false`
- `/responses` 真实转发成功

已验证：

- 当以下 sidecar 请求统一返回 `404` 时：
  - `/backend-api/plugins/list`
  - `/backend-api/plugins/featured`
  - `/backend-api/codex/analytics-events/events`
  主路径仍得到：
  - `item.completed = SIDECAR`
  - `turn.completed`
- 当同一组 sidecar 请求统一返回 `500` 时：
  - 主路径仍得到：
    - `item.completed = SIDECAR500`
    - `turn.completed`

当前含义：

- 当前已观测到的 sidecar 请求不是当前非交互主路径的 hard dependency
- 方案三当前可以把 `/responses` 视为主链路必需出口
- `/backend-api/plugins/*` 与 `/backend-api/codex/analytics-events/events` 当前只属于旁路产品面

证据：

- [13-sidecar-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/13-sidecar-dependency-v1.md)

### 3.23 当前已测 Claude 路径都没有触发 `/v1/messages/count_tokens`

当前范围：

- `claude 2.1.114`
- `claude 2.1.116`
- `claude`
- `claude`
- `claude` 首轮 + `-r` 续轮
- 交互 TTY `claude --bare`
- 默认交互 TTY `claude`
- `claude --continue`
- 默认 `claude` 的真实 tool roundtrip
- `claude`
- 本地 `/v1/messages` loopback success probe

已验证：

- `claude`
  - 当前样本观测到 `2` 条 `POST /v1/messages`
  - `POST /v1/messages/count_tokens = 0`
- `claude`
  - 当前样本观测到 `1` 条 `POST /v1/messages`
  - `POST /v1/messages/count_tokens = 0`
- `claude` 首轮 + `-r` 续轮
  - 当前样本观测到 `3` 条 `POST /v1/messages`
  - `POST /v1/messages/count_tokens = 0`
- 交互 TTY `claude --bare`
  - 当前样本观测到 `2` 条 `POST /v1/messages`
  - `POST /v1/messages/count_tokens = 0`
- 默认交互 TTY `claude`
  - 当前样本观测到 `2` 条 `POST /v1/messages`
  - `POST /v1/messages/count_tokens = 0`
- `claude --continue`
  - 当前样本观测到 `2` 条 `POST /v1/messages`
  - `POST /v1/messages/count_tokens = 0`
- 默认 `claude` 的真实 tool roundtrip
  - 当前样本观测到 `2` 条 `POST /v1/messages`
  - `POST /v1/messages/count_tokens = 0`
- `claude`
  - 不带 `--verbose` 时，CLI 直接报错并退出
  - 带 `--verbose` 的有效调用里，当前样本观测到 `1` 条 `POST /v1/messages`
  - `POST /v1/messages/count_tokens = 0`
- 官方文档仍要求网关提供：
  - `POST /v1/messages/count_tokens`

当前含义：

- 方案三必须实现 `POST /v1/messages/count_tokens`
- 但在当前已测 Claude 路径里，不能把它写成启动前置依赖或每轮必经请求

证据：

- [14-count-tokens-observation-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/14-count-tokens-observation-v1.md)

### 3.24 当前交互 `features.apps=true` 首轮文本路径也可走 HTTP-only

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 首轮文本回复路径
- `features.apps=true`
- websocket `GET /responses` 连续 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

已验证：

- 当前客户端会先多次尝试 websocket `GET /responses`
- websocket 全部 `404` 后，仍继续发起 HTTP `POST /responses`
- 当前样本的 HTTP `POST /responses` 返回 `200`
- 交互终端最终输出：
  - `APPSHTTP`

当前含义：

- HTTP-only 的当前覆盖范围已经从非交互路径扩到交互 `features.apps=true` 首轮文本路径
- 这还不是更深 apps 回合或其他 CLI 入口都已覆盖的结论

证据：

- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)

### 3.25 当前交互 `features.apps=true` 首轮文本路径在 sidecar `404` 与 `500` 下仍能完成

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 首轮文本回复路径
- `features.apps=true`
- `/responses` 真实转发成功

已验证：

- 当前已观测到的 sidecar 请求在统一 `404` 下仍不阻止当前路径完成：
  - `/backend-api/plugins/featured?platform=codex`
  - `/backend-api/plugins/list`
  - `/backend-api/wham/apps`
  - `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
  - `/backend-api/wham/usage`
  - `/backend-api/codex/analytics-events/events`
  - 当前终端最终输出：
    - `APPS404`
- 当前已观测到的 sidecar 请求在统一 `500` 下仍不阻止当前路径完成：
  - `/backend-api/plugins/list`
  - `/backend-api/plugins/featured?platform=codex`
  - `/backend-api/wham/apps`
  - `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
  - `/backend-api/codex/analytics-events/events`
  - 当前终端会额外出现：
    - `MCP client for \`codex_apps\` failed to start`
    - `MCP startup incomplete (failed: codex_apps)`
  - 当前终端最终输出：
    - `APPS500`

当前含义：

- 当前已观测 sidecar 请求不是交互 `features.apps=true` 首轮文本路径的硬依赖
- sidecar `500` 在这条路径里会额外暴露 `codex_apps` MCP 启动失败警告
- 这还不是“所有 apps 功能都不依赖 sidecar”的结论

证据：

- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)

### 3.26 当前交互 `features.apps=true` 首轮文本路径的 `/responses` `400` 与 `500` 错误外观已验证

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 首轮文本回复路径
- `features.apps=true`
- 本地 `/responses` loopback probe

已验证：

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

- 交互 `features.apps=true` 首轮文本路径的 `/responses` `400` 与 `500` 不再属于未知面
- 当前交互路径的 `400` 与 `500` 也不能共用同一类错误翻译
- 这还不包含同一路径的畸形 SSE、断流和更深回合

证据：

- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)

### 3.27 当前四份 `/responses` 首轮请求样本的顶层骨架一致，差异集中在工具清单

当前范围：

- `codex-cli 0.121.0`
- 当前四份已解压请求样本：
  - 非交互路径：
    - `/tmp/responses-forward-8797/008-request.json`
    - `/tmp/responses-forward-8797/016-request.json`
  - 交互 `features.apps=true` 首轮文本路径：
    - `/tmp/codex-apps-http-only-8806/008-request.json`
    - `/tmp/codex-interactive-errors-8821/008-request.json`

已验证：

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
    - 当前唯一 `namespace`：
      - `mcp__pencil__`
  - 交互 `features.apps=true` 两份样本：
    - `tools_len = 21`
    - 类型分布：
      - `function = 13`
      - `custom = 1`
      - `web_search = 1`
      - `namespace = 6`
    - 当前额外 `namespace`：
      - `mcp__codex_apps__adobe_photoshop`
      - `mcp__codex_apps__figma`
      - `mcp__codex_apps__github`
      - `mcp__codex_apps__gmail`
      - `mcp__codex_apps__notion__legacy`
      - `mcp__pencil__`

当前含义：

- 当前四份首轮请求样本的主骨架已经稳定到可写进正式文档
- 当前已验证的结构差异不是顶层 payload，而是工具清单，尤其是 `features.apps=true` 引入的 `namespace` 工具
- 这还不是更深回合、续轮或工具回合都保持同一骨架的结论

证据：

- [16-request-shape-comparison-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/16-request-shape-comparison-v1.md)

### 3.28 当前非交互 `features.apps=true` 的 `codex exec/exec resume` 文本路径可走 HTTP-only

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `codex exec resume --json`
- `features.apps=true`
- websocket `GET /responses` 连续 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

已验证：

- 首轮命令 `Reply exactly APPSRESUME1.` 成功完成，并输出：
  - `APPSRESUME1`
- 续轮命令 `Reply exactly APPSRESUME2.` 成功完成，并输出：
  - `APPSRESUME2`
- 两轮都得到：
  - `item.completed`
  - `turn.completed`
- paired forward log 当前还确认：
  - `POST /responses = 2`
  - 第 1 个请求：
    - `input_len = 3`
    - `tools_len = 21`
  - 第 2 个请求：
    - `input_len = 6`
    - `tools_len = 21`

当前含义：

- HTTP-only 的当前覆盖范围已经扩到非交互 `features.apps=true` 的 `exec/exec resume` 文本路径
- 当前续轮 apps 文本路径已经有直接请求骨架证据，不再只停留在首轮样本
- 这还不是更深 apps 工具回合或交互 apps 更深回合都已覆盖的结论

证据：

- [17-exec-apps-resume-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/17-exec-apps-resume-coverage-v1.md)

### 3.35 当前真实 GitHub app 业务动作在 forward-only 对照下成功，但在 sidecar `404` 与 `500` 下都会失败

当前范围：

- `codex-cli 0.121.0`
- 非交互 `codex exec --json --enable apps`
- 当前真实业务动作：
  - `github_get_user_login`
- prompt 固定为：
  - `Use the GitHub app to tell me the authenticated GitHub login. Output only the login.`

已验证：

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
  - 终端仍完成同一工具调用
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
  - 当前已观测 sidecar 路径包括：
    - `/backend-api/plugins/featured?platform=codex`
    - `/backend-api/plugins/list`
    - `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
    - `/backend-api/wham/apps`
    - `/backend-api/codex/analytics-events/events`
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
  - 当前已观测 sidecar 路径与 `404` 样本相同
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
- 这还不代表所有 app 工具家族或交互 TUI apps 业务动作都已有同样结论

证据：

- [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)

### 3.36 当前交互 `features.apps=true` 同会话第三轮文本路径也可走 HTTP-only

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen --enable apps`
- 同一会话连续三轮文本提示
- websocket `GET /responses` 连续 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

已验证：

- transcript 里记录到三轮文本结果：
  - `APPROUND3A`
  - `APPROUND3B`
  - `APPROUND3C`
- paired forward log 里出现：
  - `GET /responses = 7`
  - `POST /responses = 5`
  - `status 200 = 5`
- 当前这组 `5` 次 `POST /responses` 同时覆盖：
  - 三轮文本回复
  - 同会话后续一条 GitHub app 工具往返

当前含义：

- HTTP-only 的当前交互覆盖范围已经从同会话第二轮继续扩到第三轮文本路径
- 这还不是“任意更深交互 apps 回合都已覆盖”的结论

证据：

- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)

### 3.37 当前交互 GitHub app 业务动作在 forward-only 下成功，但在 sidecar `404` 与 `500` 下都会失败

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen --enable apps`
- 当前真实业务动作：
  - `github_get_profile`
- prompt 固定为：
  - `Use the GitHub app to tell me the authenticated GitHub numeric id. Output only the digits.`

已验证：

- forward-only 对照样本：
  - `openai_base_url` 指向本地 `/responses` 透明转发
  - transcript 出现真实工具调用：
    - `Called codex_apps.github_get_profile({})`
  - 工具结果里出现：
    - `"id": "99057954"`
  - transcript 最终输出：
    - `99057954`
- sidecar `404` 样本：
  - transcript 启动期出现：
    - `MCP client for \`codex_apps\` failed to start`
    - `MCP startup incomplete (failed: codex_apps)`
  - blocker log 里当前 sidecar 请求都带：
    - `"mode": "404"`
  - paired forward log 里仍出现：
    - `GET /responses = 7`
    - `POST /responses = 1`
  - transcript 工具错误文本包括：
    - `tool call error: failed to get client`
    - `MCP startup failed: handshaking with MCP server failed`
    - `error decoding response body`
- sidecar `500` 样本：
  - transcript 启动期同样出现：
    - `MCP client for \`codex_apps\` failed to start`
    - `MCP startup incomplete (failed: codex_apps)`
  - blocker log 里当前 sidecar 请求都带：
    - `"mode": "500"`
  - paired forward log 里仍出现：
    - `GET /responses = 7`
    - `POST /responses = 1`
  - transcript 工具错误文本同样包括：
    - `tool call error: failed to get client`
    - `MCP startup failed: handshaking with MCP server failed`
    - `error decoding response body`

当前含义：

- 当前交互 GitHub app 业务动作在 forward-only 对照下成功，排除了“交互 TUI + 本地 `/responses` 转发”本身会把它打坏
- 当前交互 GitHub app 业务动作在 sidecar `404` 与 `500` 下都会失败
- 因此，对至少一个真实 apps 工具业务动作，`/backend-api/...` sidecar 当前在非交互与交互路径里都是 hard dependency
- 这还不代表其他 app 工具家族都有同样结论

证据：

- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)
- [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)

### 3.38 当前 Gmail app 业务动作也已出现同类 sidecar 依赖

当前范围：

- `codex-cli 0.121.0`
- 非交互 `codex exec --json --enable apps`
- prompt 固定为：
  - `Use the Gmail app to tell me the authenticated Gmail address. Output only the address.`

已验证：

- forward-only 对照样本：
  - `openai_base_url` 指向本地 `/responses` 透明转发
  - 终端出现真实工具调用：
    - `tool = gmail_get_profile`
  - 工具结果里出现：
    - `"email":"norvynzhang@gmail.com"`
  - 最终 assistant 输出：
    - `norvynzhang@gmail.com`
  - forward log 里出现：
    - `GET /responses = 7`
    - `POST /responses = 2`
    - `status 200 = 2`
- sidecar `404` 样本：
  - blocker log 里当前 sidecar 请求都带：
    - `"mode": "404"`
  - `/responses` 主出口仍然健康：
    - `GET /responses = 7`
    - `POST /responses = 5`
    - `status 200 = 5`
  - 第一个真实工具调用失败：
    - `tool = gmail_get_profile`
    - `tool call error: failed to get client`
  - agent 继续探测第二个真实工具调用：
    - `tool = gmail_list_labels`
    - `tool call error: failed to get client`
  - 最终 assistant 输出：
    - `Gmail connector unavailable`

当前含义：

- 当前 sidecar hard dependency 已经从 GitHub 扩到第二个 app 家族
- 这还不代表所有 app 工具家族都有同样结论

证据：

- [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)

### 3.39 当前 Gmail app 业务动作在 sidecar `500` 下也失败，而且会进入本地回退搜索

当前范围：

- `codex-cli 0.121.0`
- 非交互 `codex exec --json --enable apps`
- prompt 固定为：
  - `Use the Gmail app to tell me the authenticated Gmail address. Output only the address.`

已验证：

- sidecar `500` 样本：
  - blocker log 里当前 sidecar 请求都带：
    - `"mode": "500"`
  - `/responses` 主出口仍然健康：
    - `GET /responses = 7`
    - `POST /responses = 6`
    - `status 200 = 6`
  - 两次真实工具调用都失败：
    - `tool = gmail_get_profile`
    - `tool call error: failed to get client`
  - 终端随后进入本地回退搜索：
    - `ls/find ~/.codex`
    - `rg` 搜索 gmail 相关配置
    - 打开 `~/.codex/auth.json`
    - 打开 `state_5.sqlite`
    - 打开 `logs_2.sqlite`

当前含义：

- Gmail 家族在 sidecar `500` 下也失败，不是只在 `404` 下失败
- 当前 `500` 外观比 `404` 更重；它会进入本地回退搜索

证据：

- [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)

### 3.40 当前 Notion app 业务动作也已出现同类 sidecar 依赖

当前范围：

- `codex-cli 0.121.0`
- 非交互 `codex exec --json --enable apps`
- prompt 固定为：
  - `Use the Notion app to search Notion users for Norvyn Zhang and return only the exact name. If the tool rejects query_type=users, retry with query_type=user.`

已验证：

- forward-only 对照样本：
  - 第一段 `query_type=users` 因 schema 校验被拒
  - agent 改成 `query_type=user` 后成功
  - 最终 assistant 输出：
    - `Norvyn Zhang`
- sidecar `404` 样本：
  - `/responses` 主出口仍然健康：
    - `GET /responses = 7`
    - `POST /responses = 4`
    - `status 200 = 4`
  - 两次真实工具调用都失败：
    - `tool = notion (legacy)_search`
    - `query_type = "users"`
    - `query_type = "user"`
  - 最终 assistant 输出：
    - `⚠️ 无法验证: Notion app MCP 启动握手失败；\`query_type=users\` 与 \`query_type=user\` 两次请求都未成功执行。`
- sidecar `500` 样本：
  - `/responses` 主出口仍然健康：
    - `GET /responses = 7`
    - `POST /responses = 5`
    - `status 200 = 5`
  - 三次真实工具调用都失败：
    - `query_type = "users"`
    - `query_type = "users"` 重试
    - `query_type = "user"`
  - 最终 assistant 输出：
    - `⚠️ 无法验证：Notion app 在 \`query_type=users\` 和 \`query_type=user\` 两次调用中都在 MCP 握手阶段失败，未进入查询。`

当前含义：

- 当前 sidecar hard dependency 已经扩到第三个 app 家族
- 当前 Notion 家族的失败点稳定落在 MCP 握手阶段

证据：

- [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)

### 3.30 当前交互 `features.apps=true` 首轮文本路径的 `/responses` 畸形 SSE 与断流外观已验证

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 首轮文本回复路径
- `features.apps=true`
- 本地 `/responses` loopback probe

已验证：

- 当前 `malformed-sse`
  - 终端最终输出：
    - `stream disconnected before completion: stream closed before response.completed`
  - 当前样本里观测到：
    - `POST /responses = 6`
- 当前 `truncated-sse`
  - 终端最终输出：
    - `stream disconnected before completion: stream closed before response.completed`
  - 当前样本里观测到：
    - `POST /responses = 6`

当前含义：

- 交互 `features.apps=true` 首轮文本路径的 `/responses` 畸形 SSE 与显式断流不再属于未知面
- 当前这条交互路径里，畸形 SSE 与显式断流当前会收敛到同一类“未完整结束的流”文案
- 这还不包含更深交互回合、apps 工具回合或 Claude 默认交互式工具路径

证据：

- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)

### 3.31 当前交互 `features.apps=true` 同会话第二轮文本路径也可走 HTTP-only

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 当前首轮与同会话第二轮文本回复路径
- `features.apps=true`
- websocket `GET /responses` 连续 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

已验证：

- paired forward log 里出现：
  - `GET /responses = 7`
  - `POST /responses = 2`
  - `200` 响应 = `2`
- 同一交互会话的两轮终端输出在验证 run 中记录为：
  - `APPDEEP1`
  - `APPDEEP2`

当前含义：

- HTTP-only 的当前覆盖范围已经从交互 apps 首轮文本路径扩到同会话第二轮文本路径
- 这还不是任意更深交互 apps 回合都已覆盖的结论

证据：

- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)

### 3.32 当前交互 `features.apps=true` 同会话第二轮文本路径在 sidecar `404` 与 `500` 下仍能完成

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 当前首轮与同会话第二轮文本回复路径
- `features.apps=true`
- `/responses` 真实转发成功

已验证：

- 当前已观测到的 sidecar 请求在统一 `404` 下仍不阻止当前路径完成
  - paired forward log 里出现：
    - `GET /responses = 7`
    - `POST /responses = 2`
    - `200` 响应 = `2`
  - 同一交互会话的两轮终端输出在验证 run 中记录为：
    - `APPDEEP4041`
    - `APPDEEP4042`
- 当前已观测到的 sidecar 请求在统一 `500` 下仍不阻止当前路径完成
  - paired forward log 里出现：
    - `GET /responses = 7`
    - `POST /responses = 2`
    - `200` 响应 = `2`
  - 当前终端会额外出现：
    - `MCP client for \`codex_apps\` failed to start`
    - `MCP startup incomplete (failed: codex_apps)`
  - 同一交互会话的两轮终端输出在验证 run 中记录为：
    - `APPDEEP5001`
    - `APPDEEP5002`

当前含义：

- 当前已观测 sidecar 请求不是交互 `features.apps=true` 同会话第二轮文本路径的硬依赖
- sidecar `500` 在这条路径里仍会额外暴露 `codex_apps` MCP 启动失败警告
- 这还不是“apps 工具业务动作也不依赖 sidecar”的结论

证据：

- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)

### 3.33 当前交互 `features.apps=true` 同会话第二轮文本路径的 `/responses` `400 / 500 / 畸形 SSE / 断流` 外观已验证

当前范围：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- `features.apps=true`
- 同一交互会话先完成 1 轮文本回复
- 错误只注入第 `2` 个 `POST /responses`
- 本地 `/responses` loopback probe

已验证：

- 当前 `400 application/json`
  - 第 2 轮终端最终输出：
    - `{"detail": "forced 400 from local /responses proxy"}`
  - 当前样本里观测到：
    - `POST /responses = 2`
- 当前 `500 application/json`
  - 第 2 轮终端最终输出：
    - `APPERR500B`
  - 当前样本里观测到：
    - `POST /responses = 3`
- 当前 `malformed-sse`
  - 第 2 轮终端先显示：
    - `Reconnecting...`
    - `Stream disconnected before completion: stream closed before response.completed`
  - 随后终端最终输出：
    - `APPERRMALB`
  - 当前样本里观测到：
    - `POST /responses = 3`
- 当前 `truncated-sse`
  - 第 2 轮终端先显示：
    - `Reconnecting...`
    - `Stream disconnected before completion: stream closed before response.completed`
  - 随后终端最终输出：
    - `APPERRTRUNCB`
  - 当前样本里观测到：
    - `POST /responses = 3`

当前含义：

- 交互 `features.apps=true` 同会话第二轮文本路径的错误外观不再属于未知面
- 当前第 2 轮里：
  - `400` 直接终止
  - `500` 会补发并恢复
  - `malformed-sse` 与 `truncated-sse` 都会先显式暴露断流，再补发恢复
- 这还不代表 apps 工具回合或第三轮及以上交互回合有同样行为

证据：

- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)

### 3.34 默认 `claude` tool-use 回合的 `400 / 500 / 畸形 SSE / 断流` 外观已验证

当前范围：

- `claude 2.1.116`
- 默认 `claude`
- 第 `1` 条 `/v1/messages` 固定返回 `Read` tool_use
- 第 `2` 条 `/v1/messages` 起按 probe mode 返回错误
- 本地 `/v1/messages` loopback probe

已验证：

- 当前 `json-400`
  - 终端最终输出：
    - `API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"forced 400 from local tool-roundtrip probe"}}`
  - 当前样本里观测到：
    - `POST /v1/messages = 2`
    - 第 `2` 条请求已带 `tool_result`
- 当前 `json-500`
  - 在一个本地 `30s` time-bounded PTY run 里，终端没有产生可见错误文本
  - 当前样本里观测到：
    - `POST /v1/messages = 8`
    - 第 `2` 条及之后的请求都返回 `500`
    - 第 `2` 条请求已带 `tool_result`
- 当前 `malformed-sse`
  - 终端最终输出：
    - `Could not parse message into JSON: {not-json}`
    - `From chunk: [ "event: content_block_delta", "data: {not-json}" ]`
    - `undefined is not an object (evaluating '_.input_tokens')`
  - 当前样本里观测到：
    - `POST /v1/messages = 3`
    - 第 `2` 条请求已带 `tool_result`
- 当前 `truncated-sse`
  - 终端最终输出：
    - `undefined is not an object (evaluating '_.input_tokens')`
  - 当前样本里观测到：
    - `POST /v1/messages = 3`
    - 第 `2` 条请求已带 `tool_result`

当前含义：

- 默认 `claude` tool-use 回合不再属于错误外观未知面
- 当前 `400` 会直接打印完整 API Error JSON
- 当前 `500` 当前仍表现成内部重试，不能写成“立即返回终端错误”
- 当前畸形 SSE 与半截 SSE 当前都落到解析失败或内部空值错误，不会显示“断流”字样

证据：

- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)

### 3.29 当前非交互 `features.apps=true` 的 `exec/exec resume` 文本路径在 sidecar `404` 与 `500` 下仍能完成

当前范围：

- `codex-cli 0.121.0`
- `codex exec --json`
- `codex exec resume --json`
- `features.apps=true`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 `/backend-api/...` sidecar 请求统一返回 `404` 或统一返回 `500`

已验证：

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
- sidecar 故障当前会暴露 stderr，但不会阻止当前这条主路径完成
- 这还不是 apps 业务动作、交互 apps 更深回合或未来 sidecar 新路径都不受影响的结论

证据：

- [17-exec-apps-resume-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/17-exec-apps-resume-coverage-v1.md)

### 3.35 当前本地 Swift gateway 已完成真实 Claude CLI 路径验证

当前范围：

- 当前仓库里的 `modelbridge-daemon`
- `ANTHROPIC_BASE_URL=http://127.0.0.1:4317`
- 当前机器上的 `claude 2.1.116`

已验证：

- 本地 daemon 当前真实完成：
  - `claude` 文本回复
  - 默认 `claude` 文本回复
  - `Bash` 工具回合
  - `Read` 工具回合
  - `advisor` server-side tool 回合
  - 默认完整工具清单下的 `mcp__plugin_Notion_notion__authenticate` 路径
- `advisor` 首轮后再触发普通 function call 的 bridge 缺口已在当前代码中修复；当前 trace 已显示：
  - `responses_in_advisor_continuation`
  - 后续普通 `function_call`
  - 再下一段 `responses_out_continuation`
- 当前本地 daemon 仍未实现本地 `/backend-api/...` sidecar 模块；在这个前提下，上述 Claude CLI 已验证路径仍可通过本地 `/v1/messages -> /responses` 桥接完成

当前含义：

- 对当前产品形态来说，本地正式 runtime 已不是“只有代码骨架”
- 当前正式代码已经具备真实 Claude CLI 用户路径的运行证据
- 当前 `Write` / `Edit` 的强制 prompt 仍会受模型自行改写路径或工具选择影响；现有 trace 已证明当前 daemon 收到了这两类真实 `function_call`，但这两条 prompt 当前不能当稳定金标准

证据：

- [README.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/README.md)
- `/tmp/modelbridge-trace.jsonl`

## 4. 当前禁止越界项

- 不把 `codex app-server` 写成方案三的主通路
- 不把 `codex mcp-server` 写成方案三的模型后端
- 不把公开 OpenAI API 计费方案写成满足硬约束的路线
- 不把 `/wham/tasks` 写成方案三的主推理面
- 不把“未抓到成功样本”的字段结构写成已知事实

## 5. 当前结论

在现有证据下，方案三的正确表述是：

- 本地实现 `Anthropic-compatible gateway`
- 入口接 Claude Code 的 `/v1/messages` 与 `/v1/messages/count_tokens`
- 本地主出口保持 `/responses` 形状
- 真实远端主出口接 `https://chatgpt.com/backend-api/codex/responses`
- 辅助出口按需接 `/backend-api/...`

这条路线已经被证实存在，当前单轮文本路径的最小响应契约已经收敛，函数工具声明层改写已被真实远端接受，代表性函数家族与补充工具家族的工具回合层都已经闭环；`advisor` 侧现在也已补齐三层证据：官方契约、Claude CLI 接受性、`/responses` synthetic bridge 成功样本。HTTP-only、sidecar 非硬依赖，以及交互 `features.apps=true` 首轮、同会话第二轮、同会话第三轮文本路径和默认 `claude` tool-use 回合的错误外观都已经扩到当前已测路径；当前四份 `/responses` 首轮请求样本的顶层骨架也已确认一致，非交互 `features.apps=true` 的 `exec/exec resume` 文本路径当前也已确认：在 websocket `404` 下仍可走 HTTP-only，在 sidecar `404/500` 下仍能完成。与此同时，当前真实 GitHub app 业务动作已经补到非交互与交互两条样本：forward-only 对照仍成功，但 sidecar `404/500` 都会失败。当前未决范围收敛到其他 app 工具家族、其他交互 apps 业务动作，以及个别工具实例的更深业务语义。
