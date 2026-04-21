# apps 工具业务动作依赖 v1

Date: 2026-04-21

## 1. 文档定位

本文件只回答一个问题：

- 当前真实 apps 工具业务动作要不要依赖 `/backend-api/...`

这里不讨论纯文本路径；纯文本路径的当前结论见：

- [13-sidecar-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/13-sidecar-dependency-v1.md)
- [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)
- [17-exec-apps-resume-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/17-exec-apps-resume-coverage-v1.md)

## 2. 当前适用范围

本页所有结论只适用于以下范围：

- `codex-cli 0.121.0`
- 非交互 `codex exec --json --enable apps`
- 交互 TTY `codex --no-alt-screen --enable apps`
- 当前真实 GitHub app 业务动作：
  - 非交互：
    - `github_get_user_login`
  - 交互：
    - `github_get_profile`
- 当前真实 Gmail app 业务动作：
  - 非交互：
    - `gmail_get_profile`
    - `gmail_list_labels`
- 当前验证过的 prompts：
  - 非交互：
    - `Use the GitHub app to tell me the authenticated GitHub login. Output only the login.`
    - `Use the Gmail app to tell me the authenticated Gmail address. Output only the address.`
  - 交互：
    - `Use the GitHub app to tell me the authenticated GitHub numeric id. Output only the digits.`

本页不覆盖：

- 尚未验证的其他 app 工具家族
- 更深业务语义

## 3. 当前实验

### 3.1 基线直连成功

实验配置：

- 不 override `openai_base_url`
- 不 override `chatgpt_base_url`
- 直接使用当前机器的 ChatGPT 登录态

已验证结果：

- 终端出现真实 `mcp_tool_call`：
  - `server = codex_apps`
  - `tool = github_get_user_login`
- 工具结果是：
  - `{"login":"n0rvyn","id":99057954}`
- 最终 assistant 输出：
  - `n0rvyn`
- 当前 run 结束于：
  - `turn.completed`

证据：

- [研究总稿 Appendix A.34](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.2 forward-only 对照成功

实验配置：

- `openai_base_url="http://127.0.0.1:8874"`
- 本地 `/responses` forwarder 透明转发到真实订阅上游
- 不 override `chatgpt_base_url`

已验证结果：

- 终端出现真实 `mcp_tool_call`：
  - `server = codex_apps`
  - `tool = github_get_user_login`
- 工具结果仍是：
  - `{"login":"n0rvyn","id":99057954}`
- 最终 assistant 输出：
  - `n0rvyn`
- forward log 里出现：
  - `GET /responses = 7`
  - `POST /responses = 2`
  - `status 200 = 2`
- 当前两段 `/responses` 请求都保持同一顶层骨架：
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
- 请求推进关系当前样本是：
  - 第 `1` 段：
    - `input_len = 3`
    - `tools_len = 21`
    - 最后一个 `input` item 是 `message`
  - 第 `2` 段：
    - `input_len = 7`
    - `tools_len = 21`
    - 最后一个 `input` item 是 `function_call_output`

当前含义：

- 仅把 `/responses` 主出口改成本地透明转发，不会破坏当前这条 GitHub app 业务动作

证据：

- `/tmp/codex-apps-github-forward-only-8874/events.jsonl`
- [研究总稿 Appendix A.34](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.3 sidecar `404` 会破坏当前 GitHub app 业务动作

实验配置：

- `openai_base_url="http://127.0.0.1:8870"`
- `chatgpt_base_url="http://127.0.0.1:8871/backend-api"`
- `/responses` 透明转发到真实订阅上游
- 当前已观测到的 `/backend-api/...` sidecar 请求统一返回 `404`

当前已观测 sidecar 路径包括：

- `/backend-api/plugins/featured?platform=codex`
- `/backend-api/plugins/list`
- `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
- `/backend-api/wham/apps`
- `/backend-api/codex/analytics-events/events`

已验证结果：

- `/responses` forward log 里仍出现：
  - `GET /responses = 7`
  - `POST /responses = 3`
  - `status 200 = 3`
- 当前三段 `/responses` 请求都保持同一顶层骨架
- 请求推进关系当前样本是：
  - 第 `1` 段：
    - `input_len = 3`
    - 最后一个 `input` item 是 `message`
  - 第 `2` 段：
    - `input_len = 7`
    - 最后一个 `input` item 是 `function_call_output`
  - 第 `3` 段：
    - `input_len = 11`
    - 最后一个 `input` item 是 `function_call_output`
- 终端出现真实 `mcp_tool_call`：
  - `tool = github_get_user_login`
- 该工具调用失败，终端错误文本包括：
  - `tool call error: failed to get client`
  - `MCP startup failed: handshaking with MCP server failed`
  - `error decoding response body`
- agent 随后尝试：
  - `github_get_profile`
- 第二个工具调用也失败
- 最终 assistant 输出：
  - `GitHub app error: unable to retrieve authenticated login.`

当前含义：

- 在 `/responses` 主出口仍然健康时，统一 sidecar `404` 已足以破坏当前这条 GitHub app 业务动作

证据：

- `/tmp/codex-apps-github-sidecar404-forward-8870/events.jsonl`
- `/tmp/codex-apps-github-sidecar404-blocker-8871/events.jsonl`
- [研究总稿 Appendix A.34](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.4 sidecar `500` 也会破坏当前 GitHub app 业务动作

实验配置：

- `openai_base_url="http://127.0.0.1:8872"`
- `chatgpt_base_url="http://127.0.0.1:8873/backend-api"`
- `/responses` 透明转发到真实订阅上游
- 当前已观测到的 `/backend-api/...` sidecar 请求统一返回 `500`

当前已观测 sidecar 路径包括：

- `/backend-api/plugins/featured?platform=codex`
- `/backend-api/plugins/list`
- `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
- `/backend-api/wham/apps`
- `/backend-api/codex/analytics-events/events`

已验证结果：

- `/responses` forward log 里仍出现：
  - `GET /responses = 7`
  - `POST /responses = 3`
  - `status 200 = 3`
- 当前三段 `/responses` 请求都保持同一顶层骨架
- 请求推进关系当前样本是：
  - 第 `1` 段：
    - `input_len = 3`
    - 最后一个 `input` item 是 `message`
  - 第 `2` 段：
    - `input_len = 7`
    - 最后一个 `input` item 是 `function_call_output`
  - 第 `3` 段：
    - `input_len = 11`
    - 最后一个 `input` item 是 `function_call_output`
- 终端出现真实 `mcp_tool_call`：
  - `tool = github_get_user_login`
- 该工具调用失败，终端错误文本包括：
  - `tool call error: failed to get client`
  - `MCP startup failed: handshaking with MCP server failed`
  - `error decoding response body`
- agent 再次尝试同一工具后仍失败
- 最终 assistant 输出：
  - `无法通过 GitHub app 获取登录名；GitHub app 握手失败。`

当前含义：

- 在 `/responses` 主出口仍然健康时，统一 sidecar `500` 也足以破坏当前这条 GitHub app 业务动作

证据：

- `/tmp/codex-apps-github-sidecar500-forward-8872/events.jsonl`
- `/tmp/codex-apps-github-sidecar500-blocker-8873/events.jsonl`
- [研究总稿 Appendix A.34](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.5 交互 forward-only 对照成功

实验配置：

- `openai_base_url="http://127.0.0.1:8881"`
- 交互 TTY `codex --no-alt-screen --enable apps`
- websocket `GET /responses` 统一 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游
- 在同一会话的三轮文本提示之后提交：
  - `Use the GitHub app to tell me the authenticated GitHub numeric id. Output only the digits.`

已验证结果：

- transcript 里出现真实工具调用：
  - `Called codex_apps.github_get_profile({})`
- 工具结果里出现：
  - `"id": "99057954"`
- transcript 里最终输出：
  - `99057954`
- paired forward log 里当前总计：
  - `GET /responses = 7`
  - `POST /responses = 5`
  - `status 200 = 5`

当前含义：

- 当前交互 GitHub app 业务动作在 forward-only 对照下成功
- 这排除了“交互 TUI + 本地 `/responses` 转发”本身会把这条动作打坏

证据：

- `/tmp/codex-interactive-apps-8881.typescript`
- `/tmp/codex-interactive-apps-forward-8881/events.jsonl`
- [研究总稿 Appendix A.35](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.6 交互 sidecar `404` 会破坏当前 GitHub app 业务动作

实验配置：

- `openai_base_url="http://127.0.0.1:8882"`
- `chatgpt_base_url="http://127.0.0.1:8883/backend-api"`
- 交互 TTY `codex --no-alt-screen --enable apps`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 `/backend-api/...` sidecar 请求统一返回 `404`

已验证结果：

- blocker log 里当前已观测到的 sidecar 请求都带：
  - `"mode": "404"`
- transcript 启动期出现：
  - `MCP client for \`codex_apps\` failed to start`
  - `MCP startup incomplete (failed: codex_apps)`
- paired forward log 里仍出现：
  - `GET /responses = 7`
  - `POST /responses = 1`
- transcript 里出现真实工具调用：
  - `Called codex_apps.github_get_profile({})`
- transcript 里的工具错误文本包括：
  - `tool call error: failed to get client`
  - `MCP startup failed: handshaking with MCP server failed`
  - `error decoding response body`

当前含义：

- 当前交互 GitHub app 业务动作在 `/responses` 主出口仍然可达时，仍会被 sidecar `404` 打坏

证据：

- `/tmp/codex-interactive-github-sidecar404-8882.typescript`
- `/tmp/codex-interactive-github-sidecar404-forward-8882/events.jsonl`
- `/tmp/codex-interactive-github-sidecar404-blocker-8883/events.jsonl`
- [研究总稿 Appendix A.35](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.7 交互 sidecar `500` 也会破坏当前 GitHub app 业务动作

实验配置：

- `openai_base_url="http://127.0.0.1:8884"`
- `chatgpt_base_url="http://127.0.0.1:8885/backend-api"`
- 交互 TTY `codex --no-alt-screen --enable apps`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 `/backend-api/...` sidecar 请求统一返回 `500`

已验证结果：

- blocker log 里当前已观测到的 sidecar 请求都带：
  - `"mode": "500"`
- transcript 启动期出现：
  - `MCP client for \`codex_apps\` failed to start`
  - `MCP startup incomplete (failed: codex_apps)`
- paired forward log 里仍出现：
  - `GET /responses = 7`
  - `POST /responses = 1`
- transcript 里出现真实工具调用：
  - `Called codex_apps.github_get_profile({})`
- transcript 里的工具错误文本包括：
  - `tool call error: failed to get client`
  - `MCP startup failed: handshaking with MCP server failed`
  - `error decoding response body`

当前含义：

- 当前交互 GitHub app 业务动作在 `/responses` 主出口仍然可达时，也会被 sidecar `500` 打坏

证据：

- `/tmp/codex-interactive-github-sidecar500-8884.typescript`
- `/tmp/codex-interactive-github-sidecar500-forward-8884/events.jsonl`
- `/tmp/codex-interactive-github-sidecar500-blocker-8885/events.jsonl`
- [研究总稿 Appendix A.35](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.8 非交互 Gmail app 业务动作在 forward-only 对照下成功

实验配置：

- `openai_base_url="http://127.0.0.1:8890"`
- 非交互 `codex exec --json --enable apps`
- 本地 `/responses` forwarder 透明转发到真实订阅上游
- 不 override `chatgpt_base_url`
- prompt 固定为：
  - `Use the Gmail app to tell me the authenticated Gmail address. Output only the address.`

已验证结果：

- 终端出现真实 `mcp_tool_call`：
  - `tool = gmail_get_profile`
- 工具结果里出现：
  - `"email":"norvynzhang@gmail.com"`
- 最终 assistant 输出：
  - `norvynzhang@gmail.com`
- forward log 里出现：
  - `GET /responses = 7`
  - `POST /responses = 2`
  - `status 200 = 2`

当前含义：

- 仅把 `/responses` 主出口改成本地透明转发，不会破坏当前这条 Gmail app 业务动作

证据：

- `/tmp/codex-gmail-forward-only-8890/events.jsonl`
- [研究总稿 Appendix A.36](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.9 非交互 Gmail app 业务动作在 sidecar `404` 下失败

实验配置：

- `openai_base_url="http://127.0.0.1:8886"`
- `chatgpt_base_url="http://127.0.0.1:8887/backend-api"`
- 非交互 `codex exec --json --enable apps`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 `/backend-api/...` sidecar 请求统一返回 `404`

已验证结果：

- blocker log 里当前 sidecar 请求都带：
  - `"mode": "404"`
- `/responses` forward log 里仍出现：
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

- sidecar `404` 的影响已经不只限于 GitHub；当前 Gmail app 家族也会被同类握手错误打坏

证据：

- `/tmp/codex-gmail-sidecar404-forward-8886/events.jsonl`
- `/tmp/codex-gmail-sidecar404-blocker-8887/events.jsonl`
- [研究总稿 Appendix A.36](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.10 非交互 Gmail app 业务动作在 sidecar `500` 下也失败

实验配置：

- `openai_base_url="http://127.0.0.1:8891"`
- `chatgpt_base_url="http://127.0.0.1:8892/backend-api"`
- 非交互 `codex exec --json --enable apps`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 `/backend-api/...` sidecar 请求统一返回 `500`

已验证结果：

- blocker log 里当前 sidecar 请求都带：
  - `"mode": "500"`
- `/responses` forward log 里仍出现：
  - `GET /responses = 7`
  - `POST /responses = 6`
  - `status 200 = 6`
- 第一个真实工具调用失败：
  - `tool = gmail_get_profile`
  - `tool call error: failed to get client`
- agent 重试同一工具后仍失败
- 终端随后出现本地回退搜索行为：
  - `ls/find ~/.codex`
  - `rg` 搜索 gmail 相关配置
  - 打开 `~/.codex/auth.json`
  - 打开 `state_5.sqlite`
  - 打开 `logs_2.sqlite`

当前含义：

- Gmail app 家族在 sidecar `500` 下同样失败，不是只在 `404` 下失败
- 当前 Gmail `500` 外观比 `404` 更重；它会进入本地回退搜索，而不是直接收敛成连接器不可用文案

证据：

- `/tmp/codex-gmail-sidecar500-forward-8891/events.jsonl`
- `/tmp/codex-gmail-sidecar500-blocker-8892/events.jsonl`
- [研究总稿 Appendix A.36](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.11 非交互 Notion app 业务动作在 forward-only 对照下成功

实验配置：

- `openai_base_url="http://127.0.0.1:8893"`
- 非交互 `codex exec --json --enable apps`
- 本地 `/responses` forwarder 透明转发到真实订阅上游
- 不 override `chatgpt_base_url`
- prompt 固定为：
  - `Use the Notion app to search Notion users for Norvyn Zhang and return only the exact name. If the tool rejects query_type=users, retry with query_type=user.`

已验证结果：

- 第一段真实工具调用：
  - `tool = notion (legacy)_search`
  - `query_type = "users"`
  - 工具返回 schema 校验错误，要求 `query_type` 只能是 `internal` 或 `user`
- agent 随后重试：
  - `tool = notion (legacy)_search`
  - `query_type = "user"`
- 第二次工具结果里出现：
  - `<user id="..." name="Norvyn Zhang" email="norvynzhang@gmail.com"/>`
- 最终 assistant 输出：
  - `Norvyn Zhang`

当前含义：

- 当前 Notion app 家族在 forward-only 对照下成功
- 仅把 `/responses` 主出口改成本地透明转发，不会破坏当前这条 Notion app 业务动作

证据：

- `/tmp/codex-notion-forward-8893/events.jsonl`
- [研究总稿 Appendix A.37](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

### 3.12 非交互 Notion app 业务动作在 sidecar `404` 与 `500` 下都会失败

实验配置：

- sidecar `404`
  - `openai_base_url="http://127.0.0.1:8893"`
  - `chatgpt_base_url="http://127.0.0.1:8894/backend-api"`
- sidecar `500`
  - `openai_base_url="http://127.0.0.1:8893"`
  - `chatgpt_base_url="http://127.0.0.1:8895/backend-api"`
- 非交互 `codex exec --json --enable apps`
- `/responses` 透明转发到真实订阅上游

已验证结果：

- sidecar `404`：
  - blocker log 里 sidecar 请求都带：
    - `"mode": "404"`
  - `/responses` 仍然健康：
    - `GET /responses = 7`
    - `POST /responses = 4`
    - `status 200 = 4`
  - 两次真实工具调用都失败：
    - `tool = notion (legacy)_search`
    - `query_type = "users"`
    - `query_type = "user"`
  - 最终 assistant 输出：
    - `⚠️ 无法验证: Notion app MCP 启动握手失败；\`query_type=users\` 与 \`query_type=user\` 两次请求都未成功执行。`
- sidecar `500`：
  - blocker log 里 sidecar 请求都带：
    - `"mode": "500"`
  - `/responses` 仍然健康：
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

- 当前 sidecar hard dependency 已经覆盖到第三个 app 家族 Notion
- 对当前 Notion 样本，失败点发生在 MCP 握手阶段，而不是实际查询阶段

## 4. 当前结论

对当前范围，已经可以写成结论：

- 当前这条真实 GitHub app 业务动作在正常环境下成功
- 当前这条真实 GitHub app 业务动作在 forward-only 对照下仍成功
- 当前交互 GitHub app 业务动作在 forward-only 对照下也成功
- 当前 Gmail app 业务动作在 forward-only 对照下也成功
- 当前这条真实 GitHub app 业务动作在 sidecar `404` 与 sidecar `500` 下都会失败
- 当前交互 GitHub app 业务动作在 sidecar `404` 与 sidecar `500` 下也都会失败
- 当前 Gmail app 业务动作在 sidecar `404` 与 sidecar `500` 下都失败
- 当前 Notion app 业务动作在 forward-only 对照下成功，在 sidecar `404` 与 sidecar `500` 下都失败
- 因此，`/backend-api/...` sidecar 的 hard dependency 已经不只限于单个 GitHub 样本，当前至少覆盖到 GitHub、Gmail、Notion 三个 app 家族

当前可固定的边界是：

- 文本路径：
  - 当前已测样本里，sidecar 不是 hard dependency
- GitHub app 业务动作：
  - 当前已测样本里，sidecar 是 hard dependency
- Gmail app 业务动作：
  - 当前已测 `404/500` 样本里，sidecar 是 hard dependency
- Notion app 业务动作：
  - 当前已测 `404/500` 样本里，sidecar 是 hard dependency

## 5. 当前不能扩大解释

当前不能把这里的结果扩大成：

- “所有 app 工具业务动作都依赖同一组 sidecar 路径”
- “其中任一条 sidecar 路径单独失败就一定会破坏业务动作”
- “交互 TUI 下的所有 apps 工具业务动作都已经被覆盖”
- “所有 app 工具家族都已有同样结论”

## 6. 证据位置

- forward-only:
  - `/tmp/codex-apps-github-forward-only-8874/events.jsonl`
  - `/tmp/codex-gmail-forward-only-8890/events.jsonl`
  - `/tmp/codex-notion-forward-8893/events.jsonl`
- sidecar `404`:
  - `/tmp/codex-apps-github-sidecar404-forward-8870/events.jsonl`
  - `/tmp/codex-apps-github-sidecar404-blocker-8871/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar404-forward-8882/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar404-blocker-8883/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar404-8882.typescript`
  - `/tmp/codex-gmail-sidecar404-forward-8886/events.jsonl`
  - `/tmp/codex-gmail-sidecar404-blocker-8887/events.jsonl`
  - `/tmp/codex-notion-sidecar404-blocker-8894/events.jsonl`
- sidecar `500`:
  - `/tmp/codex-apps-github-sidecar500-forward-8872/events.jsonl`
  - `/tmp/codex-apps-github-sidecar500-blocker-8873/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar500-forward-8884/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar500-blocker-8885/events.jsonl`
  - `/tmp/codex-interactive-github-sidecar500-8884.typescript`
  - `/tmp/codex-gmail-sidecar500-forward-8891/events.jsonl`
  - `/tmp/codex-gmail-sidecar500-blocker-8892/events.jsonl`
  - `/tmp/codex-notion-sidecar500-blocker-8895/events.jsonl`
