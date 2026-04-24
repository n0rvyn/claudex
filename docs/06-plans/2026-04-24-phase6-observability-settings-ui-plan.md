---
type: plan
status: active
tags: [observability, routing, settings-ui, dashboard, trace-fields, token-status, hot-reload]
refs:
  - docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
  - docs/scheme3/10-tool-mapping-v1.md
  - docs/research/2026-04-22-upstream-model-probe.md
---

# Phase 6: 可观测性增强 + Settings UI 整合 Implementation Plan

**Goal:** `TraceLogger` 每条记录带上路由 4 字段（`claude_model` / `upstream_model` / `reasoning_effort` / `text_verbosity` / `resolved_route_match`）；`TraceDiagnostics` 按 Claude 模型分组聚合（p50 / p95 / count / error reasons）；Dashboard "Runtime activity" 下方多一块 "Routing insights"（三行 opus/sonnet/haiku）；Settings `Upstream` tab 的单值 `executorModel` / `advisorModel` 文本框替换为可 add/edit/delete 的 Routing 表格 + Advisor route 编辑 + Token status 区块；Settings 里改完路由 → 保存 → 下一条请求命中新路由（不需要重启 daemon）。

**Architecture:**

- **Trace 字段下沉（Task 1）：** `AnthropicBridge.swift` 三个 outbound stage（`anthropic_in:72`、`responses_out_initial:528`、`responses_out_continuation:1218`）+ 一个 inbound stage（`anthropic_out:1160`）在 emit 时从 `preparedTurn.anthropicModel` + `preparedTurn.resolvedRoute` 读出 5 字段（`claude_model` 来自 `request.model` → `anthropicModel`；`upstream_model` / `reasoning_effort` / `text_verbosity` 来自 `resolvedRoute`；`resolved_route_match` 来自匹配规则的 `.match` 原文或字面量 `"fallback"`）。`anthropic_in` 在 `prepareTurn` 完成**之后**才能拿到 `resolvedRoute`；所以 `anthropic_in` 的 5 字段写入必须放在 `prepareTurn` 返回 `.turn(preparedTurn)` 之后。对 `.rejected(_)` 分支保持现状（拒绝请求没有有效 route）。

- **Routing 命中规则 surface（Task 1）：** `ModelRoutingTable.resolve` 现在只返回 `ModelRoute`；Phase 6 新增 `ModelRoutingTable.resolveWithMatch(for:) -> (ModelRoute, matchedRule: ModelRoutingRule?)`，返回命中规则；fallback 时 `matchedRule == nil`，trace 写 `"fallback"`。`PreparedTurn.resolvedRoute: ModelRoute` 扩成 `resolvedRoute: ResolvedRoute`（含 `route` + `matchLabel: String`），整条 tool turn 续回合能保持 `matchLabel` 一致（避免 pending turn 续回合 trace 里 `resolved_route_match` 忽然变）。

- **Per-Claude-model 聚合（Task 2）：** `TraceDiagnostics` 新增 `perClaudeModelMetrics: [String: ClaudeModelMetrics]`。`TraceLogger.diagnostics(limit:)` 扫描最近 N 行 trace，对每条 `anthropic_out`（含 duration_ms）或 `anthropic_in`（含 claude_model）两种事件类型按 `claude_model` 分组统计：count（`anthropic_in` 条数）/ success / failure / p50 / p95 / lastUpstreamModel / errorReasons。`anthropic_in` 与 `anthropic_out` 通过 `session_id` 相关联；单条 `session_id` 的 `claude_model` 在 `anthropic_in` 时记录，聚合 `anthropic_out` 时查表还原。窗口：这次 daemon 启动以来的 trace（即当前 `diagnostics(limit:)` 已经在做的事）。

- **Dashboard Routing insights（Tasks 3-4）：** `AppModel` 新增 `routingInsights: [RoutingInsightRow]`。三行顺序固定 `opus`、`sonnet`、`haiku`；每行数据从 `diagnostics.perClaudeModelMetrics[<keyword>]` 取，若该 key 无数据则行显示 "—"（不隐藏）。每行右侧显示"当前路由 → <upstream_model> · <effort>"，这一信息来自 `configuration.routingTable.resolveWithMatch(for: <claude-model-sample>)` 即时计算，不依赖 trace 数据，保证即使未发过请求也能看到配置。`ContentView.swift` 在 `recentSection` 之后插入 `routingInsightsSection`。

- **Hot reload（Task 5）：** 当前 `GatewayDaemon.configuration` 是 `let`；`AnthropicBridge.configuration` 也是 `let`。Phase 6 新增 `AnthropicBridge.updateRouting(table:, advisorRoute:)`（actor 方法，原子替换 bridge 的 routing 引用），以及 `GatewayDaemon.applyRoutingUpdate(table:, advisorRoute:) async`（代理到 bridge）。`AppModel.saveUpstreamSettings()` 在 `persistConfiguration` 后调用 `gatewayDaemon.applyRoutingUpdate(...)`，不重启 daemon。In-flight requests continue with old route（已被各 task 闭包捕获），新 request 的 `resolve()` 读取新表。不 hot-reload 的字段：`responsesURL` / `host` / `port` / `subscriptionAuthFilePath`（这些需要 LocalHTTPServer 重建；Phase 6 不改这些字段的热加载）。

- **Settings Routing 编辑器（Tasks 6-8）：** `SettingsView.UpstreamSettingsTab` 的 `Upstream` MBSection 移除 `executorModelDraft` / `advisorModelDraft` 两个单值 `TextField`。新增三个 MBSection：
  1. "Routing rules"：表格列出 `routingTable.rules`（claude keyword、upstream model、effort、verbosity），每行有 edit / delete 按钮；底部有 Add rule 按钮（追加空白行进入 edit 模式）。edit 模式为行内展开：`TextField("opus")` + 三个 `Picker`（upstream / effort / verbosity，选项从硬编码白名单来：`ModelRoutingOptions.upstreamModels` / `reasoningEfforts` / `textVerbosities`，由 Phase 2 probe 沉淀）。用户支持拖拽重排（`onMove` + `.moveDisabled(false)`），因为 `resolve()` 按顺序匹配，顺序有语义。
  2. "Fallback route"：当所有规则都不匹配时的 route，展示三个 Picker（upstream / effort / verbosity），没有 keyword 字段。
  3. "Advisor route"：advisor 子调用的 route，三个 Picker。
- **Settings Token status 区块（Tasks 9-10）：** `UpstreamSettingsTab` 底部新增 "Token status" MBSection。显示：access_token 前 4 + 后 4 字符（中间 `…`，来自 `DoctorSnapshot.lastRefresh` 或新增 `accessTokenPreview` 字段，避免把整个 token 透出到 UI 层）、`lastRefresh` 时间（相对格式，如 "refreshed 5 min ago"）、`hasRefreshToken` 状态灯。"Refresh now" 按钮调用 `SubscriptionSessionLoader.refreshAndReload()`；按钮按下时 disable 并显示 spinner，成功/失败后显示 inline status text。AppModel 新增 `@Published var tokenStatus: TokenStatus` 与 30 秒轮询 `Timer.publish`（仅当 Settings 窗口前台时活跃；用 `.task(id: settingsOpen)` 控制生命周期）。

- **Scope boundary / 不做的事：**
  - 不引入 regex match（DP-P6-C `Chosen: substring`）
  - 不加历史 24h/7d 窗口（DP-P6-B `Chosen: this-session`）
  - 不加 `claude_model` 以外的分组维度（DP-P6-A `Chosen: claude_model`）
  - `responsesURL` / `subscriptionAuthFilePath` 的热加载不做（复杂度高且非 Phase 6 acceptance）
  - 已部署的 Phase 5 deferred 问题（#1 / #2 / #3）本 Phase 不修

**Tech Stack:** Swift 6 actor、SwiftUI、`Timer.publish` + `.task(id:)`、现有 `TraceLogger` + `TraceDiagnostics` + `ModelRoutingTable` + `AppModel`、`FileManager.replaceItemAt`（`SubscriptionSessionLoader.refreshAndReload` 已用）。

**Design doc:** none（design evidence 来自 dev-guide Phase 6 scope + `docs/scheme3/10-tool-mapping-v1.md §7.8` 白名单）

**Design analysis:** none

**Crystal file:** none

**Threat model:**
- Routing 编辑器若允许空字符串 keyword，`resolve()` 的 `needle.contains("")` 恒为 true → 每条请求命中该规则 → 后续规则死代码。验证任务：`RoutingRulesValidationTests` 断言空 keyword 在保存时被拒（trim 后校验）。
- Token preview 泄漏：`DoctorSnapshot` 当前没有 `access_token_preview` 字段，新增字段只导出前 4 + 后 4 共 8 字符 + `…`。审查 `TraceLogger` 是否有地方 log 了完整 token（已扫过，没有）。
- Hot reload 竞态：in-flight 请求继续用旧 route 是正确的（每个请求在 `prepareTurn` 时 snapshot route）；但若 UI 在保存瞬间 crash，disk 已写但内存 bridge 未 apply。Task 5 测试覆盖 save → applyRoutingUpdate 的顺序。

---

## Decisions

### [DP-P6-A] Dashboard Routing insights 分组键（recommended）

**Context:** dev-guide Phase 6 scope item 2 写 "按 upstream_model 维度聚合"，但 "用户可见的变化" 写 "三行 opus/sonnet/haiku"。两者是不同的维度（`upstream_model` 是 `gpt-5.4` / `gpt-5.3-codex-spark`；`claude_model` 是 `opus` / `sonnet` / `haiku`）。

**Options:**
- A: 按 `claude_model` 分组 (opus/sonnet/haiku)
- B: 按 `upstream_model` 分组 (gpt-5.4 / gpt-5.3-codex-spark)
- C: 两者都保留，Dashboard 用 segmented control 切换

**Chosen:** A — 用户 2026-04-24 确认按 Claude 模型分组。这匹配用户心智模型（"我请求的是 opus"），且三行固定顺序对齐 dev-guide "用户可见的变化"。`upstream_model` 仍然 emit 到 trace 供诊断。

### [DP-P6-B] Dashboard 聚合时间窗口（recommended）

**Context:** dev-guide 列为 Phase 6 open decision："本会话 / 本 24h / 可配置"。

**Options:**
- A: 本会话（这次 daemon 启动以来）
- B: 过去 24h（需磁盘 index）
- C: Settings 可配置（默认本会话）

**Chosen:** A — 用户 2026-04-24 确认 "这次开机以来"。复用现有 `TraceLogger.diagnostics(limit:)`；daemon 重启后重新计数，与 `kpiSection` 行为一致。

### [DP-P6-C] Routing 规则 match 字段语法（recommended）

**Context:** dev-guide 列为 Phase 6 open decision："默认 substring，regex 可选"。

**Options:**
- A: 固定 substring（与 `ModelRoutingTable.resolve` 当前 `.contains` 一致）
- B: 支持 regex 切换

**Chosen:** A — 用户 2026-04-24 确认固定 substring。Core `resolve()` 已按 `.contains` 实现，Phase 6 UI 不需要扩展；验证器仅要求 trim 后非空。

### [DP-P6-D] Token 状态刷新策略（recommended）

**Context:** dev-guide 列为 Phase 6 open decision："主动轮询 refresh 还是仅被动显示"。

**Options:**
- A: 被动显示（只读 DoctorSnapshot）
- B: 30 秒自动轮询
- C: 被动 + "Refresh now" 按钮

**Chosen:** B + dev-guide 原文要求的 "Refresh now" 按钮 — 用户 2026-04-24 确认 30 秒自动 + 保留按钮。Timer 仅在 Settings 窗口前台时活跃（`.task(id:)` 生命周期绑定）。

### [DP-P6-H] 配置热加载实现方式（blocking）

**Context:** Phase 6 acceptance 要求 "Settings 里修改路由 → 保存 → 下一条请求 trace 的 `upstream_model` 反映新配置（不需要重启）"。当前 `GatewayDaemon.configuration` 与 `AnthropicBridge.configuration` 都是 `let`，结构上不支持热加载。

**Options:**
- A: 在 `AnthropicBridge` 引入 `updateRouting(table:, advisorRoute:)` actor 方法，原子替换 routing 引用；`GatewayDaemon.applyRoutingUpdate` 代理；in-flight 请求保持旧 route（因为已 snapshot 进 task closure）。`configuration` 的其他字段仍 `let`，只改 routing 相关两项。
- B: 重启 daemon — `stop()` + 新 configuration 初始化 + `start()`。简单但用户感知到 daemon "stopped → running"，in-flight 请求失败，`pendingToolTurns` 丢失。
- C: 引入外部 `ConfigStore` actor，bridge 每次 `resolve()` 时从 store 读；支持全量字段热加载但重构范围大。

**Chosen:** A — 用户 2026-04-24 确认按 Recommendation。最小结构变更，仅 routing 相关字段热加载（响应 Phase 6 明确需求），其他字段保留 `let`；避免 B 的用户可见中断，避免 C 的大规模重构。in-flight 保持旧 route 是期望语义（一个 tool turn 不能中途换模型，与 Phase 2 `PendingToolTurn.resolvedRoute` 立场一致）。

---

## Tasks

### Task 1: Trace 路由字段扩展（`TraceLogger` emission 增加 5 字段）

**Files:**
- `Sources/CCRouterCore/ModelRouting.swift`（新增 `resolveWithMatch`）
- `Sources/CCRouterCore/AnthropicBridge.swift`（4 处 trace emission 增加字段 + `PreparedTurn.resolvedRoute` 升级为 `ResolvedRoute`）
- `Tests/CCRouterCoreTests/TraceLoggerRoutingFieldsTests.swift`（新增）

**Steps:**
1. `ModelRouting.swift` 新增 `public struct ResolvedRoute: Sendable { public let route: ModelRoute; public let matchLabel: String }`；在 `ModelRoutingTable` 新增 `public func resolveWithMatch(for claudeModel:) -> ResolvedRoute`，匹配逻辑与 `resolve()` 相同但返回 `matchLabel = rule.match` 或 `"fallback"`。
2. `AnthropicBridge.swift` 把 `PreparedTurn.resolvedRoute: ModelRoute` **和** `PendingToolTurn.resolvedRoute: ModelRoute`（`.swift:1311`）**都**改为 `ResolvedRoute`（两者都要，否则 tool turn 续回合会编译失败于 `:336`、`:346`、`:363` — 这三处从 `pending.resolvedRoute` 读 route 后再构造 `PreparedTurn`）。三个首次 resolve 调用点（`.swift:391`、`:442`、`:517`）改为 `configuration.routingTable.resolveWithMatch(for: request.model)`；下游所有把 `resolvedRoute` 当 `ModelRoute` 用的地方（如 `route: resolvedRoute.route`、`reasoningEffort: resolvedRoute.route.reasoningEffort`）按需要 `.route` 访问；`.matchLabel` 注入 trace。

   另外两个 internal helper 签名必须同步升级（否则 `runPreparedTurn` 把 `preparedTurn.resolvedRoute` 传入时类型不匹配）：
   - `handleOutputBlocks(..., resolvedRoute: ModelRoute, ...)` at `.swift:728-730` → `resolvedRoute: ResolvedRoute`
   - `runAdvisorSubcallAndSecondPass(..., resolvedRoute: ModelRoute, ...)` at `.swift:842-844` → `resolvedRoute: ResolvedRoute`

   两者内部原先把 `resolvedRoute.upstreamModel` / `.reasoningEffort` 等当 `ModelRoute` 用的地方，按上面规则加 `.route` 访问。
3. 在以下 5 个 emit 点加入 5 个路由字段（`claude_model` / `upstream_model` / `reasoning_effort` / `text_verbosity` / `resolved_route_match`）：
   - **`anthropic_in`** —— `prepareTurn` 返回 `.turn(preparedTurn)` 之后首次 emit；`.rejected` 分支保留现状（无 resolved route）
   - **`responses_out_initial`** —— `.swift:528`
   - **`responses_out_continuation`** —— `.swift:1218`
   - **`anthropic_out` (main path via `logRequestOutcome`)** —— `.swift:1148` 函数定义；签名扩展为 `logRequestOutcome(sessionID:, response:, startedAtUptimeNanoseconds:, result:, errorType: String? = nil, errorMessage: String? = nil, claudeModel: String? = nil, resolvedRoute: ResolvedRoute? = nil)`；新增两参数默认 `nil` 以容纳**无 route 上下文**的早期失败分支（`:70`、`:120`、`:144`、`:171`、`:186`、`:201` — 这些发生在 `prepareTurn` 之前或 refresh 错误等场景，无 route 可填）。
   
     能拿到 route 信息的调用点按 scope 分两类传参：
     - `preparedTurn` 在 scope（主 success path、tool turn success at 其所在函数）：`claudeModel: preparedTurn.anthropicModel, resolvedRoute: preparedTurn.resolvedRoute`
     - `:826`（在 `handleOutputBlocks`，scope 内有升级后的 `anthropicModel: String` + `resolvedRoute: ResolvedRoute` 参数）：`claudeModel: anthropicModel, resolvedRoute: resolvedRoute`
     - `:960`（在 `runAdvisorSubcallAndSecondPass`，scope 同上）：同样传本地 `anthropicModel` + `resolvedRoute` 参数，不是 preparedTurn.*
   - **`anthropic_out` stream_aborted branch** —— `.swift:605-614` 的 catch 分支 inline emit（不是 `logRequestOutcome` 调用），**也必须加** `claude_model` + `upstream_model` 等 5 字段；此处 `preparedTurn` 仍在 scope 内（是 `runPreparedTurn(preparedTurn:)` 参数），直接读。否则 stream-aborted 失败在 Task 2 per-model 聚合里不可见，会拉低 failure count 的准确度。
4. 新增 `TraceLoggerRoutingFieldsTests.swift`（使用 `TraceLogger.$overrideFileURL` 隔离）— 7 cases：
   - opus/sonnet/haiku 三种 Claude model 命中规则时 5 个 emit 点（`anthropic_in` + `responses_out_initial` + `responses_out_continuation` + `anthropic_out` main + `anthropic_out` stream_aborted）各自的 5 字段值正确；
   - fallback case（Claude model 为 `foo-bar-model`）`resolved_route_match: "fallback"`；
   - 带 max_tokens 单轮文本请求 end-to-end（用 `MockResponsesEventStream`）所有 emit 点包含 5 字段；
   - stream_aborted 场景（`MockResponsesEventStream` 在 emit text delta 后抛错）→ `anthropic_out` event `result: "stream_aborted"` 仍带完整 5 字段（回归保护）。

**Verify:** `swift test --filter TraceLoggerRoutingFieldsTests` 通过；`swift test` 全套通过（既有 197 测试不退化）。

**Dependency:** none（Task 1 先做，后续 Task 都依赖 `ResolvedRoute`）

### Task 2: TraceDiagnostics per-Claude-model 聚合

**Files:**
- `Sources/CCRouterCore/TraceDiagnostics.swift`（新增 `perClaudeModelMetrics` 字段 + `ClaudeModelMetrics` 结构）
- `Sources/CCRouterCore/TraceLogger.swift`（`diagnostics(limit:)` 填充新字段）
- `Tests/CCRouterCoreTests/TraceDiagnosticsPerModelAggregationTests.swift`（新增）

**Steps:**
1. `TraceDiagnostics.swift` 新增 `public struct ClaudeModelMetrics: Codable, Sendable, Equatable { public let requestCount: Int; public let successCount: Int; public let failureCount: Int; public let p50LatencyMilliseconds: Int?; public let p95LatencyMilliseconds: Int?; public let lastUpstreamModel: String?; public let recentErrorReasons: [String] }`。给 `TraceDiagnostics` 加 `public let perClaudeModelMetrics: [String: ClaudeModelMetrics]`，`empty` 初始为 `[:]`。memberwise init 签名扩充。
2. `TraceLogger.diagnostics(limit:)`：扫描期间维护 `var perModelState: [String: (latencies: [Int], success: Int, failure: Int, lastUpstream: String?, errors: [String])]`，key 为 `object.string("claude_model")`：
   - `anthropic_in` 事件：增加 count（其实不加 count，count 等于该 model 的所有 `anthropic_out` 总数，避免双计数）
   - `anthropic_out` 事件：按 `claude_model` 分组，累加 success/failure/latency/errors/lastUpstream
3. 收尾时把 `perModelState` 转成 `[String: ClaudeModelMetrics]`，注入 `TraceDiagnostics(...)`。
4. 新增 `TraceDiagnosticsPerModelAggregationTests.swift` — 5 cases：
   - 3 个 anthropic_out（claude_model 分别 opus/sonnet/haiku，都成功）→ `perClaudeModelMetrics` 有 3 key，每 key `requestCount: 1, successCount: 1`
   - 混合成功/失败：opus 2 成功 + 1 失败 → `successCount: 2, failureCount: 1`，errorReasons 含失败原因
   - p50/p95：opus 5 条 anthropic_out latency [100,200,300,400,500] → p50 ≈ 300，p95 ≈ 500
   - lastUpstreamModel：opus 先后命中 gpt-5.4 后 gpt-5.3-codex-spark → `lastUpstreamModel == "gpt-5.3-codex-spark"`
   - 无数据：空 trace → `perClaudeModelMetrics == [:]`

**Verify:** `swift test --filter TraceDiagnosticsPerModelAggregationTests` 通过。

**Dependency:** Task 1（需要 `anthropic_out` trace 里有 `claude_model` 字段）。

### Task 3: AppModel 暴露 routingInsights

**Files:**
- `ModelBridge/ContentView.swift`（`AppModel` 类）
- `Tests/` 无（逻辑在 app target；单测覆盖由 Task 4 的 UI smoke 承担）

**Steps:**
1. `ContentView.swift` 新增 `struct RoutingInsightRow: Equatable { let claudeModelKey: String; let displayName: String; let currentRouteLabel: String; let metrics: ClaudeModelMetrics? }`。
2. `AppModel` 新增 `var routingInsights: [RoutingInsightRow]` computed property：
   - 三行固定顺序 `[("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]`
   - 每行 `currentRouteLabel`：`configuration.routingTable.resolveWithMatch(for: "claude-\(key)-probe")` 取 `route.upstreamModel + " · " + route.reasoningEffort`
   - 每行 `metrics`: `doctorSnapshot?.traceDiagnostics?.perClaudeModelMetrics[key]`
3. 对 `doctorSnapshot` 的 `objectWillChange` 信号已有（Phase 4），不需要额外订阅。

**Verify:** manual — 确认 computed property 编译通过，类型签名正确。UI 行为由 Task 4 验证。

**Dependency:** Task 2。

### Task 4: Dashboard Routing insights UI

**Files:**
- `ModelBridge/ContentView.swift`（`ContentView.body` 加区块 + `routingInsightsSection` 私有视图）
- `ModelBridge/DesignSystem.swift`（如需新组件）

**Steps:**
1. `ContentView.swift` 在 `recentSection` 之后 `routingInsightsSection` 插入（保持 Dashboard 宽度 `.frame(width: 380)`）。
2. `routingInsightsSection` 结构：`MBCard(padding: 10)` 内三行 HStack：`Label("Routing") | "opus" | metrics 3 column` / 类似。每行：
   - 左：Claude model 名字 + 灰色小字"→ <upstreamModel> · <effort>"（来自 `row.currentRouteLabel`）
   - 右：`<count> req · <p50>ms`（来自 `row.metrics`，无数据显示 "—"）
3. 参考 `kpiSection` 的 MBCard 视觉语言保持一致。

**Verify:** `xcodebuild -project ModelBridge.xcodeproj -scheme ModelBridge build` 通过；打开 `dist/ModelBridge.app`（或通过 Xcode 运行）肉眼确认 Dashboard 下方多出 Routing insights 三行；Phase 6 验收项 "真机运行 opus + sonnet + haiku 各一条请求 → Dashboard 3 条独立行"（跑完后验证）。

**Dependency:** Task 3。

### Task 5: Bridge + Daemon 热加载支持

**Files:**
- `Sources/CCRouterCore/AnthropicBridge.swift`（新增 `updateRouting` actor 方法；改 `routingTable` 字段为 `var`）
- `Sources/CCRouterCore/GatewayDaemon.swift`（新增 `applyRoutingUpdate`）
- `Tests/CCRouterCoreTests/AnthropicBridgeRoutingHotReloadTests.swift`（新增）

**Steps:**
1. `AnthropicBridge` 把 `configuration.routingTable` + `configuration.advisorRoute` 从 `let configuration: RouterConfiguration` 迁移到独立可变字段：`private var routingTable: ModelRoutingTable` + `private var advisorRoute: ModelRoute`，init 从 `configuration` 拷贝。其他 `configuration` 字段保持原样。
2. 所有 `configuration.routingTable` / `configuration.advisorRoute` 的读取点改为读 `self.routingTable` / `self.advisorRoute`（grep 确认：`:391 :442 :517 :1074` 四处）。
3. 新增 `public func updateRouting(table: ModelRoutingTable, advisorRoute: ModelRoute) async { self.routingTable = table; self.advisorRoute = advisorRoute; await TraceLogger.shared.log(JSONObject.from(["stage": .string("routing_hot_reload"), "rules_count": .number(Double(table.rules.count)), "fallback_upstream": .string(table.fallback.upstreamModel), "advisor_upstream": .string(advisorRoute.upstreamModel)])) }`。
4. `GatewayDaemon` 新增 `public func applyRoutingUpdate(table:, advisorRoute:) async { await bridge.updateRouting(table: table, advisorRoute: advisorRoute) }`。
5. 新增 `AnthropicBridgeRoutingHotReloadTests.swift` — 3 cases：
   - 初始 defaultTable 下发 opus 请求 → upstream 命中 `gpt-5.4`；调 `updateRouting(...)` 切 opus → 虚拟 `gpt-5.4-mini`；再发 opus → 命中 `gpt-5.4-mini`
   - 热加载 advisor route → advisor 子调用用新 upstream（mock 一次 tool turn）
   - 并发：调 `updateRouting` 同时发请求 — 任一次请求要么看到旧 route，要么看到新 route，永不部分旧部分新（由 actor 串行化保证）；断言无 crash。

**Verify:** `swift test --filter AnthropicBridgeRoutingHotReloadTests` 通过；既有 `ModelRoutingBridgeIntegrationTests` 不退化。

**Dependency:** Task 1（需要 `ResolvedRoute` / `resolveWithMatch`）。

### Task 6: Settings Routing 编辑器后端状态

**Files:**
- `ModelBridge/ContentView.swift`（`AppModel` 新增 draft 状态）
- `ModelBridge/SettingsView.swift`（data types）
- `Tests/` 无（UI 状态由 Task 7 的 Xcode 测试承担）

**Steps:**
1. `ContentView.swift` 新增 `struct RoutingRuleDraft: Identifiable, Equatable { let id = UUID(); var keyword: String; var upstreamModel: String; var effort: String; var verbosity: String }` + `struct RouteDraft: Equatable { var upstreamModel: String; var effort: String; var verbosity: String }`。
2. `AppModel` 新增：
   - `@Published var routingRulesDraft: [RoutingRuleDraft] = []`
   - `@Published var fallbackRouteDraft: RouteDraft`
   - `@Published var advisorRouteDraft: RouteDraft`
   - `func syncRoutingDraftsFromConfiguration()`（init 与 reload 时调用；把 `configuration.routingTable.rules` 与 `fallback` / `advisorRoute` 填入 draft）
   - `func addRoutingRule()`（append 空白 `RoutingRuleDraft(keyword: "", upstreamModel: "gpt-5.4", effort: "xhigh", verbosity: "low")`）
   - `func removeRoutingRule(id:)`
   - `func moveRoutingRule(from:to:)`（支持 onMove）
   - `func saveRoutingAndApply() async` — 校验所有 draft 非空且 trim 后合法；构造 `ModelRoutingTable` + `ModelRoute`；调 `configurationStore.save(configuration: updated)` 然后 `await daemon.applyRoutingUpdate(...)`；失败时 publish `routingSaveError`
3. 定义常量 `enum RoutingOptions { static let upstreamModels = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.3-codex-spark"]; static let efforts = ["low", "medium", "high", "xhigh"]; static let verbosities = ["low", "medium", "high"] }`。upstreamModels 来自 Phase 2 probe；efforts 与 verbosities 目前只 `xhigh` / `low` 在生产使用，其他从 UI 选出时若上游拒绝会在请求时失败并 trace，本 Phase 不拦截（Phase 2 DP-002 / 的后续 probe 任务未 ship）。
4. 删除 `executorModelDraft` / `advisorModelDraft` 的**所有** 12 个消费点（verifier cycle 1 审查确认）：
   - `ContentView.swift`：
     - line 43/44（`@Published` 声明删除）
     - line 59/60（init 赋值删除）
     - line 422/423（`saveGatewaySettings` 调用 `persistConfiguration` 的 `executorModel:` / `advisorModel:` 实参 —— **不删**，改为 `executorModel: currentConfiguration.executorModel, advisorModel: currentConfiguration.advisorModel`，用保留的 compat 计算属性回填；`saveGatewaySettings` 保持只改 host/port/responsesURL 的语义）
     - line 440/441（`saveUpstreamSettings`——Task 6 step 5 将该函数改名为 `saveLegacyUpstreamSettings`——调用 `persistConfiguration` 同样两个实参，按同样方式改为从 `currentConfiguration.executorModel/.advisorModel` 回填）
     - line 630/631（`syncDrafts` / reload 路径直接删除，drafts 不再存在）
     - `persistConfiguration` 自身签名（line 488-489）**不改动**：参数 `executorModel: String, advisorModel: String` 仍被两个 caller 使用；仅实参来源从删除的 drafts 换为 compat 计算属性，这保持 `persistConfiguration` 对非 routing 字段的保存语义不变
   - `SettingsView.swift`：line 401（`TextField("", text: $model.executorModelDraft)`）、line 410（同 advisor）
   - 保留的向后兼容层（不要在 Phase 6 误删）：
     - `RouterConfiguration.executorModel` 计算属性（`.swift:22` `routingTable.fallback.upstreamModel` 的别名）— 继续作为 DoctorSnapshot 的 compat field 来源
     - `RouterConfiguration.advisorModel` 计算属性（如存在类似结构）
     - `DoctorSnapshot.executorModel` / `.advisorModel` 存储字段 — `/health` 端点 JSON consumer（以及 Phase 2 前的测试）仍读；继续从 `configuration.executorModel` / `.advisorModel` 填
     - `RouterConfigurationStore` / `RouterConfiguration` 里的 legacy 读取路径（line 141/151/202/216 + `StoredConfiguration.executorModel/.advisorModel` Codable 字段）— 用于老 `config.json` 迁移，保留
5. `AppModel.saveUpstreamSettings()` 旧版调用改名为 `saveLegacyUpstreamSettings()`（保留兼容签名但 Settings UI 不再调用）；新 `saveRoutingAndApply()` 是 Settings 保存按钮主路径。

**Verify:** 编译通过；`swift test` 全套通过；`xcodebuild build -scheme ModelBridge` 通过。

**Dependency:** Task 5（`applyRoutingUpdate` 存在）。

### Task 7: Settings Routing 编辑器 UI

**Files:**
- `ModelBridge/SettingsView.swift`（`UpstreamSettingsTab`）
- `ModelBridgeTests/SettingsRoutingEditorTests.swift`（新增 Xcode 单测目标；放入已配置的 PBXFileSystemSynchronizedRootGroup，Xcode 自动收录，禁手动改 pbxproj）

**Steps:**
1. `UpstreamSettingsTab` 移除 "Upstream" MBSection 里的 `Executor model` + `Advisor model` 两个 MBField，保留 "Responses URL"。
2. 在 "Responses URL" 下方加三个 MBSection：
   - "Routing rules"：`MBCard` 内嵌 `List`（或 `VStack` + ForEach + .onMove） — 每行 `RoutingRuleDraftRow(binding, onDelete:)` 组件。底部 "Add rule" 按钮。`RoutingRuleDraftRow` 结构：`TextField` for keyword + 3 个 `Picker` for upstream/effort/verbosity + delete icon。
   - "Fallback route"：`VStack` 三个 `Picker` binding `$model.fallbackRouteDraft.upstreamModel` / `.effort` / `.verbosity`。
   - "Advisor route"：同上 binding `$model.advisorRouteDraft.xxx`。
3. 保存按钮从 "Save upstream" 改标题 "Save routing + upstream"，action 调 `await model.saveRoutingAndApply()`（由于 `@ObservedObject`，失败时在 Routing rules 顶部显示 `model.routingSaveError` 红字）。
4. 新增 `ModelBridgeTests/SettingsRoutingEditorTests.swift`（ModelBridgeTests 同步组；Xcode 打开/编译时自动收录到 target，无需改 pbxproj；XCTest 或 Swift Testing 视 target 现有约定）5 cases：
   - Add rule → draft 数组长度 +1
   - Edit rule keyword → draft 反映
   - Delete rule → 数组 -1
   - Move rule → 数组顺序变
   - saveRoutingAndApply → configurationStore 被调用 + daemon.applyRoutingUpdate 被调用（用测试替身）

**Verify:** `xcodebuild test -project ModelBridge.xcodeproj -scheme ModelBridge -destination 'platform=macOS' -only-testing:ModelBridgeTests/SettingsRoutingEditorTests` 通过。

**Dependency:** Task 6。

### Task 8: Advisor route 独立验证

**Files:** `Tests/CCRouterCoreTests/AnthropicBridgeRoutingHotReloadTests.swift`（扩充 case 2 的 advisor route）

**Steps:**
1. Task 5 测试 case 2 已覆盖 advisor route 热加载；若 Task 7 中发现 UI 侧 Advisor route 不独立（比如并入 Fallback），这里补一个 Xcode 测试"修改 Advisor route 只影响 advisor 子调用、不影响 executor"。

**Verify:** `swift test --filter AnthropicBridgeRoutingHotReloadTests` 保持绿；无新增 flake。

**Dependency:** Task 7。

### Task 9: DoctorSnapshot + BridgeDoctorStatus 扩充 Token preview

**Files:**
- `Sources/CCRouterCore/DoctorSnapshot.swift`
- `Sources/CCRouterCore/AnthropicBridge.swift`（`doctorStatus` 填充）
- `Sources/CCRouterCore/SubscriptionSession.swift`（`SubscriptionCredentials` 新增 preview 字段暴露）
- `Tests/CCRouterCoreTests/DoctorSnapshotTests.swift`（扩充 1 case）

**Steps:**
1. `DoctorSnapshot` 新增 `public let accessTokenPreview: String?`（nil when not authenticated）。`BridgeDoctorStatus` 对称新增字段。
2. `AnthropicBridge.doctorStatus()` 用 `credentials.accessToken.prefix(4) + "…" + credentials.accessToken.suffix(4)` 构造 preview（仅 `.ready` state 时），写入 `BridgeDoctorStatus`。
3. `GatewayDaemon.snapshot` + `/health` handler 两处 `DoctorSnapshot(..., accessTokenPreview: auth.accessTokenPreview)`。
4. `DoctorSnapshotTests.swift` 加 case `accessTokenPreviewExposedWhenAuthenticated` — mock `SubscriptionCredentials` 带 access_token `"abcd1234efgh5678"` → snapshot.accessTokenPreview == `"abcd…5678"`。unauthenticated → nil。

**Verify:** `swift test --filter DoctorSnapshotTests` 通过。

**Dependency:** none。

### Task 10: Settings Token status UI

**Files:**
- `ModelBridge/SettingsView.swift`（`UpstreamSettingsTab`）
- `ModelBridge/ContentView.swift`（`AppModel` 加 token polling + `refreshNow` action）
- `ModelBridgeTests/SettingsTokenStatusTests.swift`（新增 Xcode 单测；放入 ModelBridgeTests 同步组，Xcode 自动收录）

**Steps:**
1. `AppModel`：
   - 新增 `@Published var isRefreshingToken: Bool = false`、`@Published var tokenRefreshError: String? = nil`
   - 新增 `func refreshTokenNow() async`：内部复用现有 `SubscriptionSessionLoader` 构造模式（参考 `ContentView.swift:389`：从 `currentConfiguration.subscriptionAuthFilePath` + `subscriptionAuthBookmarkData` 构造 loader）per-call 调一次 `refreshAndReload()`；成功 reload `doctorSnapshot`，失败写 `tokenRefreshError`
   - 新增 `func startTokenStatusPolling() async`：`while !Task.isCancelled { await refreshSnapshot(); try? await Task.sleep(for: .seconds(30)) }`；**不需要** `stopTokenStatusPolling()`（SwiftUI 的 `.task` 在 view 消失时自动 cancel 这个 Task；cycle 2 advisory C2-A2 指出它会是死代码）
2. **生命周期**：在 `UpstreamSettingsTab.body` 末尾（`SettingsShell { ... }` 外层）挂 `.task { await model.startTokenStatusPolling() }`（无 id 参数）。SwiftUI 语义：view 出现时启动、消失时自动 cancel、重新出现时重启 — 不依赖 `SettingsTab` private 枚举（SettingsView.swift:80 确认是 private，子 tab 文件看不到该类型）
2. `UpstreamSettingsTab` 底部新增 "Token status" MBSection：
   - `MBField(label: "Access token")`：显示 `model.doctorSnapshot?.accessTokenPreview ?? "—"`，`MBFont.mono`
   - `MBField(label: "Last refresh")`：显示相对时间 `"5 min ago"` / `"never"`（用 `RelativeDateTimeFormatter`），来源 `doctorSnapshot.lastRefresh`
   - `MBField(label: "State")`：`MBDot` 状态灯 + 文字（"ready" / "requires re-auth" / "refreshing…"）
   - `Button("Refresh now", action: { Task { await model.refreshTokenNow() } })`，`.disabled(model.isRefreshingToken)`，显示 spinner
   - 错误时显示 `model.tokenRefreshError` 红字
3. `SettingsTokenStatusTests.swift` 3 cases：
   - `tokenPreviewRendersFromSnapshot` — 注入 snapshot with preview → UI 显示正确
   - `refreshNowTogglesBusyFlag` — 调 `refreshTokenNow()` → `isRefreshingToken` 从 false → true → false
   - `refreshFailurePopulatesError` — mock loader throw → `tokenRefreshError` 非 nil

**Verify:** `xcodebuild test` Xcode 测试通过；肉眼 / real-device：Settings → Upstream tab → 滚到底部看到 Token status 区块显示当前 auth.json 的 last_refresh；点 "Refresh now" 触发真实 refresh；数据每 30s 自动刷新（不主动切窗口也看到）。

**Dependency:** Task 9。

### Task 11: 端到端集成回归（smoke + Phase 6 场景）

**Files:**
- `scripts/smoke_local_gateway.sh`（无需修改，但验证通过）
- 手工验证步骤记录于本 plan 底部 "Manual acceptance"

**Steps:**
1. `swift test` 全套绿（≥ 197 + 新增 Task 1/2/5/9 case 数 ≥ 15）
2. `xcodebuild test -only-testing:ModelBridgeTests` 全套绿
3. `bash scripts/smoke_local_gateway.sh` 通过
4. 本地手工：`open dist/ModelBridge.app` → 打开 Settings → 编辑 opus 路由为 `gpt-5.4-mini` → Save → 在 Claude CLI 发 `ANTHROPIC_MODEL=claude-opus-4-7 claude`，TUI 输入 prompt: `Reply OK.` → 查看 trace `jq 'select(.stage == "responses_out_initial") | .upstream_model' ~/Library/Application\ Support/ModelBridge/trace.jsonl | tail -1` 输出 `"gpt-5.4-mini"`

**Verify:** 每一步命令输出贴回本 plan 的 Manual acceptance 部分（Task 11 收尾）。

**Dependency:** Tasks 1-10。

---

## Verification

**Verdict:** Approved (with inline post-cycle-2 patches)

**Cycle log:**

- Cycle 1 (`.claude/reviews/plan-verifier-2026-04-24-090429.md`): 5 must-revise items; all addressed by plan-level revisions to Task 1 (steps 2/3/4), Task 6 (step 4), Task 10 (step 1).
- Cycle 2 (`.claude/reviews/plan-verifier-2026-04-24-091401.md`): 3 of 5 cycle-1 revisions closed cleanly; 2 net-new precision gaps flagged:
  - **C2-1** `persistConfiguration` callsite arithmetic (ContentView.swift:422/423/440/441) — applied inline to Task 6 step 4: keep `persistConfiguration` signature, switch arguments to `currentConfiguration.executorModel` / `.advisorModel` compat computed-props.
  - **C2-2** `:826` / `:960` don't have `preparedTurn` in scope + helper signature `ModelRoute → ResolvedRoute` upgrade — applied inline to Task 1 step 2 (add `handleOutputBlocks` + `runAdvisorSubcallAndSecondPass` signature upgrade) and step 3 (scope-aware parameter passing).
- 2-cycle cap reached; both cycle-2 items are mechanical patches with exact replacement text from verifier; inlined rather than invoking a cycle-3 verify re-run.
- Cycle 2 advisories C2-A1/A2/A3 (non-blocking) folded into Task 10 step 1 (`sessionLoader` per-call construction pattern; `stopTokenStatusPolling` removed as dead code).

**Residual risk:** None identified at cycle 2 that requires pre-execution patching. Executor should treat Task 1 (core bridge signature changes) as the highest-risk task — it cascades into Tasks 2/5/7/10. Breaking build at Task 1 means re-work the `ResolvedRoute` rollout plan.

---

## Manual acceptance (fill during Task 11)

- `swift test`: **214 tests passed** (30 suites, 1.862s) — all Phase 6 suites green
- `xcodebuild test -only-testing:ModelBridgeTests`: **TEST SUCCEEDED** — existing tests pass; new test files need pbxproj update (see Task 7 gap note in execution report)
- `bash scripts/smoke_local_gateway.sh`: **Smoke validation passed**
- Hot reload smoke: pending manual — open `dist/ModelBridge.app`, Settings > Upstream, edit opus rule to `gpt-5.4-mini`, save, send request, check `trace.jsonl`
- Dashboard Routing insights 三行: pending manual
- Token status "Refresh now": pending manual
