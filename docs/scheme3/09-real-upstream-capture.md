# 真实上游抓包

Date: 2026-04-20

## 1. 文档定位

本文件只记录真实远端样本。

这里的“真实远端”指当前已抓到的这些路径：

- 默认 ChatGPT 登录态下
- `codex-cli 0.121.0`
- `codex exec --json`
- `codex exec resume --json`
- 单轮文本、多轮文本、以及续轮里的 native tool path

本文件不记录本地 probe 伪造的成功流；那部分单独放在 [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md)。

## 2. 已验证结论

### 2.1 默认远端主机

当前已验证：

- 默认远端主机是 `chatgpt.com:443`

证据：

- 本地 `HTTPS_PROXY` 探针捕获到连续的 `CONNECT chatgpt.com:443`
- 同一次运行里，Codex 错误消息直接打印：
  - `wss://chatgpt.com/backend-api/codex/responses`
  - `https://chatgpt.com/backend-api/codex/responses`

### 2.2 Public Responses API 直转发不可用

当前已验证：

- 把捕获到的 Bearer、`chatgpt-account-id`、zstd body 原样转发到 `https://api.openai.com/v1/responses`
- 上游返回 `401 Unauthorized`
- 错误正文明确写：
  - `Missing scopes: api.responses.write`

这说明：

- 当前机器上的 ChatGPT/Codex 订阅登录态
- 不能直接当成 public Responses API 的可写权限

### 2.3 ChatGPT backend codex responses 可用

当前已验证：

- 把同一条请求转发到 `https://chatgpt.com/backend-api/codex/responses`
- 上游返回 `200`
- 传输是分块流
- `codex exec` 完成回复并输出最终消息

## 3. 请求样本

### 3.1 请求头

当前真实样本已验证：

- `Authorization: Bearer ...`
- `chatgpt-account-id`
- `accept: text/event-stream`
- `content-type: application/json`
- `content-encoding: zstd`

### 3.2 请求骨架

当前真实样本解压后顶层字段包括：

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

当前样本值包括：

- `model: "gpt-5.4"`
- `stream: true`
- `store: false`
- `tool_choice: "auto"`
- `parallel_tool_calls: true`
- `reasoning.effort: "xhigh"`
- `include: ["reasoning.encrypted_content"]`

## 4. 响应样本

### 4.1 真实事件顺序

当前抓到的真实 SSE 事件顺序：

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

### 4.2 与本地最小契约的差异

真实上游比 [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md) 多出这些已验证内容：

- 开头有一对 reasoning item：
  - `response.output_item.added`，`item.type = "reasoning"`
  - `response.output_item.done`，`item.type = "reasoning"`
- reasoning item 包含：
  - `encrypted_content`
  - `summary`
- assistant message item 多了：
  - `phase`
- `response.content_part.added` 的 `part` 多了：
  - `annotations`
  - `logprobs`
- `response.output_text.delta` 多了：
  - `logprobs`
  - `obfuscation`
  - `sequence_number`
- `response.completed` 多了很多响应级字段，例如：
  - `background`
  - `completed_at`
  - `max_output_tokens`
  - `max_tool_calls`
  - `previous_response_id`
  - `prompt_cache_retention`

### 4.3 受控删字段结果

基于这条真实样本，当前已经逐项验证并全部得到 `turn.completed`：

| 模式 | 删除内容 | 结果 |
| --- | --- | --- |
| `baseline` | 不删字段 | `turn.completed` |
| `drop_sequence_number` | 删除事件级与文本事件里的 `sequence_number` | `turn.completed` |
| `drop_reasoning_item` | 删除开头 reasoning item 对 | `turn.completed` |
| `drop_annotations` | 删除 `part.annotations` | `turn.completed` |
| `drop_annotations_logprobs` | 删除 `annotations` 与 `logprobs` | `turn.completed` |
| `drop_obfuscation` | 删除 `response.output_text.delta.obfuscation` | `turn.completed` |
| `drop_response_extras` | 删除一批 response 级扩展字段 | `turn.completed` |
| `drop_all_optional` | 同时删除 sequence / annotations / logprobs / obfuscation / response extras | `turn.completed` |
| `drop_reasoning_and_optional` | 再叠加删除 reasoning item 对 | `turn.completed` |
| `probe_minimal` | 把真实样本裁到 [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md) 的最小契约 | `turn.completed` |

当前结论：

- 对当前 `codex exec --json` 单轮文本路径，真实上游里多出的这些字段都不是必需字段
- 当前文本路径接受的最小 SSE 形状已经可以直接回到 [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md)

### 4.4 当前已扩展的 HTTP-only 覆盖边界

当前透明转发代理样本已验证：

- 会话 A：
  - 首轮 `Reply exactly FIRST.`
  - 续轮 `Reply exactly SECOND.`
  - 两轮都只靠 HTTP `POST /responses` 成功
- 会话 B：
  - 首轮 `Reply exactly ALPHA.`
  - 续轮 `Read /etc/hosts and reply with only the first token.`
  - 续轮第一段 `/responses` 返回：
    - `reasoning`
    - `function_call`
      - `name = "exec_command"`
      - `arguments = {"cmd":"awk 'NF{print $1; exit}' /etc/hosts","yield_time_ms":1000,"max_output_tokens":200}`
  - 客户端随后发起第二段 `/responses`，请求体新增：
    - `reasoning`
    - `function_call`
    - `function_call_output`
  - 最终 assistant 文本是：
    - `##`

当前样本还确认：

- 续轮请求当前没有设置 `previous_response_id`
- 当前续轮样本通过扩展 `input` 历史推进会话

### 4.5 当前不能下的结论

- 不能说这些额外字段全部都是必需字段
- 不能说本地最小契约已经覆盖交互 TUI、apps 或其他 CLI 入口
- 不能说所有路径都会先产出 reasoning item

## 5. 对架构的影响

当前证据把方案三的真实远端定位收窄成：

- `Claude Code CLI -> local Anthropic-compatible gateway -> remote https://chatgpt.com/backend-api/codex/responses`

当前证据同时排除：

- `Claude Code CLI -> local gateway -> https://api.openai.com/v1/responses` 这种“直接 public API 转发”路线

## 6. 后续验证

下一步只剩三类问题：

- 交互 TUI 与 apps 路径是否仍可在 websocket `404` 后走 HTTP 成功
- Claude tools 如何映射到真实上游的工具语义
- 辅助产品面在主链路里是否仍有必需依赖
