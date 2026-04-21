# 方案三文档索引

Date: 2026-04-20

先读：

- [docs/00-session-brief.md](/Users/norvyn/Code/Projects/ModelBridge/docs/00-session-brief.md)

## 1. 目标

本目录只服务一个目标：

- 保持前端为 `Claude Code CLI`
- 后端计费和认证走 `OpenAI subscription`
- 方案边界固定为“本地 Anthropic-compatible gateway -> 真实远端 `chatgpt.com/backend-api/codex/responses`”

这里不复述未验证结论。

任何事实性描述都必须能回到以下任一证据：

- 官方文档
- OpenAI 官方开源代码
- 本机 CLI 输出
- 本机运行态探针

总研究稿在这里：

- [2026-04-20-claude-code-openai-subscription-router.md](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md)

## 2. 当前状态

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| Claude Code 入口协议 | 已验证 | 真实探针已捕获 `/v1/messages?beta=true` 请求形状 |
| Codex 订阅登录态 | 已验证 | 本机 `codex login status` 为 ChatGPT 登录 |
| 主推理上游路径 | 已验证 | 本地 override 看到 `/responses`；默认远端已验证为 `chatgpt.com/backend-api/codex/responses` |
| 辅助产品面路径 | 已验证 | 本机探针已捕获 `/backend-api/plugins/*` 与 `/backend-api/codex/analytics-events/events` |
| `/responses` 成功响应形状 | 已验证（当前路径） | 已拿到一条真实上游成功样本，并已验证把它裁到本地最小契约后仍能 `turn.completed` |
| `/responses` websocket 是否必须 | 已验证（当前已测路径） | 当前 `codex exec --json` 单轮文本、单轮工具回合、`codex exec resume --json` 多轮文本、resumed native tool path、非交互 `features.apps=true` 的 `codex exec/exec resume` 文本路径，以及交互 `codex --no-alt-screen` 的 `features.apps=true` 首轮、同会话第二轮、同会话第三轮文本路径和一条交互 GitHub app 业务动作都可在 websocket `404` 后回落 HTTP 成功 |
| zstd 请求体字段解码 | 已验证（当前四份首轮样本） | 已解出 4 份 `/responses` 首轮请求体；顶层骨架一致，差异集中在工具清单 |
| 当前错误兼容矩阵 | 已验证（当前路径） | 已拿到 `codex exec --json`、`claude --bare -p`、默认 `claude -p` tool-use 回合的 `400 / 500 / 畸形 SSE / 断流` 第一版矩阵；交互 `codex --no-alt-screen` 且 `features.apps=true` 的首轮与同会话第二轮文本路径也已补齐 `/responses` `400 / 500 / 畸形 SSE / 断流` 外观；非交互与交互 GitHub app、非交互 Gmail app、非交互 Notion app 的 sidecar 故障外观也已补齐 |
| 辅助产品面依赖 | 已验证（当前已测路径） | 当前非交互 `features.apps=false` 主路径、非交互 `features.apps=true` 的 `exec/exec resume` 文本路径，以及交互 `features.apps=true` 的首轮、同会话第二轮、同会话第三轮文本路径，在当前已观测 `/backend-api/...` sidecar 请求统一 `404` 与统一 `500` 下都仍能完成；同时当前真实 GitHub、Gmail、Notion app 业务动作已验证：forward-only 对照成功，sidecar `404/500` 会破坏当前业务动作 |
| Claude `count_tokens` 触发时机 | 已验证（当前已测路径） | `claude --bare -p`、`claude -p`、`-r` 续轮、交互 bare、默认交互 `claude`、`claude -p -c`、默认 `claude -p` tool roundtrip、`claude -p --verbose --output-format stream-json` 都未观测到 `/v1/messages/count_tokens`；官方文档仍要求网关提供 endpoint |
| Public Responses API 直转发 | 已验证不可用 | 同样的 Bearer 和 body 转发到 `api.openai.com/v1/responses` 返回 `401` 和 `api.responses.write` scope 缺失 |
| Claude tool-use 到上游工具语义的映射 | 已验证（实例级） | 函数工具声明层重写已被真实远端接受；`Bash / Read / Edit / WebSearch / Agent / Write / TodoWrite / AskUserQuestion / mcp__claude_ai_Google_Drive__authenticate / mcp__plugin_Notion_notion__authenticate` 的 tool call / tool result 往返已验证；官方 `Advisor tool` 契约已找到；真实 `claude` 已接受 `server_tool_use + advisor_tool_result`，且 `/responses` synthetic advisor bridge 已验证成功 |
| 本地 gateway 正式代码 | 已进入运行态 | Swift package 当前已编译通过；`/v1/messages` 已从 `501` 升级为真实桥接；真实 `claude --bare -p` 文本、`Read` 工具回合、advisor 路径都已指向本地 daemon 成功完成 |
| Connector diagnostics | 已验证 | 新 `/health` 样本已经返回 `traceDiagnostics`，包含最近 stage 计数、function call 名称、connector 名称和本地 auth reject 路径 |
| Launch at login API 接线 | 已验证（API/编译） | `SMAppService.mainApp`、`Status` 枚举和 `register()/unregister()` 调用形状已在本机编译通过；真实 packaged-app register/unregister 仍待系统状态级验证 |
| Signing / notarization | 已拆分并确认阻断 | `security find-identity -v -p codesigning` 当前返回 `0 valid identities found`，所以本机只能交付脚本与 runbook，不能做真实签名与公证 |

## 3. 文档地图

1. [00-project-brief.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/00-project-brief.md)
   固定项目定义、硬约束、范围边界和当前技术判定。
2. [01-validated-baseline.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md)
   固定方案三已经证实的边界、硬约束和禁止事项。
3. [02-target-architecture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/02-target-architecture.md)
   固定方案三的目标架构、组件职责和主辅数据流。
4. [03-anthropic-edge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/03-anthropic-edge.md)
   记录 Claude Code 一侧必须满足的接口语义。
5. [04-upstream-edge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/04-upstream-edge.md)
   记录 Codex 订阅态上游的已验证边界。
6. [05-validation-matrix.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/05-validation-matrix.md)
   把剩余验证任务写成可执行矩阵。
7. [06-open-questions.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/06-open-questions.md)
   记录当前已清空 blocking 未决项后的剩余观察点。
8. [07-doc-governance.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/07-doc-governance.md)
   固定本目录的升级顺序、写作规则和证据门槛。
9. [08-responses-http-contract.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/08-responses-http-contract.md)
   记录当前 `codex exec` 单轮文本路径接受的 `/responses` HTTP 契约。
10. [09-real-upstream-capture.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/09-real-upstream-capture.md)
   固定真实远端 host/path、public API 拒绝结果和真实 SSE 样本差异。
11. [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)
   固定 Claude 工具样本、`/responses` 工具样本和当前已验证的结构差异。
12. [11-advisor-bridge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/11-advisor-bridge.md)
   固定 `advisor` 的官方契约、Claude CLI 接受性，以及 `/responses` synthetic advisor bridge 的真实成功样本。
13. [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)
   固定当前 `/responses` 与 `/v1/messages` 路径的第一版错误外观矩阵。
14. [13-sidecar-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/13-sidecar-dependency-v1.md)
   固定当前非交互主路径对 `/backend-api/...` sidecar 的依赖结论。
15. [14-count-tokens-observation-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/14-count-tokens-observation-v1.md)
   固定当前已测 Claude CLI 路径里 `/v1/messages/count_tokens` 的观测结果。
16. [15-interactive-apps-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/15-interactive-apps-coverage-v1.md)
   固定交互 TUI 且 `features.apps=true` 的 HTTP-only 与 sidecar 故障覆盖结果。
17. [16-request-shape-comparison-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/16-request-shape-comparison-v1.md)
   固定当前四份 `/responses` 首轮请求样本的共享骨架和已验证差异。
18. [17-exec-apps-resume-coverage-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/17-exec-apps-resume-coverage-v1.md)
   固定非交互 `features.apps=true` 的 `codex exec/exec resume` 文本路径在 HTTP-only 与 sidecar 故障下的覆盖结果。
19. [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)
   固定当前真实 GitHub、Gmail、Notion app 业务动作在 forward-only 和 sidecar 故障下的依赖差异。
20. [20-implementation-blueprint.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/20-implementation-blueprint.md)
   固定正式实现的产品形态、组件图、主流程和进入编码 gate。
21. [21-gateway-modules.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/21-gateway-modules.md)
   把 gateway daemon 拆成正式编码模块，并固定每个模块的职责边界。
22. [22-execution-and-acceptance.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/22-execution-and-acceptance.md)
   固定正式实现的 phase 顺序、验收矩阵和失败处理规则。

## 5. 当前代码状态

截至 `2026-04-21`，仓库里的正式代码状态是：

- `modelbridge-daemon` 已可运行，并暴露：
  - `GET /health`
  - `POST /v1/messages`
  - `POST /v1/messages/count_tokens`
- `/health` 当前已返回：
  - `messagesImplemented = true`
  - `countTokensImplemented = true`
  - `chatGPTAuthenticated = true`
  - `executorModel = "gpt-5.4"`
  - `advisorModel = "gpt-5.4"`
  - `gatewayAuthHeader = "x-api-key"`
  - `gatewayAuthTokenSuffix = "..."`
  - `configurationPath = ".../config.json"`
  - `subscriptionAuthFilePath = ".../.codex/auth.json"`
  - `tracePath = "/tmp/modelbridge-trace.jsonl"`
  - `recentTraceLines = [...]`
- 本地 gateway 当前已完成：
  - 持久化 `RouterConfiguration`
  - `x-api-key` ingress 校验
  - doctor 中的配置路径、订阅 auth 文件路径、trace 信息
  - 菜单栏里的 `Copy Env`
  - `launch at login` 状态展示与开关接线
  - connector diagnostics 摘要
  - Swift Testing 覆盖配置持久化与本地 token 校验
- `Claude Code CLI` 指向本地 daemon 后，当前真实命令已验证：
  - `claude --bare -p 'Reply exactly DEFAULTOK.'` -> `DEFAULTOK`
  - `claude --bare -p --output-format json 'Reply exactly CCRUN.'` -> `result = "CCRUN"`
  - `claude -p --output-format json 'Reply exactly FULLTOOLOK.'` -> `result = "FULLTOOLOK"`
  - `claude --bare -p --output-format json 'Use the Bash tool ...'` -> `result = "BASHOK"`
  - `claude --bare -p --output-format json 'Use the Read tool ...'` -> 完整 tool roundtrip 成功
  - `claude --bare -p --output-format json 'Use the advisor tool ...'` -> `result = "ADVISOROK"`
  - `claude -p --output-format json 'Call the mcp__plugin_Notion_notion__authenticate tool ...'` -> `result = "NOTIONAUTHSEEN"`
  - `claude --bare -p --output-format json 'Reply exactly FINALSMOKEOK.'` -> `result = "FINALSMOKEOK"`
  - `bash scripts/smoke_local_gateway.sh` -> `Smoke validation passed`
- 当前自动化验证已完成：
  - `swift build`
  - `swift test`
  - `bash scripts/build_app_bundle.sh`
  - `bash scripts/smoke_local_gateway.sh`
- 当前本地 ingress auth 已验证：
  - 错误 `x-api-key` -> `HTTP/1.1 401 Unauthorized`
  - 正确 `x-api-key` -> `HTTP/1.1 200 OK` + `{"input_tokens":1}`
- 当前 trace 日志已落到：
  - `/tmp/modelbridge-trace.jsonl`

当前还需要注意的运行边界：

- 当前本地 gateway 已验证：
  - 默认 `claude -p` 的完整工具清单可被桥接到 `/responses`
  - `advisor` 后续再触发普通 function call 的回合已修复
- 当前 `Write` / `Edit` 的强制验收 prompt 仍会受到模型自行改写路径或工具选择的影响；现有 trace 已证明当前 daemon 收到了 `Write` 与 `Edit` 的真实 function call，并完成了后续 `tool_result` continuation，但这两条 CLI prompt 还不能拿来当稳定金标准

当前仓库里新增的产品化入口：

- `docs/06-plans/2026-04-21-modelbridge-productization-plan.md`
- `docs/06-plans/2026-04-21-modelbridge-distribution-followups.md`
- `docs/06-plans/2026-04-21-modelbridge-signing-notarization-runbook.md`
- `scripts/build_app_bundle.sh`
- `scripts/smoke_local_gateway.sh`
- `scripts/sign_app_bundle.sh`
- `scripts/notarize_app_bundle.sh`
- `Tests/CCRouterCoreTests/RouterConfigurationStoreTests.swift`
- `Tests/CCRouterCoreTests/LocalGatewayAuthorizationTests.swift`
- `Tests/CCRouterCoreTests/TraceLoggerDiagnosticsTests.swift`

当前仍保留但不构成迁移 blocker 的内部兼容标识：

- Swift package 核心库产品仍叫 `CCRouterCore`
- 核心 target / source 目录仍在 `Sources/CCRouter*`
- 测试目录仍在 `Tests/CCRouterCoreTests`
- 本地配置 override 环境变量仍使用 `CC_ROUTER_*`

这些名字当前只影响包内实现和 Xcode 本地 package 连接，不影响用户看到的 app 名称、bundle 名称、trace 路径、Application Support 路径、doctor 文案或 `ANTHROPIC_BASE_URL` 接入方式

## 4. 使用规则

- 写新结论前，先补证据，再更新 `01-validated-baseline.md`
- 项目定义或范围变化，先更新 `00-project-brief.md`
- 设计决策写进 `02-target-architecture.md` 前，必须能指回一条或多条已验证事实
- 任何“还没抓到真实样本”的内容，只能进入 `05-validation-matrix.md` 或 `06-open-questions.md`
- 不允许把 `app-server` 方案和方案三混写
- 不允许把 `/wham/tasks` 写成方案三的主推理面
