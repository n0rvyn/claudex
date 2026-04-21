# 方案三验证矩阵

Date: 2026-04-20

## 1. 文档定位

本文件只记录“把方案三从已验证存在推进到可实现”所需的验证任务。

每项任务都要有：

- 明确问题
- 明确方法
- 明确通过标准
- 明确失败后如何处理

## 2. 验证矩阵

| ID | 问题 | 当前状态 | 方法 | 通过标准 | 失败后处理 |
| --- | --- | --- | --- | --- | --- |
| V-01 | `/responses` 的成功 HTTP 响应长什么样 | Resolved（当前 probe） | 用本地 probe 返回最小 SSE 成功响应，驱动 `codex exec` 完成一轮成功会话 | `codex exec` 产出 `item.completed` 与 `turn.completed` | 下一步改抓真实上游成功样本并做差异对照 |
| V-02 | websocket 是必需路径还是可选路径 | Resolved（当前路径） | 让 websocket `GET /responses` 返回 `404`，仅保留 HTTP `POST /responses` 成功流 | 当前 `codex exec --json` 单轮文本路径在 websocket 失败后仍成功 | 扩展到多轮、tools 等路径，避免把当前结论外推到所有路径 |
| V-03 | zstd 请求体解压后是什么 JSON 结构 | Resolved（当前四份首轮样本） | 抓取 `POST /responses` 原始 body，使用 zstd 流式解压并提取字段骨架；当前已覆盖非交互与交互 `features.apps=true` 的四份首轮样本 | 已形成 [16-request-shape-comparison-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/16-request-shape-comparison-v1.md)；当前四份首轮样本的顶层骨架一致，差异集中在工具清单 | 更深回合若需要继续覆盖，转入 [06-open-questions.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/06-open-questions.md) |
| V-04 | Claude 的 `/v1/messages/count_tokens` 何时会被调用 | Resolved（当前已测路径） | 针对 Claude Code 不同启动、续轮、交互与 tool-use 路径继续做本地 mock probe；当前已覆盖 `claude --bare -p`、`claude -p`、`claude --bare -p` 首轮 + `-r` 续轮、交互 TTY `claude --bare`、默认交互 `claude`、`claude -p -c`、默认 `claude -p` 的真实 tool roundtrip、`claude -p --verbose --output-format stream-json` | 已形成 [14-count-tokens-observation-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/14-count-tokens-observation-v1.md)；当前八条路径都只观测到 `/v1/messages`，没有观测到 `/v1/messages/count_tokens` | 更广路径若需要继续覆盖，转入 [06-open-questions.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/06-open-questions.md) |
| V-05 | Claude 的 tool-use 如何映射到上游 `/responses` | Resolved（实例级） | 在 Claude 侧构造带 `tools` 的真实请求样本，再对照上游成功样本；当前已验证函数工具声明层重写会被真实远端接受，且 `Bash / Read / Edit / WebSearch / Agent / Write / TodoWrite / AskUserQuestion / mcp__claude_ai_Google_Drive__authenticate / mcp__plugin_Notion_notion__authenticate` 已完成 tool call / tool result 往返；已验证 raw `advisor_20260301` passthrough 会被第一段 `/responses` 以 `400 Unsupported tool type` 拒绝；同时已验证官方 `Advisor tool` 契约、真实 `claude` 对 `server_tool_use + advisor_tool_result` 的接受性，以及 `/responses` synthetic advisor bridge 成功样本 | 已形成字段级映射表，并把剩余风险收敛到更深参数语义与未来新增工具类型 | 若后续出现新的高风险工具实例失败，再把该实例单独开成新验证项 |
| V-06 | 本地网关是否需要访问 `/backend-api/...` 才能完成主链路 | Resolved（当前已测路径） | 把主链路和辅助面分开，分别做禁用实验；当前已让 `/responses` 保持真实转发成功，同时让已观测到的 `/backend-api/...` sidecar 请求统一返回 `404` 与 `500`；当前已覆盖非交互 `features.apps=false` 主路径、非交互 `features.apps=true` 的 `exec/exec resume` 文本路径、交互 `features.apps=true` 的首轮与同会话第二轮文本路径，以及一个真实 GitHub app 业务动作 `github_get_user_login` | 已形成 [13-sidecar-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/13-sidecar-dependency-v1.md)、[15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)、[17-exec-apps-resume-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/17-exec-apps-resume-coverage-v1.md) 与 [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)；当前文本路径在 sidecar `404` 与 `500` 下仍能完成，但 `github_get_user_login` 当前已验证在 forward-only 对照下成功、在 sidecar `404/500` 下都会失败 | 若后续要覆盖其他 apps 工具家族、交互 apps 业务动作、第三轮及以上回合或新 sidecar 路径，再单独扩展 |
| V-07 | 错误返回的最小兼容要求是什么 | Resolved（当前路径） | 分别返回 4xx、5xx、畸形 JSON、断流，观察 Claude 与 Codex 的报错行为；当前已在 `codex exec --json`、`claude --bare -p`、默认 `claude -p` tool-use 回合、交互 `codex --no-alt-screen` 且 `features.apps=true` 的首轮与同会话第二轮文本路径，以及交互 GitHub app 工具回合的 sidecar `404/500` 路径上补到当前直接证据 | 已形成 [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)，并把结论限定在当前 CLI 路径；当前剩余未知已收窄到其他 app 工具家族、其他未测失败类别与其他未测入口 | 若后续要覆盖其他 app 工具家族、其他失败类别或其他未测入口，再单独扩展矩阵 |
| V-08 | 真实上游成功样本和当前 probe 契约差多少 | Resolved（当前路径） | 通过本地转发代理抓取真实订阅后端 `chatgpt.com/backend-api/codex/responses` 成功流，并和当前 probe 逐项 diff | 已拿到真实 `200` 样本；已确认真实流多出 reasoning item、`sequence_number`、`logprobs`、`obfuscation` 等字段 | 下一步把问题收窄到“这些额外字段哪些是必需” |
| V-09 | HTTP-only 可行性的覆盖范围到哪里 | Resolved（当前已测路径） | 把当前成功路径扩展到多轮、tools、不同模型或不同 CLI 入口；当前已验证 `codex exec --json` 单轮文本、单轮工具回合、`codex exec resume --json` 多轮文本、resumed native tool path、非交互 `features.apps=true` 的 `codex exec/exec resume` 文本路径、交互 `features.apps=true` 的首轮与同会话第二轮及第三轮文本路径，以及同会话一条交互 GitHub app 业务动作，都能在 websocket `404` 后只靠 HTTP `POST /responses` 完成 | 得到明确边界：当前覆盖到非交互 CLI 文本、resumed native tool path、非交互 apps 续轮文本、交互 `features.apps=true` 的前三轮文本路径，以及一条交互 GitHub app 业务动作；剩余未知收敛到其他 app 工具家族与其他未验证 CLI 入口 | 若后续要覆盖其他 app 工具家族或其他 CLI 入口，再为这些入口单独建验证项 |
| V-10 | 真实上游额外字段里哪些是必需字段 | Resolved（当前文本路径） | 基于真实上游样本，对本地代理返回做受控删字段实验，并把真实样本裁到 [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md) 的最小契约 | `baseline`、`drop_sequence_number`、`drop_reasoning_item`、`drop_annotations`、`drop_annotations_logprobs`、`drop_obfuscation`、`drop_response_extras`、`drop_all_optional`、`drop_reasoning_and_optional`、`probe_minimal` 全部得到 `turn.completed` | 把结论限定在当前文本路径；更广路径继续走 `V-09`、`V-05` |

## 3. 优先顺序

当前没有未完成验证项。

## 4. 进入实现前的最低门槛

当前没有额外 gate 项。

## 5. 结果归档规则

- 成功样本放入新的研究文档或附录
- 只要拿到新证据，先更新 [01-validated-baseline.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md)
- 若某项验证推翻当前架构目标，先更新 [02-target-architecture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/02-target-architecture.md)
