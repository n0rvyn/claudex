# Claude 入口面

Date: 2026-04-20

## 1. 文档定位

本文件只记录 Claude Code 一侧已经确认的入口要求。

未确认项单独放到文末。

## 2. 已验证入口路径

当前已验证的最小入口集：

- `POST /v1/messages`
- `POST /v1/messages/count_tokens`

来源：

- [研究总稿第 3 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:30)

## 3. 已验证请求头

本机真实探针已观测到以下头：

- `anthropic-beta`
- `anthropic-version`
- `X-Claude-Code-Session-Id`
- `x-api-key`

已知样例：

- `anthropic-version: 2023-06-01`

来源：

- [研究总稿第 4 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:42)

## 4. 已验证请求体形状

本机真实探针已观测到请求体中包含：

- `model`
- `messages`
- `system`
- `tools`
- `thinking`
- `context_management`
- `stream`

其中 `stream` 已观测值为：

- `true`

来源：

- [研究总稿第 4 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:46)

## 4.1 已验证工具样本差异

当前已验证：

- `claude --bare -p` 工具总数是 `4`
  - `Bash`
  - `Edit`
  - `Read`
  - `advisor`
- `claude -p` 工具总数是 `56`
  - 其中 `55` 个是函数工具
  - `1` 个是 `advisor_20260301`

当前含义：

- Claude Code 的工具集会随运行模式变化
- 方案三不能把 `--bare` 样本直接当成正式 CLI 工具全集

来源：

- [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)

## 4.2 已验证 `advisor` 是单请求内的 server-side tool

Anthropic 官方 `Advisor tool` 文档当前已明确：

- 工具定义仍放在请求体 `tools` 数组里：
  - `{"type":"advisor_20260301","name":"advisor","model":"..."}`
- 当模型调用它时，响应内容里出现：
  - `server_tool_use`
  - `advisor_tool_result`
- 这两个 block 都发生在同一个 `/v1/messages` 请求里，不需要客户端再补 `tool_result`
- 后续多轮必须把 `advisor_tool_result` 一起带回

本机真实 `claude --bare -p` 对本地 mock 的验证已经确认：

- CLI 接受带 `server_tool_use + advisor_tool_result` 的 SSE
- 用 `-r <session-id>` 续轮时，Claude 会把上一轮 assistant content 中的这两个 block 原样带回

来源：

- [11-advisor-bridge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/11-advisor-bridge.md)

## 4.3 当前已测 Claude 路径没有触发 `count_tokens`

当前范围：

- `claude 2.1.114`
- `claude 2.1.116`
- `claude --bare -p`
- `claude -p`
- `claude --bare -p` 首轮 + `-r` 续轮
- 交互 TTY `claude --bare`
- 默认交互 TTY `claude`
- `claude -p -c`
- 默认 `claude -p` 的真实 tool roundtrip
- `claude -p --verbose --output-format stream-json`
- 本地 `/v1/messages` loopback success probe

当前已验证：

- 八条已测路径里都没有出现：
  - `POST /v1/messages/count_tokens`
- `claude --bare -p`
  - 当前样本是 `2` 条 `POST /v1/messages`
  - 先 `haiku title`，再 `sonnet main`
- `claude -p`
  - 当前样本是 `1` 条 `POST /v1/messages`
- `claude --bare -p` 首轮 + `-r` 续轮
  - 当前样本合计 `3` 条 `POST /v1/messages`
  - 续轮阶段是 `1` 条 `POST /v1/messages`
- 交互 TTY `claude --bare`
  - 当前样本是 `2` 条 `POST /v1/messages`
- 默认交互 TTY `claude`
  - 当前样本是 `2` 条 `POST /v1/messages`
  - 第 `2` 条请求当前观测到 `tools=33`
- `claude -p -c`
  - 当前样本合计 `2` 条 `POST /v1/messages`
  - `-c` 续轮阶段的请求当前观测到 `messages=3`
- 默认 `claude -p` 的真实 tool roundtrip
  - 当前样本是 `2` 条 `POST /v1/messages`
  - 第 `2` 条请求当前已观测到最后一个 content block 是：
    - `tool_result`
- `claude -p --verbose --output-format stream-json`
  - 不带 `--verbose` 时，CLI 直接报错
  - 带 `--verbose` 的有效调用里，当前样本是 `1` 条 `POST /v1/messages`

当前含义：

- 方案三仍然必须提供 `POST /v1/messages/count_tokens`
- 但在当前已测 Claude 路径里，不能把它写成启动前置依赖或每轮必经请求

来源：

- [14-count-tokens-observation-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/14-count-tokens-observation-v1.md)

## 5. 网关侧必须承担的职责

在当前证据下，本地网关至少要承担：

- 接收 Anthropic 风格请求
- 保留 Claude 会话标识
- 返回 Claude Code 可接受的响应格式
- 提供 `/v1/messages/count_tokens`
- 对 `advisor` 保留 `server_tool_use + advisor_tool_result` 语义
- 在续轮请求里保留并回传 `advisor_tool_result`

## 6. 已验证错误外观

当前范围：

- `claude 2.1.114`
- `claude --bare -p`
- 本地 `/v1/messages` loopback probe

当前已验证：

- `400 application/json`
  - 终端直接输出 `API Error: 400 {...}`
  - 当前 `400` 样本里观测到 `2` 个 `POST /v1/messages`
- `500 application/json`
  - 在本地 `15s` time-bounded run 里，终端没有产生可见错误文本
  - 同一时间窗口内观测到 `10` 个 `POST /v1/messages`
  - 这说明当前 `500` 路径存在内部重试
- `200 text/event-stream` + 非法 JSON chunk
  - 终端会先输出 `Could not parse message into JSON: {not-json}`
  - 最后输出 `undefined is not an object (evaluating '_.input_tokens')`
- `200 text/event-stream` + 提前断流
  - 终端最终输出 `undefined is not an object (evaluating '_.input_tokens')`

当前含义：

- Claude CLI 当前不会把所有错误都稳定映射成同一种终端外观
- 当前 `500` 和当前 SSE 流式异常都不能简单等同于“立即打印服务端错误正文”

来源：

- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)

## 7. 当前不能写死的内容

以下内容还没有单独验证，不能写成协议定论：

- Claude Code 在 tool-use 回合里的最小响应要求
- Claude Code 是否要求 Anthropic SSE 的某些特定事件顺序
- 未来版本里的 `count_tokens` 触发条件
- Claude 默认 `-p`、交互会话、tool-use 回合里的错误外观

这些内容进入：

- [05-validation-matrix.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/05-validation-matrix.md)
- [06-open-questions.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/06-open-questions.md)
