# 非交互 apps 续轮路径覆盖 v1

Date: 2026-04-21

## 1. 文档定位

本文件只记录当前非交互 `features.apps=true` 且 `exec/exec resume` 路径的已验证覆盖结果。

这里只写已经被二次验证的事实，不把更深 apps 回合或更广入口写成已知。

## 2. 适用范围

当前结论只覆盖：

- `codex-cli 0.121.0`
- `codex exec --json`
- `codex exec resume --json`
- `features.apps=true`

当前结论不覆盖：

- 交互 TTY apps 更深回合
- 需要 `codex_apps` MCP 实际完成业务动作的路径
- 其他未验证 CLI 入口

## 3. 已验证实验

### 3.1 当前非交互 `features.apps=true` 续轮文本路径可走 HTTP-only

实验配置：

- `openai_base_url="http://127.0.0.1:8823"`
- 本地 forwarder 对每个 websocket `GET /responses` 返回 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游
- 第一轮命令：
  - `Reply exactly APPSRESUME1.`
- 续轮命令：
  - `Reply exactly APPSRESUME2.`

已验证结果：

- 第一轮与续轮都会先多次尝试 websocket `GET /responses`
- websocket 全部 `404` 后，两轮都继续发起 HTTP `POST /responses`
- 两轮最终都成功完成：
  - 首轮输出：
    - `APPSRESUME1`
  - 续轮输出：
    - `APPSRESUME2`
  - 两轮都有：
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

当前已验证的工具类型分布：

- `function = 13`
- `custom = 1`
- `web_search = 1`
- `namespace = 6`

当前已验证的 `namespace` 工具集合：

- `mcp__codex_apps__adobe_photoshop`
- `mcp__codex_apps__figma`
- `mcp__codex_apps__github`
- `mcp__codex_apps__gmail`
- `mcp__codex_apps__notion__legacy`
- `mcp__pencil__`

证据：

- `/tmp/codex-exec-apps-resume-8823/events.jsonl`
- `/tmp/codex-exec-apps-first.txt`
- `/tmp/codex-exec-apps-second.txt`

### 3.2 当前非交互 `features.apps=true` 续轮文本路径在 sidecar `404` 下仍能完成

实验配置：

- `openai_base_url="http://127.0.0.1:8824"`
- `chatgpt_base_url="http://127.0.0.1:8825/backend-api"`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 sidecar 请求统一返回 `404`
- 第一轮命令：
  - `Reply exactly APPSSIDE404A.`
- 续轮命令：
  - `Reply exactly APPSSIDE404B.`

当前已观测到并被拦截为 `404` 的 sidecar 路径包括：

- `/backend-api/codex/analytics-events/events`
- `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
- `/backend-api/plugins/featured?platform=codex`
- `/backend-api/plugins/list`
- `/backend-api/wham/apps`

已验证结果：

- sidecar `404` 没有阻止当前首轮或续轮文本回复完成
- 终端会额外出现 sidecar 相关 stderr：
  - `rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Client(Reqwest(reqwest::Error { kind: Decode, source: Error("data did not match any variant of untagged enum JsonRpcMessage", line: 0, column: 0) }))`
- paired forward log 里仍出现两次 HTTP `POST /responses`
- 两轮最终输出：
  - `APPSSIDE404A`
  - `APPSSIDE404B`

证据：

- `/tmp/codex-exec-apps-sidecar-forward-8824/events.jsonl`
- `/tmp/codex-exec-apps-sidecar-404-8825/events.jsonl`
- `/tmp/codex-exec-apps-sidecar-404-first.txt`
- `/tmp/codex-exec-apps-sidecar-404-second.txt`

### 3.3 当前非交互 `features.apps=true` 续轮文本路径在 sidecar `500` 下仍能完成

实验配置：

- `openai_base_url="http://127.0.0.1:8826"`
- `chatgpt_base_url="http://127.0.0.1:8827/backend-api"`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 sidecar 请求统一返回 `500`
- 第一轮命令：
  - `Reply exactly APPSSIDE500A.`
- 续轮命令：
  - `Reply exactly APPSSIDE500B.`

当前已观测到并被拦截为 `500` 的 sidecar 路径包括：

- `/backend-api/codex/analytics-events/events`
- `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
- `/backend-api/plugins/featured?platform=codex`
- `/backend-api/plugins/list`
- `/backend-api/wham/apps`

已验证结果：

- sidecar `500` 没有阻止当前首轮或续轮文本回复完成
- 终端会额外出现 sidecar 相关 stderr：
  - `rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Client(Reqwest(reqwest::Error { kind: Decode, source: Error("data did not match any variant of untagged enum JsonRpcMessage", line: 0, column: 0) }))`
- paired forward log 里仍出现两次 HTTP `POST /responses`
- 两轮最终输出：
  - `APPSSIDE500A`
  - `APPSSIDE500B`

证据：

- `/tmp/codex-exec-apps-sidecar-forward-8826/events.jsonl`
- `/tmp/codex-exec-apps-sidecar-500-8827/events.jsonl`
- `/tmp/codex-exec-apps-sidecar-500-first.txt`
- `/tmp/codex-exec-apps-sidecar-500-second.txt`

## 4. 当前结论

当前可以写成结论的只有三条：

- 非交互 `features.apps=true` 的 `codex exec --json` 与 `codex exec resume --json` 当前都已经有 HTTP-only 成功证据
- 当前已观测 sidecar 请求在统一 `404` 与统一 `500` 下，都不是这条非交互 apps 续轮文本路径的硬依赖
- 当前 apps 续轮路径的请求骨架已经至少扩到：
  - 第 1 个请求 `input_len = 3`
  - 第 2 个请求 `input_len = 6`
  - 两轮都维持 `tools_len = 21`

## 5. 当前不能扩大解释

当前不能把这里的结果扩大成：

- “所有 `features.apps=true` 回合都只靠 HTTP `/responses` 就够”
- “所有 apps 相关功能都不依赖 sidecar”
- “sidecar `404` 或 `500` 只会打印 stderr，不会影响业务功能”
- “更深 apps 工具回合也已经验证完成”
