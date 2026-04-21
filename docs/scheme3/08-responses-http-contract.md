# `/responses` HTTP 契约

Date: 2026-04-20

## 1. 文档定位

本文件只记录当前已经被验证的 `/responses` HTTP 契约。

这里的“契约”专指：

- `codex-cli 0.121.0`
- `codex exec --json`
- 单轮文本回复路径
- `features.apps=false`
- websocket `GET /responses` 连续返回 `404`
- HTTP `POST /responses` 返回 SSE

本文件不把本地 probe 接受结果写成“真实上游完整协议”。

## 2. 验证依据

当前结论来自两类证据：

- OpenAI 官方源码与官方 API 文档
- 本机 `codex exec` 成功探针

主证据稿：

- [研究总稿 Appendix A.7](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:342)

## 3. 已验证请求骨架

### 3.1 请求头

当前成功样本已验证：

- `Authorization: Bearer ...`
- `chatgpt-account-id`
- `accept: text/event-stream`
- `content-type: application/json`
- `content-encoding: zstd`

### 3.2 zstd 解压后的顶层字段

当前成功样本解压后得到的顶层字段：

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

### 3.3 当前样本值

当前样本已验证：

- `model: "gpt-5.4"`
- `stream: true`
- `store: false`
- `tool_choice: "auto"`
- `parallel_tool_calls: true`
- `reasoning.effort: "xhigh"`
- `include: ["reasoning.encrypted_content"]`

当前样本结构已验证：

- `input` 是列表，当前样本长度为 `3`
- 前三个 `input` 项的 `type` 都是 `message`
- 第一项有 `type`、`role`、`content`
- 第一项 `role` 是 `developer`
- 第一项 `content[0]` 有 `type`、`text`
- `tools` 是列表，当前样本长度为 `16`
- 当前样本前几个工具项 `type` 是 `function`

说明：

- 这些数字只对当前样本成立
- 不能把 `input_len=3` 或 `tools_len=16` 写成固定协议要求

## 4. 已验证成功响应契约

### 4.1 传输结果

当前已验证：

- `codex exec` 会先尝试 websocket `GET /responses`
- 当 websocket 反复 `404` 时，当前路径仍会继续到 HTTP `POST /responses`
- 只要 `POST /responses` 返回被客户端接受的 SSE 事件序列，当前路径就能完成回复

### 4.2 当前被接受的事件顺序

本地 probe 返回下列事件顺序；`codex exec` 已成功接受：

1. `response.created`
2. `response.in_progress`
3. `response.output_item.added`
4. `response.content_part.added`
5. `response.output_text.delta`
6. `response.output_text.done`
7. `response.content_part.done`
8. `response.output_item.done`
9. `response.completed`

### 4.3 当前被接受的最小字段集合

当前 probe 使用并已被接受的字段集合如下：

#### `response.created`

- `type`
- `response.id`
- `response.object`
- `response.created_at`
- `response.status`
- `response.model`
- `response.output`

#### `response.in_progress`

- `type`
- `response.id`
- `response.object`
- `response.created_at`
- `response.status`
- `response.model`
- `response.output`

#### `response.output_item.added`

- `type`
- `output_index`
- `item.id`
- `item.type`
- `item.status`
- `item.role`
- `item.content`

#### `response.content_part.added`

- `type`
- `item_id`
- `output_index`
- `content_index`
- `part.type`
- `part.text`

#### `response.output_text.delta`

- `type`
- `item_id`
- `output_index`
- `content_index`
- `delta`

#### `response.output_text.done`

- `type`
- `item_id`
- `output_index`
- `content_index`
- `text`

#### `response.content_part.done`

- `type`
- `item_id`
- `output_index`
- `content_index`
- `part.type`
- `part.text`

#### `response.output_item.done`

- `type`
- `output_index`
- `item.id`
- `item.type`
- `item.status`
- `item.role`
- `item.content`

#### `response.completed`

- `type`
- `response.id`
- `response.object`
- `response.created_at`
- `response.status`
- `response.model`
- `response.output`
- `response.usage.input_tokens`
- `response.usage.output_tokens`
- `response.usage.total_tokens`

### 4.4 当前已验证的“可省略字段”

当前 probe 没有发送以下字段；`codex exec` 仍完成回复：

- `sequence_number`
- `annotations`
- `logprobs`
- `response_id`
- reasoning item
- `obfuscation`
- 响应级扩展字段，例如：
  - `completed_at`
  - `previous_response_id`
  - `prompt_cache_retention`
  - `max_output_tokens`
  - `max_tool_calls`

说明：

- 这里只能得出“当前路径当前版本可接受这些字段缺席”
- 不能把它改写成“官方协议里这些字段永远不是必需”

### 4.5 真实样本裁到最小契约仍成功

当前已验证：

- 以真实远端 `200` 成功样本为输入
- 删除开头 reasoning item 对
- 删除所有事件级 `sequence_number`
- 删除 `annotations`、`logprobs`、`obfuscation`
- 把 `response.created`、`response.in_progress`、`response.completed` 裁到本文件 `4.3` 的最小字段集合
- 把 message item 的 `content` 裁到只剩 `type` 与 `text`

之后再回放给 `codex exec`；当前路径仍得到：

- `item.completed`
- `turn.completed`

当前含义：

- 对当前 `codex exec --json` 单轮文本路径，这份最小契约已经被真实上游样本二次验证
- 这不是对 tools、多轮或 websocket 成功路径的结论

## 5. 当前不能外推的内容

- 不能把本地 probe 接受结果写成真实上游唯一返回形状
- 不能把当前 HTTP-only 成功写成“所有路径都不需要 websocket”
- 不能把当前文本路径成功写成“tool 调用路径也会成功”
- 不能把当前样本中的 `model: "gpt-5.4"` 写成固定模型要求

## 6. 与真实上游的当前差异

相对 [09-real-upstream-capture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/09-real-upstream-capture.md)，当前本地最小契约缺少这些已验证字段：

- 开头一对 reasoning item
- `sequence_number`
- `logprobs`
- `obfuscation`
- reasoning `encrypted_content`
- assistant message `phase`
- 更多 response 级元数据

当前含义：

- 这些字段在真实上游里存在
- 对当前 `codex exec --json` 单轮文本路径，它们都不是必需字段
- 不能把这个结果外推到 tools、多轮或其他 CLI 入口

## 7. 与其余文档的关系

- 上游边界总览见 [04-upstream-edge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/04-upstream-edge.md)
- 当前仍未解决的问题见 [06-open-questions.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/06-open-questions.md)
- 后续验证项见 [05-validation-matrix.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/05-validation-matrix.md)
