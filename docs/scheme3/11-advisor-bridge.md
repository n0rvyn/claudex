# Advisor Bridge

Date: 2026-04-20

## 1. 文档定位

本文件只记录 `advisor` 这一个特种工具在方案三里的已验证事实。

范围只包含三层：

- Anthropic 官方契约
- 真实 `claude` 对 advisor server-side block 的接受性
- ChatGPT 订阅上游 `/responses` 的 synthetic advisor bridge

## 2. 官方契约

Anthropic 官方 `Advisor tool` 文档当前已明确：

- 请求定义：
  - `{"type":"advisor_20260301","name":"advisor","model":"..."}`
- 这是 server-side tool
- 执行器调用时，响应 content 会出现：
  - `server_tool_use`
  - `advisor_tool_result`
- 这两个 block 都发生在同一个 `/v1/messages` 请求里
- 多轮续回时，必须把 `advisor_tool_result` 一起带回

来源：

- <https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool>

## 3. Claude CLI 接受性

本机 loopback Anthropic mock 当前已验证：

- 第 1 个 `/v1/messages` 请求是标题生成请求，不含工具
- 第 2 个请求才是主请求，包含：
  - `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-4-7"}`
- 当主请求的 SSE 返回：
  - `text`
  - `server_tool_use`
  - `advisor_tool_result`
  - `text`
- `claude` 正常完成，结果是：
  - `Advisor consulted. Final answer from the first turn.`
- 用相同 `session_id` 续轮后，Claude 会在 assistant content 中原样带回：
  - `server_tool_use`
  - `advisor_tool_result`

当前含义：

- 方案三在 Anthropic 入口面保留 advisor 语义是可行的
- 不需要把 advisor 降成客户端 `tool_result` 回合

## 4. Raw passthrough 不可用

当前已验证：

- 把 raw `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-4-7"}` 直接追加到 `/responses` 的 `tools` 数组
- 第一段真实上游请求直接返回：
  - `400 Bad Request`
  - `{"detail":"Unsupported tool type: advisor_20260301"}`

当前含义：

- `advisor` 不能走 raw passthrough
- 方案三必须桥接，不是透传

## 5. `/responses` Synthetic Bridge 已验证

当前 bridge 原型做法：

- 在 `/responses` 主请求里注入一个零参数 function：
  - `name = "advisor"`
- 第一段强制上游调用这个 synthetic advisor function
- 本地收到真实 `function_call(name="advisor")` 后，再发起一次真实 `/responses` 子调用拿建议文本
- 第三段把该建议文本作为 `function_call_output` 送回主请求

当前已验证成功的样本：

1. `gpt-5.4 -> gpt-5.4 advisor`
   - `codex exec` 得到：
     - `item.completed`
     - `turn.completed`
2. `gpt-5.3-codex -> gpt-5.4 advisor`
   - 第一段上游 `response.created` 明确显示主模型是 `gpt-5.3-codex`
   - advisor 子调用状态是 `200`
   - `codex exec` 得到：
     - `item.completed`
     - `turn.completed`

当前含义：

- `advisor` 在方案三里已经有一条被真实订阅上游接受的 bridge 路径
- 当前更合理的一组已验证“执行器 / advisor”分工样本是：
  - `gpt-5.3-codex -> gpt-5.4`

## 6. ChatGPT 订阅面模型探针

对 `https://chatgpt.com/backend-api/codex/responses` 的最小写请求，当前已验证：

- 可用：
  - `gpt-5.4`
  - `gpt-5.4-mini`
  - `gpt-5.3-codex`
- 不可用：
  - `gpt-5.2-codex`
  - `gpt-5.1-codex-max`

当前错误体已明确写出：

- `The 'gpt-5.2-codex' model is not supported when using Codex with a ChatGPT account.`
- `The 'gpt-5.1-codex-max' model is not supported when using Codex with a ChatGPT account.`

## 7. 当前能下的结论

- Anthropic 侧的 advisor 契约已经明确，不再是未知项
- 真实 `claude` 接受 `server_tool_use + advisor_tool_result`
- 续轮时，Claude 会把这两个 block 原样带回
- raw `advisor_20260301` 不能透传到 `/responses`
- `/responses` synthetic advisor bridge 已经在真实订阅上游成功

## 8. 当前可写成实现规则的桥接表

| 阶段 | Anthropic 侧 | 网关动作 | `/responses` 侧 |
| --- | --- | --- | --- |
| 请求入站 | `advisor_20260301` tool 定义 | 保留在 Anthropic 入口，不做 raw passthrough | 不直接发送 raw `advisor_20260301` |
| 主请求出站 | Claude 主请求 | 注入 synthetic function | `tools += {"type":"function","name":"advisor","parameters":{"type":"object","properties":{},"additionalProperties":false},"strict":false}` |
| 第一次上游调用 | 无 | 强制或允许调用 synthetic advisor | 真实上游返回 `function_call(name="advisor")` |
| advisor 子调用 | 无 | 网关单独发起真实 `/responses` 子调用拿建议文本 | 当前已验证 `gpt-5.3-codex -> gpt-5.4 advisor` 与 `gpt-5.4 -> gpt-5.4 advisor` |
| 第二次主请求 | 无 | 把 advisor 结果作为函数输出送回主请求 | `input += reasoning + function_call + function_call_output` |
| Anthropic 出站 | `server_tool_use + advisor_tool_result` | 把 bridge 结果还原成 Anthropic server-side block 语义 | 不把 synthetic `advisor` 暴露给 Claude CLI |

## 9. 当前还不能下的结论

- 不能说 advisor bridge 原型已经等于正式实现
- 不能说所有执行器模型都适合配 `gpt-5.4` 作为 advisor
- 不能说当前 bridge 的提示词和字段集合已经是最终版本
