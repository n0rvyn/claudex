# 交互 TUI / apps 路径覆盖 v1

Date: 2026-04-21

## 1. 文档定位

本文件只记录当前交互 TUI 且 `features.apps=true` 路径的已验证覆盖结果。

这里只写已经被二次验证的事实，不把 apps 工具业务动作或其他未测入口写成已知。

## 2. 适用范围

当前结论只覆盖：

- `codex-cli 0.121.0`
- 交互 TTY `codex --no-alt-screen`
- 当前首轮、同会话第二轮、同会话第三轮文本回复路径
- 当前一条同会话第 4 次提交的 GitHub app 业务动作
- `features.apps=true`

当前结论不覆盖：

- 其他 app 工具家族
- 其他未验证的更深同会话序列
- 其他未验证 CLI 入口

## 3. 已验证实验

### 3.1 当前交互 `features.apps=true` 首轮文本路径可走 HTTP-only

实验配置：

- `openai_base_url="http://127.0.0.1:8806"`
- 本地 forwarder 对每个 websocket `GET /responses` 返回 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

已验证结果：

- 客户端先多次尝试 websocket `GET /responses`
- websocket 全部 `404` 后，仍继续发起 HTTP `POST /responses`
- 当前样本的 HTTP `POST /responses` 返回 `200`
- 交互终端最终输出：
  - `APPSHTTP`

证据：

- `/tmp/codex-apps-http-only-8806/events.jsonl`

### 3.2 当前交互 `features.apps=true` 首轮文本路径在 sidecar `404` 下仍能完成

实验配置：

- `openai_base_url="http://127.0.0.1:8807"`
- `chatgpt_base_url="http://127.0.0.1:8808/backend-api"`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 sidecar 请求统一返回 `404`

当前已观测到并被拦截为 `404` 的 sidecar 路径包括：

- `/backend-api/plugins/featured?platform=codex`
- `/backend-api/plugins/list`
- `/backend-api/wham/apps`
- `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
- `/backend-api/wham/usage`
- `/backend-api/codex/analytics-events/events`

已验证结果：

- sidecar `404` 没有阻止当前首轮文本回复完成
- paired forward log 里仍出现 HTTP `POST /responses`
- 当前样本的 HTTP `POST /responses` 返回 `200`
- 交互终端最终输出：
  - `APPS404`

证据：

- `/tmp/codex-apps-sidecar-404-8808/events.jsonl`
- `/tmp/codex-apps-sidecar-forward-8807/events.jsonl`

### 3.3 当前交互 `features.apps=true` 首轮文本路径在 sidecar `500` 下仍能完成

实验配置：

- `openai_base_url="http://127.0.0.1:8809"`
- `chatgpt_base_url="http://127.0.0.1:8810/backend-api"`
- `/responses` 透明转发到真实订阅上游
- 当前已观测 sidecar 请求统一返回 `500`

当前已观测到并被拦截为 `500` 的 sidecar 路径包括：

- `/backend-api/plugins/list`
- `/backend-api/plugins/featured?platform=codex`
- `/backend-api/wham/apps`
- `/backend-api/connectors/directory/list?tier=categorized&external_logos=true`
- `/backend-api/codex/analytics-events/events`

已验证结果：

- sidecar `500` 没有阻止当前首轮文本回复完成
- paired forward log 里仍出现 HTTP `POST /responses`
- 当前样本的 HTTP `POST /responses` 返回 `200`
- 交互终端出现警告：
  - `MCP client for \`codex_apps\` failed to start`
  - `MCP startup incomplete (failed: codex_apps)`
- 当前样本最终仍输出：
  - `APPS500`

证据：

- `/tmp/codex-apps-sidecar-500-8810/events.jsonl`
- `/tmp/codex-apps-sidecar-forward-8809/events.jsonl`

### 3.4 当前交互 `features.apps=true` 同会话第二轮文本路径也可走 HTTP-only

实验配置：

- `openai_base_url="http://127.0.0.1:8850"`
- 同一交互会话连续提交两轮文本提示
- 本地 forwarder 对每个 websocket `GET /responses` 返回 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

已验证结果：

- paired forward log 里出现：
  - `GET /responses = 7`
  - `POST /responses = 2`
  - `200` 响应 = `2`
- 同一交互会话的两轮终端输出在验证 run 中记录为：
  - `APPDEEP1`
  - `APPDEEP2`

证据：

- `/tmp/codex-interactive-apps-resume-8850/events.jsonl`

### 3.5 当前交互 `features.apps=true` 同会话第二轮文本路径在 sidecar `404` 与 `500` 下仍能完成

实验配置：

- 保持交互 TTY `codex --no-alt-screen --enable apps`
- 同一交互会话连续提交两轮文本提示
- `/responses` 透明转发到真实订阅上游
- sidecar blocker 分别统一返回 `404` 与 `500`

已验证结果：

- sidecar `404`
  - paired forward log 里出现：
    - `GET /responses = 7`
    - `POST /responses = 2`
    - `200` 响应 = `2`
  - blocker log 里观测到：
    - `POST /backend-api/codex/analytics-events/events = 3`
    - `GET /backend-api/connectors/directory/list?tier=categorized&external_logos=true = 5`
    - `GET /backend-api/plugins/featured?platform=codex = 1`
    - `GET /backend-api/plugins/list = 1`
    - `POST /backend-api/wham/apps = 3`
    - `GET /backend-api/wham/usage = 1`
  - 同一交互会话的两轮终端输出在验证 run 中记录为：
    - `APPDEEP4041`
    - `APPDEEP4042`
- sidecar `500`
  - paired forward log 里出现：
    - `GET /responses = 7`
    - `POST /responses = 2`
    - `200` 响应 = `2`
  - blocker log 里观测到同一组 sidecar 路径
  - 当前终端会额外出现：
    - `MCP client for \`codex_apps\` failed to start`
    - `MCP startup incomplete (failed: codex_apps)`
  - 同一交互会话的两轮终端输出在验证 run 中记录为：
    - `APPDEEP5001`
    - `APPDEEP5002`

证据：

- `/tmp/codex-interactive-apps-sidecar404-forward-8851/events.jsonl`
- `/tmp/codex-interactive-apps-sidecar404-blocker-8852/events.jsonl`
- `/tmp/codex-interactive-apps-sidecar500-forward-8853/events.jsonl`
- `/tmp/codex-interactive-apps-sidecar500-blocker-8854/events.jsonl`

### 3.6 当前交互 `features.apps=true` 同会话第三轮文本路径也可走 HTTP-only

实验配置：

- `openai_base_url="http://127.0.0.1:8881"`
- 同一交互会话依次提交三轮文本提示：
  - `Reply exactly APPROUND3A.`
  - `Reply exactly APPROUND3B.`
  - `Reply exactly APPROUND3C.`
- 本地 forwarder 对每个 websocket `GET /responses` 返回 `404`
- HTTP `POST /responses` 透明转发到真实订阅上游

已验证结果：

- transcript 里记录到三轮文本结果：
  - `APPROUND3A`
  - `APPROUND3B`
  - `APPROUND3C`
- paired forward log 里出现：
  - `GET /responses = 7`
  - `POST /responses = 5`
  - `200` 响应 = `5`
- 当前 `5` 次 `POST /responses` 同时覆盖：
  - 三轮文本回复
  - 同会话后续一条 GitHub app 业务动作的两段工具往返

证据：

- `/tmp/codex-interactive-apps-8881.typescript`
- `/tmp/codex-interactive-apps-forward-8881/events.jsonl`

### 3.7 当前交互 GitHub app 业务动作在 forward-only 下成功

实验配置：

- 复用 `3.6` 的同一交互会话与同一组 forward-only 配置
- 在三轮文本提示之后提交：
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
  - `200` 响应 = `5`

当前含义：

- 当前交互 `features.apps=true` 路径不只覆盖到第三轮文本
- 在同一 forward-only 会话里，至少一条真实 GitHub app 业务动作也已经成功

证据：

- `/tmp/codex-interactive-apps-8881.typescript`
- `/tmp/codex-interactive-apps-forward-8881/events.jsonl`

## 4. 当前结论

当前可以写成结论的有七条：

- 交互 TTY `codex --no-alt-screen` 的当前首轮文本路径已经有 HTTP-only 成功证据
- 当前同会话第二轮文本路径也已经有 HTTP-only 成功证据
- 当前同会话第三轮文本路径也已经有 HTTP-only 成功证据
- 当前至少一条同会话 GitHub app 业务动作在 forward-only 下成功
- 当前已观测 sidecar 请求在统一 `404` 与统一 `500` 下，都不是这三条已测文本路径的硬依赖
- 对交互 apps 工具业务动作，当前 sidecar `404/500` 会先把 `codex_apps` MCP 启动打坏，再把工具调用打成 `failed to get client`
- sidecar `500` 会把 `codex_apps` MCP 启动失败警告暴露到终端

## 5. 当前不能扩大解释

当前不能把这里的结果扩大成：

- “所有 `features.apps=true` 回合都只靠 HTTP `/responses` 就够”
- “所有 apps 相关功能都不依赖 sidecar”
- “sidecar `500` 只会产生警告，不会影响业务功能”
- “所有 app 工具家族在 forward-only 下都成功”
- “任意更深交互 apps 回合已经被覆盖”
