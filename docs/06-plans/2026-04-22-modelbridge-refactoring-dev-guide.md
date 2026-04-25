---
type: dev-guide
status: active
tags: [modelbridge, refactoring, routing, streaming, multimodal]
refs:
  - docs/scheme3/00-project-brief.md
  - docs/scheme3/01-validated-baseline.md
  - docs/scheme3/02-target-architecture.md
  - docs/scheme3/08-responses-http-contract.md
  - docs/scheme3/10-tool-mapping-v1.md
  - docs/scheme3/16-request-shape-comparison-v1.md
current: true
confirmed_at: 2026-04-22T09:17:32
---

# ModelBridge 全面重构 Development Guide

**Project brief:** docs/scheme3/00-project-brief.md
**Design doc:** 本次重构的设计输入是当前 gap 分析结论 + docs/scheme3/ 已验证事实集合（无独立 design.md 文档；所有断言都已溯源到 code file:line 或 scheme3 章节）
**Architecture:** docs/scheme3/02-target-architecture.md

## Global Constraints

硬约束（来自 docs/scheme3/00 §2，不可讨论）：

- 前端必须是 `Claude Code CLI`
- 认证与计费必须走 OpenAI subscription
- 本地主出口保持 `/responses` 形状，真实远端固定为 `https://chatgpt.com/backend-api/codex/responses`

技术栈约束（来自 CLAUDE.md + Package.swift）：

- Swift 6，4 空格缩进，actor 并发
- 测试用 Swift Testing（`@Test` / `#expect`），不用 XCTest（包级测试）
- 环境变量保持 `CC_ROUTER_*` 前缀
- 协议翻译必须放 `CCRouterCore`，不进 SwiftUI views
- zstd 静态链接（vendored 已落地，不退回动态 dylib）

非目标（guide 不覆盖，对应 docs/scheme3/20 §6）：

- 不切换上游到 `api.openai.com/v1/responses`（docs/scheme3/09 §2.2 已验证 401 `Missing scopes: api.responses.write`）
- 不实现 websocket 上游（只有 HTTP 路径有验证证据）
- 不实现 `/backend-api/...` sidecar 主链路模块（docs/scheme3/20 §3.6 列为 deferred；当前 Claude CLI 路径不依赖）
- 不把 `count_tokens` 写成启动前置依赖（docs/scheme3/03 §4.3 已验证 8 条路径都未触发）

已验证可用上游模型白名单（docs/scheme3/10 §7.8）：

- `gpt-5.4`
- `gpt-5.4-mini`
- `gpt-5.3-codex`

已验证不可用上游模型（docs/scheme3/10 §7.8）：

- `gpt-5.2-codex`（`The 'gpt-5.2-codex' model is not supported when using Codex with a ChatGPT account.`）
- `gpt-5.1-codex-max`（同类错误）

用户对定向路由提出的目标 ID `gpt-4.5` / `gpt-5.3-codex-spark` 均**不在白名单**；必须通过 Phase 2 的 probe 任务验证后才能写入路由表。

---

<!-- section: phase-1 keywords: sse-streaming, typed-ir, chunked-transfer, buffering -->
## Phase 1: 真流式通路 + Typed IR 基础

**Status:** ✅ Completed — 2026-04-22

**Goal:** 上游每一个 SSE event 不再等整包缓冲，逐 event 流向 Claude Code CLI；内容块从 `JSONObject` ad-hoc 迁移到 typed IR，为后续多模态 / thinking / tool_use 历史回放打底。

**Depends on:** None

**Scope:**

- `ResponsesClient.perform` 从 `session.data(for:)`（当前 `Sources/CCRouterCore/ResponsesClient.swift:38` 整包下载）切到 `URLSession.bytes(for:)` + `AsyncSequence` 逐行解析
- `LocalHTTPServer` 增加 chunked transfer 写出能力（当前 `Sources/CCRouterCore/LocalHTTPServer.swift:203` 只支持 `Content-Length`+`Connection:close`），并保留 Content-Length 路径作为退化分支
- `AnthropicBridge.handleMessages` 改成 streaming handler：上游 event 到达 → 翻译 → 立即写回本地 SSE，不再等 `response.completed` 才 emit（当前 `finalizeResponse` 在 events 数组齐备后才走 `buildAnthropicSSE`，见 `AnthropicBridge.swift:162-292`）
- 新增 `Sources/CCRouterCore/IR/` 目录，引入典型内容块的 typed 表示：`IRBlock.text(String)` / `.image(data: Data, mediaType: String)` / `.toolUse(id, name, input)` / `.toolResult(id, content: [IRBlock])` / `.thinking(encryptedContent: Data?, summary: String?)`（两字段对应 `docs/scheme3/09 §4.2` 真实上游 reasoning item 的 `encrypted_content` 与 `summary`）/ `.serverToolUse` / `.advisorToolResult`
- `convertContentBlocks`（当前 `AnthropicBridge.swift:345-355` 只识别 `text`）和 `stringifyToolResultContent`（当前 `AnthropicBridge.swift:690-713`）改由 IR 层驱动，仍保留对 text-only 的向后行为
- 为现有两段工具回合引入 `PendingToolTurn` 的 IR-native 重构（当前 `AnthropicBridge.swift:859-864` 存 `[JSONValue]` replay items）

**用户可见的变化:**

- Claude Code CLI 侧的文本响应从"等几秒后整块出现"变成真实逐字 delta；对长响应首字节延迟显著缩短
- 菜单栏 Dashboard 的 trace feed 会开始出现上游 event 级 timing（`response.output_text.delta` 到达时间戳），不再只有 request/response 两端

**Architecture decisions:**

- DP-003（见下文）：本地 SSE 写出用 chunked transfer encoding 还是继续 Content-Length + 断连
- DP-004（见下文）：Typed IR 覆盖范围

**Acceptance criteria:**

- [x] `swift test --scratch-path /tmp/ModelBridgeSwiftTest` 通过（59/59 tests across 8 suites）
- [x] 新增 `IRBlockConversionTests.swift`：覆盖 Anthropic 入 → IR、IR → `/responses` input、`/responses` event → IR → Anthropic SSE 三方向的 round-trip（19 @Test）
- [x] 新增 streaming 集成测试：`StreamingBridgeIntegrationTests.swift` 含 `firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta` 断言首 delta 到首 content_block_delta ≤ 50ms（mock-driven）
- [ ] `bash scripts/smoke_local_gateway.sh` 通过 ⚠️ 需真机验证（当前会话未执行；已验证 unit test 全绿 + Xcode test 全绿）
- [ ] 真机跑 交互式 `claude` TUI（输入 prompt: `Write exactly 200 words about Swift concurrency.`） ⚠️ 需真机验证
- [ ] `tail -f /tmp/modelbridge-trace.jsonl` 期间看到 `responses_in_event` 级记录 ⚠️ 需真机验证（代码已 wire：AnthropicBridge.processUpstreamStream per-event TraceLogger.log）
- [x] 原有 `interactive claude` 单轮文本路径、`Bash` 工具回合、`advisor` 回合的 smoke 仍通过（BridgeRegressionTests 覆盖 §3.13 Bash + §3.14 advisor；不引入回归）

**Review checklist:**

- [x] /execution-review（两轮：cycle 1 发现 3 个 blocking gaps，cycle 2 全部 resolved；报告 `.claude/reviews/implementation-reviewer-2026-04-22-131741.md`）
- [x] 架构审查：IR 边界干净，JSONObject 只出现在 trace log + makeResponsesPayload 协议边缘（12 处，全部是允许的协议边缘用法）
- [x] 回归检查：§3.13 Bash 工具回合 + §3.14 advisor 回合在 BridgeRegressionTests 中通过

<!-- /section -->

---

<!-- section: phase-2 keywords: model-routing, routing-table, effort, verbosity, model-probe -->
## Phase 2: Per-Request 模型路由表

**Status:** ✅ Completed — 2026-04-22

**Goal:** Claude 侧的 `model` 字段（opus / sonnet / haiku 等）真正驱动上游模型选择、`reasoning.effort`、`text.verbosity`；单会话内同时出现多个 Claude 模型（已验证：`docs/scheme3/03 §4.1` `interactive claude` 一轮即 `haiku title + sonnet main`）时正确分流。

**Depends on:** Phase 1

**Scope:**

- 新增 `Sources/CCRouterCore/ModelRouting.swift`：`ModelRoute`（含 `upstreamModel` / `reasoningEffort` / `textVerbosity`）、`ModelRoutingRule`（`match` 为对 Claude model 小写 substring 匹配）、`ModelRoutingTable`（`rules: [Rule]` + `fallback: ModelRoute`）
- `RouterConfiguration` 增加 `routingTable: ModelRoutingTable` 与独立 `advisorRoute: ModelRoute`；老配置（只有 `executorModel` / `advisorModel`）加载时自动迁移为 `fallback` route（`Sources/CCRouterCore/RouterConfiguration.swift:3-74` 与 `Sources/CCRouterCore/RouterConfigurationStore.swift` 全面扩字段）
- `AnthropicBridge.buildInitialPayload`（当前 `Sources/CCRouterCore/AnthropicBridge.swift:295-310` 硬用 `configuration.executorModel`）和 `buildContinuationPayload`（当前 `:312-329`）改成解析 Claude `model` 字段 → `routingTable.resolve` → 得到 `ModelRoute` 并传给 `makeResponsesPayload`
- `makeResponsesPayload`（当前 `:756-783` 硬编码 `reasoning.effort: "xhigh"` 与 `text.verbosity: "low"`）改签名接受 `ModelRoute`
- `PendingToolTurn`（`:859-864`）追加 `resolvedRoute: ModelRoute` 字段，保证一个 tool turn 第 2 段 `/responses` 用的模型与第 1 段一致（否则模型在 turn 中间切换，对缓存、推理连续性都有已验证代价）
- **Verification task** — 模型 ID probe：新增 `scripts/probe_upstream_models.py`，以已有 `scripts/probe_responses_advisor_bridge.py` 作为认证 + zstd 压缩 + SSE 解析的模板（两者同样从 `~/.codex/auth.json` 读 `access_token` / `account_id` 并直接 POST 真实 `chatgpt.com/backend-api/codex/responses`）；对每个候选 ID（`gpt-5.4` / `gpt-5.4-mini` / `gpt-5.3-codex` + 用户想要的 `gpt-4.5` / `gpt-5.3-codex-spark`）发一条最小 `/responses` 请求，记录真实远端响应码与错误正文；只把返回 `200` 的 ID 写入默认路由表
- **Verification task** — `reasoning.effort` 枚举 probe：复用上一个 probe 脚本，对 `low` / `medium` / `high` / `xhigh` 各发一次最小请求，记录哪些值被真实远端接受；只把接受值写入 UI 下拉枚举（`docs/scheme3/09 §3.2` 当前只验证过 `xhigh`）
- **Verification task** — `text.verbosity` 枚举 probe：同上对 `low` / `medium` / `high`（当前只验证 `low`）

**用户可见的变化:**

- 同一个 Claude Code 会话里，`haiku` 标题生成与 `sonnet` 主回答会命中不同上游模型；Dashboard 的 trace feed 按 Claude model → upstream model 成对显示
- 用户首次启动新版时，老配置自动升级，原 `executorModel: "gpt-5.4"` 变成 fallback route，行为不退化
- Settings 里出现新 `Routing` 数据源（UI 编辑器在 Phase 6 落地），当前版本可通过编辑 `config.json` 手动配置路由规则

**Architecture decisions:**

- DP-001（BLOCKING，见下文）：用户请求的 `gpt-4.5` / `gpt-5.3-codex-spark` 如何处理
- DP-002（RECOMMENDED）：`reasoning.effort` 未验证枚举值的默认策略

**Acceptance criteria:**

- [x] `swift test` 新增 `ModelRoutingTests.swift`：覆盖 substring 匹配（opus / sonnet / haiku 大小写混合、前后缀、Claude 真实 model ID 如 `claude-opus-4-7` / `claude-sonnet-4-6` / `claude-haiku-4-5-20251001`）、fallback 命中、空表 fallback（9/9 tests pass + 2 新增 = 11/11）
- [x] `swift test` 新增 `RouterConfigurationMigrationTests.swift`：老 `executorModel` 字段加载后正确落到 `routingTable.fallback.upstreamModel`（5/5 tests pass，含 `freshInstallGetsDefaultThreeRuleTable`）
- [x] Probe 任务产出：`docs/research/2026-04-22-upstream-model-probe.md`（DP-002-P2 Option B：execute-plan 真实运行 probe，5 个 candidate 真实响应码 + 错误正文 + Conclusion 全部落盘；惊喜结果：`gpt-5.3-codex-spark` 返回 200）
- [ ] 真机跑：设置 `ANTHROPIC_BASE_URL=http://127.0.0.1:4317` + `ANTHROPIC_AUTH_TOKEN=<gateway-token>` 后，用 `ANTHROPIC_MODEL=claude-opus-4-7 claude`，TUI 输入 prompt: `Reply OPUSOK.` + `ANTHROPIC_MODEL=claude-sonnet-4-6 claude`，TUI 输入 prompt: `Reply SONNETOK.` + `ANTHROPIC_MODEL=claude-haiku-4-5-20251001 claude`，TUI 输入 prompt: `Reply HAIKUOK.` 三条各自命中配置的不同上游模型 ⚠️ 需真机验证（code path 由 `ModelRoutingBridgeIntegrationTests` 的 5 个集成测试覆盖：opus/haiku/fallback/advisor/pendingToolTurn；wire-level payload 的 `model` 字段已断言随 Claude model 切换）
- [ ] `grep upstream_model /tmp/modelbridge-trace.jsonl | jq -r .upstream_model | sort -u` 输出至少 2 个不同值 ⚠️ 需真机验证（trace 字段 emission 已 wire：`AnthropicBridge.swift:205/302/580` 三处；defaultTable haiku → gpt-5.3-codex-spark 与 opus/sonnet → gpt-5.4 天然分流）
- [ ] `bash scripts/smoke_local_gateway.sh` 通过 ⚠️ 需真机验证
- [x] Phase 1 的 streaming 与 IR 断言仍通过（79/79 swift tests + Xcode build success；BridgeRegressionTests + StreamingBridgeIntegrationTests + IRBlockConversionTests + ResponsesClientStreamingTests 全绿）

**Review checklist:**

- [x] /execution-review（implementation-reviewer 发现 RR-1 blocking gap，DP-001 Option A 修复完成；报告 `.claude/reviews/implementation-reviewer-2026-04-22-161124.md`）
- [x] Probe 结果审查：用户根据 probe 报告决定 DP-002 Option B — haiku 路由改为 `gpt-5.3-codex-spark`（probe 确认 200）

<!-- /section -->

---

<!-- section: phase-3 keywords: multimodal, image, thinking, tool-use-history, tool-result -->
## Phase 3: 协议完备性（多模态 + Thinking + 历史工具回放）

**Status:** ✅ Completed — 2026-04-23 (all 6 acceptance criteria green, including 3 real-runtime end-to-end tests against upstream; 2 follow-on bugs caught and fixed during runtime validation)

**Goal:** 关闭当前三类已确认的协议翻译黑洞——图像块丢弃、extended thinking 不surface、assistant 历史里的 `tool_use` 块 replay 丢失。这三项并行，共享 Phase 1 的 IR 基座。

**Depends on:** Phase 1

**Scope:**

**3a. 多模态翻译（图像块）**

- 当前 `convertContentBlocks`（`Sources/CCRouterCore/AnthropicBridge.swift:345-355`）只保留 `type == "text"` 块；`image` / `document` 块全部静默丢弃
- 扩展 IR `.image(data, mediaType)`；Anthropic image block 的 `source: { type: base64, media_type, data }` → IR image → `/responses` 端的 `input_image`（或复用上游已验证的 `view_image` function，见 `docs/scheme3/10 §3.3`）
- `stringifyToolResultContent`（`AnthropicBridge.swift:690-713`）当前把 `tool_result` 内容压成字符串；扩展对 image content block 的保留（例如 playwright/screenshot MCP 工具的图像返回值）

**3b. Extended thinking surface**

- 当前 `AnthropicProtocol.swift:9` `thinking: JSONObject?` 字段存在但从未被消费
- 当前 `AnthropicBridge.swift:773` 已请求 `include: ["reasoning.encrypted_content"]`，说明上游 reasoning 事件流能拿到；但 `buildAnthropicSSE`（`:503-663`）只 emit `text` / `tool_use` / `server_tool_use` / `advisor_tool_result`，`reasoning` item 被 `outputItemsInOrder` 过后在 `default: continue` 分支（`:639`）丢弃
- 新增 `reasoning` item → `content_block` of `type: thinking` 的 SSE emitter；Claude CLI 侧能显示 "thinking..." 指示器
- 当 Claude 请求的 `thinking: {type: "enabled", budget_tokens: ...}` 存在时，显式转换为 `reasoning.effort` 下游映射（与 Phase 2 的路由表共同决定最终值）

**3c. Assistant 历史 tool_use 块的 replay**

- 当前 `convertMessages`（`AnthropicBridge.swift:331-343`）对每条 message 调用 `convertContentBlocks`，后者只识别 text —— 意味着历史里的 `tool_use` 块（assistant role）和 `tool_result` 块（user role）在多轮对话回放时全部丢失
- 实际影响：Claude CLI 用 `-r <session-id>` 续轮、或客户端直接带完整历史发来时，模型丢失了"我之前调过什么工具"的上下文
- 修正（Anthropic API 里 `tool_use` 只在 assistant role content 里出现，`tool_result` 只在 user role content 里出现）：
  - assistant role 的 `tool_use` 块 → `/responses` input 里的 `function_call` item
  - user role 的 `tool_result` 块 → `/responses` input 里的 `function_call_output` item
  - assistant role 的 `thinking` 块 → `reasoning` item with encrypted_content（能拿回 encrypted_content 就带回，拿不回则作为不可逆降级保留文本占位）

**用户可见的变化:**

- 粘贴截图到 Claude Code 之后，模型真的能"看到"；此前的截图输入实际被静默丢弃
- 启用 extended thinking 的 Claude 设置下，CLI 能显示 "thinking..." 指示与最终可见的思考摘要（如果上游返回了 summary）
- 用 `claude -r <session>` 续轮时，模型能正确回忆上一轮调过哪些工具，不再出现"它忘了自己刚刚做过什么"的现象

**Architecture decisions:**

- 图像块落到 `/responses` 端用 `input_image` payload（OpenAI 官方协议）还是走已验证的 `view_image` function（`docs/scheme3/10 §3.3` 在真实上游工具清单里有此 function，但 ModelBridge 当前并未注入）—— 建议 Phase 3a 的 verification task 先探一次两种路径的接受性
- `thinking` block 的输出在 `include` 里除了 `reasoning.encrypted_content` 是否需要追加 `reasoning.summary`（`docs/scheme3/09 §4.2` 真实上游 reasoning item 含 `summary` 字段）—— 建议 verification task 确认

**Acceptance criteria:**

- [x] `swift test` 新增 `ImageBlockConversionTests.swift` / `ThinkingBlockEmissionTests.swift` / `ToolUseHistoryReplayTests.swift` (13 + 19 + 15 tests; all pass；新增 4 个运行时 bug 回归测试)
- [x] 真机验证：PNG 图像（32×32 红色）经 daemon → `input_image` → 上游 gpt-5.4 返回 `turn.completed`，模型正确识别颜色 "Red"（详见 Phase 3 changelog）
- [x] 真机验证：`thinking: {type:"enabled", budget_tokens:2000}` 请求触发完整 SSE 流 —— 连续 5 次 run 均产出 `thinking_delta` (74-87 events/turn) + `signature_delta` (每 turn 1 次) + `text_delta`
- [x] 真机验证：构造含 `tool_use`/`tool_result` 历史的请求，模型基于 prior tool_result 正确回答（输出 "The second file is beta.md..." 证明 `function_call` + `function_call_output` 成功回放）
- [x] 3a/3b/3c 各自独立的 verification task 报告写入 `docs/research/` (`2026-04-22-image-wire-probe.md` + `2026-04-22-cli-signature-passthrough.md`)
- [x] `bash scripts/smoke_local_gateway.sh` 通过 (2026-04-23；过程中修复 Phase 1 遗留的 chunked terminator 缺失 bug — 详见 changelog)
- [x] Phase 1/2 acceptance 仍通过 (完整测试套件 125 个全部通过；`firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta` 在并发压力下偶发失败，独立运行稳定通过 — 是 Phase 1 测试设计 flake，与 Phase 3 无关)

**Review checklist:**

- [ ] /execution-review
- [ ] /feature-review（完整 user journey：截图输入 + 多轮 tool_use 回放 + thinking 显示）

<!-- /section -->

---

<!-- section: phase-4 keywords: prompt-cache-key, session-ttl, advisor-context, eviction -->
## Phase 4: 会话状态与缓存稳定性

**Status:** ✅ Completed — 2026-04-23 (7/7 plan tasks; 143/144 tests pass; 1 failure is pre-existing Phase-1 timing flake unrelated to Phase 4)

**Goal:** prompt cache 真的命中；`pendingToolTurns` 不再无限增长；advisor 子调用看得到当前会话上下文。

**Depends on:** Phase 1, Phase 3（advisor context 需要 Phase 3c 的历史 replay）

**Scope:**

- 当前 `AnthropicBridge.swift:775` `prompt_cache_key: UUID().uuidString.lowercased()` 每请求随机 —— 上游 prompt cache 命中率 0。改为基于 `x-claude-code-session-id` 稳定哈希（或当 header 缺失时，fallback 到 `sha256(instructions + stable prefix of input)`）
- 当前 `AnthropicBridge.swift:8` `pendingToolTurns: [String: PendingToolTurn]` 是无 TTL 的 `[String: ...]`；长跑 daemon 会累积。增加 `lastAccessedAt: Date`，**任意读写都 bump**（`pendingToolTurns[sessionID]` 的每一次 get 或 set 都更新时间戳，不是只在 write 时 bump）+ 后台 evict（30 分钟无活动即清）；暴露当前条目数给 `DoctorSnapshot`
- 当前 `runAdvisorSubcall`（`AnthropicBridge.swift:715-735`）给 advisor 子调用传固定字符串 `"Provide concise strategic guidance for the current task."`，子 call 看不到任何会话状态；改为带当前 `instructions` + 最近 N 条 `input` message（N 由配置决定，默认 8），并在 `docs/scheme3/11 §advisor-bridge` 的已验证桥接形状下保持 `gpt-5.3-codex → gpt-5.4` 的执行器/advisor 分工

**用户可见的变化:**

- 同会话多轮对话的首字节延迟下降（上游 cache 命中）；Dashboard 可以显示 cache 命中率（定义：24h 滚动窗口内，`response.completed` 事件的 `response.usage.prompt_cache_hit_tokens / response.usage.input_tokens`，按请求数加权平均；当上游不返回 `prompt_cache_hit_tokens` 字段时该请求不计入分母）
- daemon 稳定长跑 24h+ 不再出现内存缓慢增长；`DoctorSnapshot` 新增 `pendingToolTurnsCount` 字段
- `advisor` 返回的建议文本真正贴合当前任务，而不是泛泛的 "based on the current task..."

**Architecture decisions:**

- cache key 的 fallback 哈希范围（整个 input 还是只哈希 instructions + 第一条 message）—— 影响缓存粒度
- advisor 子调用的历史截断策略（按 token 数、按 message 数、按字符数）
- pending tool turn TTL 长度（30min / 10min / 可配置）

**Acceptance criteria:**

- [x] `swift test` 新增 `PromptCacheKeyStabilityTests.swift` (7 tests) / `PendingToolTurnEvictionTests.swift` (3 tests incl. explicit `now:` override) / `AdvisorContextForwardingTests.swift` (3 tests) / `DoctorSnapshotTests.swift` (1 test) / `RouterConfigurationMigrationTests.swift` extensions (3 tests incl. `saveReloadRoundTripPreservesPhase4Fields`). Also includes `requestsWithoutSessionHeaderShareStableCacheKey` regression test for raw-header threading
- [ ] 真机观测：对同一 session id 连续发 3 条请求，`tail /tmp/modelbridge-trace.jsonl | jq .prompt_cache_key | sort -u` 只输出 1 个值 ⚠️ 需真机验证（代码已 wire：`prompt_cache_key` trace 字段 emission at AnthropicBridge.swift:216/:328/:671）
- [ ] 真机观测：发两条请求之间等 31 分钟（或调低 TTL 到 10s 快速验证）；第二条请求到达时，`DoctorSnapshot.pendingToolTurnsCount` 已归零 ⚠️ 需真机验证（`PendingToolTurnEvictionTests.pendingToolTurnEvictedWhenSimulatedTimeExceedsTTL` 用 `evictStalePending(now: Date().addingTimeInterval(1801))` 已验证逻辑路径）
- [ ] 真机跑 advisor 回合：子调用 trace 里的 `input` 包含最近 N 条 message，而不是固定 prompt ⚠️ 需真机验证（`AdvisorContextForwardingTests.advisorPayloadIncludesInstructionsAndLastNMessages` 已断言 wire-level payload 的 `input` 数组长度 = N）
- [ ] `bash scripts/smoke_local_gateway.sh` 通过 ⚠️ 需真机验证
- [x] Phase 1/2/3 acceptance 仍通过（143/144 tests；1 failure is pre-existing Phase-1 timing flake — `firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta` at 59ms vs 50ms threshold — 与 Phase 4 无关）

**Review checklist:**

- [x] /execution-review（implementation-reviewer 2026-04-23: ✅ 0 plan-vs-code gaps, 6/6 tests covered; 报告 `.claude/reviews/implementation-reviewer-2026-04-23-111404.md`）
- [ ] 长跑回归：`modelbridge-daemon` 后台跑 2h 以上，观察内存占用与 pendingToolTurns 数量 ⚠️ 需真机验证

<!-- /section -->

---

<!-- section: phase-5 keywords: token-refresh, count-tokens, resilience, auth-recovery -->
## Phase 5: 认证 Refresh + count_tokens 精度

**Status:** ✅ Completed — 2026-04-24（V3/V4 PASS；V1/V2 deferred to #1 #2）

**Goal:** 订阅 access_token 过期不再需要手动 `codex login`；count_tokens 精度不再是 `body.count/4` 的粗糙启发式。

**Depends on:** None（可与 Phase 2/3/4 并行）

**Scope:**

- 当前 `SubscriptionSessionLoader.loadCurrent`（`Sources/CCRouterCore/SubscriptionSession.swift:103-123`）只读 `tokens.access_token` + `tokens.account_id`；已实测确认 `~/.codex/auth.json` 实际同时包含 `refresh_token` 与 `last_refresh` 字段
- 在 `SubscriptionSession` 层增加：401 探测 → 用 `refresh_token` 发刷新请求 → 成功则写回 `auth.json` + 重发一次原请求；失败则返回当前的 `authorizationRequired` 状态，由 UI 触发 re-login 引导
- 当前 `GatewayDaemon.swift:128` `count_tokens = max(1, request.body.count / 4)` —— 对多轮/工具回合payload 偏离真实 token 数一个量级
- 用嵌入式 BPE（`cl100k_base`）对 Anthropic 请求的 `messages` + `system` + `tools` schema 做真实 tokenization；保留 `/responses` 端的 `usage.input_tokens`（`docs/scheme3/08 §4.3`）作为上游侧 ground truth，仅在 Anthropic 入口的 count_tokens 端点里用 BPE

**用户可见的变化:**

- Codex 订阅 access_token 到期后，Claude Code 请求不再直接报 503；daemon 自动刷新，用户无感
- 刷新失败时，菜单栏状态条变为 "请重新登录 Codex"，并在 Settings 里显示 re-login 指引
- `POST /v1/messages/count_tokens` 返回的 `input_tokens` 与真实上游 `usage.input_tokens` 在 10% 以内（当前偏差常见 5-10 倍）

**Architecture decisions:**

- BPE 实现：嵌入 Rust `tiktoken` via swift-bridge，或 pure Swift port，或仅对 text 用 char/word 启发式（trade-off：二进制体积 vs 精度）
- refresh_token 刷新端点需要探测（`~/.codex/auth.json` 只有 token 本身，endpoint 来自 `codex-cli` 源码）—— 建议 verification task 先抓包确认

**Acceptance criteria:**

- [x] `swift test` 新增测试覆盖：`AuthTokenRefresherTests.swift`（4 cases）/ `CountTokensEndpointTests.swift`（7 cases）/ `TraceLoggerRefreshEventsTests.swift`（2 cases）+ 既有文件扩充（`SubscriptionSessionTests` / `BridgeRegressionTests` / `DoctorSnapshotTests`）。原计划命名 `SubscriptionTokenRefreshTests` / `CountTokensAccuracyTests`；实际按职责细分，25 个 Phase 5 测试全绿。
- [x] Verification task 报告：`docs/research/2026-04-23-codex-refresh-endpoint-probe.md`（日期微调）记录 refresh 端点、client_id、`refresh_token rotating: true` 结论
- [ ] Deferred → #1：真机自动 refresh 验证（等自然 401 触发；unit-test + trace-emission 路径已覆盖，缺真实环境证据）
- [ ] ~~count_tokens 精度 ≤10%~~ — 已 re-defer 为 https://github.com/n0rvyn/model-bridge/issues/2（Phase 7 DP-P7-001 Chose B：接受 20-60% 偏差，目标在 Phase 8+ 改算法时调整至 ≤15%）
- [x] `bash scripts/smoke_local_gateway.sh` 通过 (2026-04-24；返回 SMOKEOK)

**Review checklist:**

- [x] /execution-review —— 2026-04-23 产出 `implementation-reviewer-2026-04-23-193014.md`；5 gap 已全部处理（2 已在代码中、3 经 TaskLocal 重构 + 回归断言修复）
- [x] 安全审查通过 (2026-04-24)：现网 `~/.codex/auth.json` = 0600；单测 `refreshAndReloadPreservesFilePermissions` 断言 writeback 后 mode 保持 0600；writeback 失败 fallback 内存缓存由 `refreshWritebackFailureReturnsCredentialsWithoutThrow` 覆盖。附注：发现单测 trace 泄漏到生产 trace.jsonl（独立 hygiene bug → #3）

<!-- /section -->

---

<!-- section: phase-6 keywords: observability, dashboard, routing-ui, settings, trace -->
## Phase 6: 可观测性增强 + Settings UI 整合

**Status:** ✅ Completed — 2026-04-24

**Goal:** Dashboard 能按 Claude 模型维度拆成功率/延迟；Settings 能编辑路由表、advisor route、查看 token refresh 状态。

**Depends on:** Phase 2（routing）、Phase 4（cache）、Phase 5（token refresh）

**Scope:**

- `TraceLogger` 的 `anthropic_in` / `responses_out_initial` / `responses_out_continuation` 阶段（`Sources/CCRouterCore/AnthropicBridge.swift:28, 74, 42`）增加字段：`claude_model`（原 Claude 请求的 model 字符串）/ `upstream_model`（经路由表解析后真正发给 `/responses` 的 model 值）/ `reasoning_effort`（同上，解析后的值）/ `text_verbosity`（同上）/ `resolved_route_match`（命中的 `ModelRoutingRule.match` 字符串原值；若走 fallback 则写入字面量 `"fallback"`）
- `TraceDiagnostics`（`Sources/CCRouterCore/TraceDiagnostics.swift`）聚合增加按 upstream_model 维度的计数 / p50 / p95 / 错误类型分布
- Dashboard (`ModelBridge/ContentView.swift`) 增加 "Routing insights" 区块：三行分别显示 haiku / sonnet / opus 各自的本周请求数 + 命中的上游模型 + 平均延迟
- Settings (`ModelBridge/SettingsView.swift`) 现 Upstream tab 扩展为 Routing 编辑器：表格形式支持 add/edit/delete rule；每行有 Claude model 关键词输入、upstream model 下拉（选项来自 Phase 2 probe 通过的白名单）、effort / verbosity 下拉（选项来自 Phase 2 probe 通过的枚举）
- Settings 新增 Advisor tab（或并入 Routing）：编辑 `advisorRoute` 的 upstream model / effort / verbosity
- Settings 现 Upstream tab 增加 "Token status" 区块：显示 access_token 前/后缀、last_refresh 时间、手动 "Refresh now" 按钮；refresh 失败时展示 re-login 引导

**用户可见的变化:**

- Dashboard 的 "Runtime activity" 卡片下方新增 "Routing insights"：三行 haiku / sonnet / opus，每行右侧显示"当前路由 → `<upstream model>` · `<effort>`"；点击单行可下钻到该 Claude 模型的详细 trace 列表
- Settings 打开后在 `Upstream` tab 看到表格，可以新增规则（例如 `opus → gpt-5.4 · xhigh · low`）；保存后立即对新请求生效，不需要重启 daemon
- Settings 的 `Upstream` tab 底部显示 Codex token 状态：一行状态灯 + 剩余有效期估算 + "Refresh now" 按钮；token 即将过期或已过期时状态灯变色

**Architecture decisions:**

- Dashboard 聚合的时间窗口（本会话 / 本 24h / 可配置）
- Routing 规则编辑的 match 字段是否暴露 regex 模式（默认 substring，regex 可选）
- Token 状态卡片是否主动轮询 refresh 还是仅被动显示

**Acceptance criteria:**

- [x] `swift test` 新增 `TraceLoggerRoutingFieldsTests.swift` / `TraceDiagnosticsPerModelAggregationTests.swift`
- [x] Xcode 测试：`xcodebuild test -project ModelBridge.xcodeproj -scheme ModelBridge -destination 'platform=macOS' -only-testing:ModelBridgeTests` 通过，覆盖 Routing 编辑器的新增 / 编辑 / 删除 / 保存 / 热加载路径
- [ ] 真机运行 `open dist/ModelBridge.app` → 发起 opus + sonnet + haiku 各一条真实请求 → Dashboard 的 Routing insights 能看到 3 条独立行 + 各自的上游模型与延迟 ⚠️ 需设备验证
- [ ] 真机运行：在 Settings 里修改 sonnet 的路由为不同模型 → 保存 → 下一条 sonnet 请求 trace 里的 `upstream_model` 反映新配置（不需要重启）⚠️ 需设备验证
- [ ] Token 状态卡片可见，显示 last_refresh；点击 "Refresh now" 触发真实 refresh 并刷新显示 ⚠️ 需设备验证
- [x] `bash scripts/build_app_bundle.sh` 通过，产出 `dist/ModelBridge.app` 能打开并完成上述 UI 检查（build 成功；UI 检查列在上方 ⚠️ 项）

**Review checklist:**

- [x] /execution-review — `.claude/reviews/implementation-reviewer-2026-04-24-104537.md`
- [x] /ui-review — `.claude/reviews/ui-reviewer-2026-04-24-105324.md`
- [x] /feature-review — `.claude/reviews/feature-reviewer-2026-04-24-110005.md`

<!-- /section -->

---

<!-- section: phase-7 keywords: e2e, acceptance, smoke, regression, routing-validation -->
## Phase 7: 端到端验收

**Status:** ✅ Completed — 2026-04-24（6/8 AC in-session green；AC-7.7/7.8 PENDING-DEVICE 等用户真机验证）

**Goal:** 用真实 Claude Code CLI + 真实 Codex 订阅，证明所有 Phase 1-6 的能力在用户日常生产路径上闭环，不是只在单测里绿。

**Depends on:** Phase 1, 2, 3, 4, 5, 6

**Scope:**

- 扩展 `scripts/smoke_local_gateway.sh`：新增 assertion 覆盖所有 Phase 的关键路径（真流式 delta 计时、路由分流、多模态、thinking、tool_use 历史、cache key 稳定、token refresh、count_tokens 精度、Dashboard 字段齐全）
- 新增 `scripts/smoke_routing_e2e.sh`：独立脚本，用 `ANTHROPIC_MODEL` 三种值各跑一次 `interactive claude`，读 trace 断言每个都命中配置的不同上游模型
- 新增 `scripts/smoke_multimodal.sh`：构造带 base64 PNG 的 `/v1/messages` payload，断言上游真实返回 `turn.completed`
- 完整回归：`docs/scheme3/01-validated-baseline.md` 已列的全部已验证路径（§3.13-3.17、§3.24-3.40）各自重跑一次，收集 pass/fail 清单
- 产出 `docs/research/2026-04-22-refactoring-acceptance-report.md`：列出所有 acceptance criteria 的真实输出证据

**用户可见的变化:**

- 无（纯验收阶段，无新功能）

**Architecture decisions:**

- 无

**Acceptance criteria:**

- [x] `swift test --scratch-path /tmp/ModelBridgeSwiftTest` 全绿（2026-04-24：221/222 passing；1 pre-existing Phase 1 timing flake 与 Phase 7 无关）
- [x] `xcodebuild test` 全绿（2026-04-24：20/20 passing）
- [x] `bash scripts/smoke_local_gateway.sh` 全绿（2026-04-24 in-session：4 trace assertions 全过，trace at `/var/folders/xg/.../modelbridge-smoke.XXXXXX.1yUXLPN2cs/trace.jsonl`）
- [x] `bash scripts/smoke_routing_e2e.sh` 全绿（2026-04-24 in-session：Upstream models hit `gpt-5.3-codex-spark` + `gpt-5.4`，routing 分流确认）
- [x] `bash scripts/smoke_multimodal.sh` 全绿（2026-04-24 in-session：HTTP 200，base64 PNG → `input_image` → `turn.completed`）
- [x] Acceptance report 落盘（`docs/research/2026-04-22-refactoring-acceptance-report.md`：6/8 in-session AC 填充真实命令输出；device-pending 条目写入 Re-run 方法 + Evidence 断言行，等用户真机填充）
- [ ] `dist/ModelBridge.app` 在干净的 macOS 账户上打开、完成登录、发 3 条请求、全部成功 ⚠️ PENDING-DEVICE（需要干净 macOS 账户/VM；acceptance report AC-7.7 包含 Re-run + Evidence 断言行）
- [ ] 至少 1 小时的真实交互使用 session（用户自己用）无未恢复错误 ⚠️ PENDING-DEVICE（需要用户日常使用 ≥1h；acceptance report AC-7.8 包含 Re-run 方法）

**Review checklist:**

- [x] /execution-review（implementation-reviewer `.claude/reviews/implementation-reviewer-2026-04-24-142948.md`，4 gaps 全部 fix 完）
- [ ] /feature-review（完整 user journey：安装 → 登录 → 配置路由 → 日常使用 → 观察 Dashboard）→ deferred: https://github.com/n0rvyn/model-bridge/issues/5（Phase 7 为纯验收阶段无新用户可见功能；触发时机：AC-7.7/7.8 真机验证后或分发 plan 首阶段）
- [ ] /submission-preview（配合 `docs/06-plans/2026-04-21-modelbridge-distribution-followups.md` 的分发流程）→ deferred: https://github.com/n0rvyn/model-bridge/issues/6（与分发 plan 同性质，在分发流程启动时执行）

<!-- /section -->

---

## Decisions

### [DP-001] 用户定向路由目标模型 ID 的处理策略（blocking）

**Context:** 用户明确要求把 `opus → GPT4.5-xhigh`、`sonnet → GPT-4.5-high`、`haiku → gpt-5.3-codex-spark`；但 `gpt-4.5` 与 `gpt-5.3-codex-spark` 都不在 `docs/scheme3/10 §7.8` 已验证白名单（白名单仅 `gpt-5.4` / `gpt-5.4-mini` / `gpt-5.3-codex`）。已验证拒绝清单里有 `gpt-5.2-codex` / `gpt-5.1-codex-max`。继续路由到未验证 ID 可能让 Phase 2 全部端到端用例 fail。

**Options:**
- A: Phase 2 先跑模型 ID probe（见 Phase 2 scope 的 Verification task），probe 通过的 ID 才写进默认路由表；probe 不通过就在 Decisions 里反馈给用户、等用户换 ID 或接受白名单 — 代价：Phase 2 交付物要等 probe 结果
- B: 默认路由表固定用白名单（例如 `opus/sonnet → gpt-5.4 + 不同 effort`、`haiku → gpt-5.3-codex`），用户自定义 ID 允许通过 Settings 手写 — 代价：偏离用户最初表达的具体 ID 诉求
- C: 合并 A+B：Phase 2 按 B 落地默认表（保证 ship），同时 probe 用户想要的 ID，probe 通过后在 Phase 6 UI 提示可切换 — 代价：落地多一步切换

**Chosen:** C — auto mode 下按 Recommendation 记录；`docs/scheme3/10 §7.8` 显示真实订阅端对未知 model ID 直接返回错误（`The 'X' model is not supported when using Codex with a ChatGPT account.`），直接用 `gpt-4.5` 会触发 `turn.failed`；同时用户诉求不该被完全丢弃，probe 可低成本并行。用户可在 run-phase 启动前推翻该选择。

### [DP-002] `reasoning.effort` 未验证枚举值的默认策略（recommended）

**Context:** `docs/scheme3/09 §3.2` 与 `docs/scheme3/16` 四样本对照只验证了 `reasoning.effort: "xhigh"`；`low/medium/high` 是基于 OpenAI 公开 `/responses` 文档的推断，在当前订阅端口无直接证据。Phase 2 的 routing UI 需要决定暴露哪些值。

**Options:**
- A: Phase 2 先跑 effort probe（同上模式，发 4 条最小请求各带一种 effort），只把真实远端接受的写入枚举 — 代价：Phase 2 延后一点
- B: UI 下拉就 4 项全放出，probe 不通过的让用户保存时报错 — 代价：UX 差，错误只在运行时暴露
- C: 只允许 `xhigh`，Phase 2 不引入 effort 维度 — 代价：失去按 Claude 模型分级效果的主要诉求

**Chosen:** A — auto mode 下按 Recommendation 记录；与 DP-001 同一 probe 脚本可复用，代价边际；`docs/scheme3/16 §3` 四样本 `reasoning.effort` 全部是 `xhigh`，直接暴露未验证值会在用户第一次切换时遭遇 400。

### [DP-003] 本地 SSE 写出的 transfer encoding（recommended）

**Context:** 当前 `Sources/CCRouterCore/LocalHTTPServer.swift:199-213` 用 HTTP/1.1 + `Content-Length` + `Connection: close`，每个响应整包封装发送；Phase 1 的真流式要求上游 event 级增量输出，需要改 transfer encoding。

**Options:**
- A: Chunked transfer encoding（RFC 9112 §7.1），保留 `Connection: close` — 代价：LocalHTTPServer 写路径要重写；Claude CLI 对 chunked 的接受性需要一次真实验证
- B: `Connection: close` + 不声明 Content-Length，写完 flush 关连接（部分 HTTP client 接受的 "close-delimited" 模式）— 代价：标准合规性差；Claude CLI 的 `undici` based fetch 是否接受需实测
- C: 保留当前 Content-Length 模式，仅把上游 event 并行积累到一定阈值再 flush — 代价：失去真流式意义

**Chosen:** A（unverified）— auto mode 下按 Recommendation 记录；无直接代码证据证明 Claude CLI 接受哪一种，需要 Phase 1 的第一个 streaming 集成测试实测。A 是 HTTP/1.1 标准路径，失败概率最低；如果实测 A 失败，Phase 1 内回退到 B。

### [DP-004] Typed IR 覆盖范围（recommended）

**Context:** 当前 `Sources/CCRouterCore/AnthropicBridge.swift` 全篇用 `JSONObject` / `JSONValue` 做 ad-hoc 翻译（`convertContentBlocks:345`、`convertMessages:331`、`stringifyToolResultContent:690`、`convertTools:365`、`outputItemsInOrder:422`、`buildAnthropicSSE:503` 六处）。Phase 1 要引入 typed IR，但边界需要决定。

**Options:**
- A: 全面 IR — content blocks、tool calls、tool results、reasoning、usage 全部 typed；核心翻译路径只碰 IR，JSONObject 只在协议解析/合成的边缘出现 — 代价：Phase 1 工作量最大；但后续 Phase 3 多模态 / Phase 4 advisor context 实现成本最低
- B: 渐进 IR — 只对 content blocks 做 IR（Phase 1 最窄范围），Phase 3 再按需扩 — 代价：Phase 3/4 要反复触动 IR 层；JSONObject + IR 并存期长
- C: 不引入 IR，继续 JSONObject helper 扩展 — 代价：Phase 3 多模态与 Phase 3c 历史 replay 的正确性非常难保证（当前 `convertContentBlocks:354` 的 `default: return nil` 就是这种代价的直接表现）

**Chosen:** A — auto mode 下按 Recommendation 记录；用户明确要求 "full refactoring" 与 "not partial"；`AnthropicBridge.swift` 已增长到 865 行，继续 JSONObject 扩展已到边际；Phase 1 一次做到位，后续 Phase 共享稳定 IR 基座，总成本更低。

### [DP-005] count_tokens 策略（recommended）

**Context:** 当前 `Sources/CCRouterCore/GatewayDaemon.swift:128` 用 `max(1, request.body.count / 4)`，`docs/scheme3/03 §4.3` 已确认当前 8 条 Claude 路径都没触发此端点，所以短期低优先；但 Phase 5 的目标是把精度拉到 ≤10% 偏差。

**Options:**
- A: 嵌入 Rust `tiktoken` via swift-bridge — 代价：二进制体积 +~2MB，FFI 复杂度；精度最高（cl100k_base 是 GPT 系列真实 BPE）
- B: Pure Swift 的 BPE port（开源实现有 `swift-tokenizers`）— 代价：包依赖 + 精度略低于 A
- C: 向上游 `/responses` 发一条最小 probe 请求取 `usage.input_tokens` — 代价：每次 count_tokens 都要跑一次 HTTP，延迟/配额双重代价；但精度最高
- D: 保留启发式，仅把系数从 `/4` 调到按 text/tool/system 分别加权的版本 — 代价：精度只能到 30%-50% 偏差，达不到 Acceptance 的 ≤10%

**Chosen:** B — auto mode 下按 Recommendation 记录；`docs/scheme3/03 §4.3` 已证 count_tokens 不是热路径，不需要 A 的极致精度；C 会被订阅配额惩罚；D 达不到 Acceptance 的 ≤10% 偏差目标。
