---
type: plan
status: active
tags: [model-routing, routing-table, reasoning-effort, text-verbosity, probe]
refs:
  - docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
  - docs/scheme3/10-tool-mapping-v1.md
  - docs/scheme3/09-real-upstream-capture.md
  - docs/scheme3/16-request-shape-comparison-v1.md
  - docs/scheme3/08-responses-http-contract.md
---

# Phase 2: Per-Request 模型路由表 Implementation Plan

**Goal:** 让 Claude 侧的 `model` 字段（opus / sonnet / haiku 等）真正驱动上游模型 + `reasoning.effort` + `text.verbosity`，同一会话内多个 Claude 模型正确分流到不同上游模型。

**Architecture:** 三步解耦：(a) 新 `Sources/CCRouterCore/ModelRouting.swift` 承载 `ModelRoute` / `ModelRoutingRule` / `ModelRoutingTable` 三个 value type（Codable + Sendable + Equatable），routing 解析由 `ModelRoutingTable.resolve(for:)` 走小写 substring 匹配 → 返回 `ModelRoute`；(b) `RouterConfiguration` 将 `executorModel` / `advisorModel` 从 stored string 退化为**派生只读属性**（由 `routingTable.fallback.upstreamModel` / `advisorRoute.upstreamModel` 派生），新增 stored `routingTable: ModelRoutingTable` + `advisorRoute: ModelRoute`；`RouterConfigurationStore` 在 decode 老 config.json 时把 flat `executorModel`/`advisorModel` 迁移为 single-rule `routingTable` + `advisorRoute`，并保留 legacy init 接受 `executorModel: String, advisorModel: String` 用于 `ContentView` / 既有测试；(c) `AnthropicBridge.makeResponsesPayload` 改签名接 `ModelRoute`，`runInitialTurn` / 续轮入口各自 `routingTable.resolve(for: anthropicModel)` 得到 `ModelRoute` 后传入；`PendingToolTurn` 追加 `resolvedRoute: ModelRoute` 字段，续轮沿用首轮 route，保证 tool turn 两段模型 / effort / verbosity 一致。

**Tech Stack:** Swift 6.2（actor 并发、Codable 迁移），Swift Testing；probe 脚本用 Python 3 + `zstandard` + 标准 `urllib`（`scripts/probe_responses_advisor_bridge.py` 已有 auth + zstd + SSE 解析模板可直接套用）。

**Design doc:** `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md`（Phase 2 章节 + DP-001/DP-002 auto-resolved chosen）

**Design analysis:** none（Phase 2 是路由基建，无独立视觉/交互设计；所有事实溯源到 `docs/scheme3/` + 现有 `file:line`）

**Crystal file:** none（dev-guide `confirmed_at: 2026-04-22T09:17:32` 为 scope 基线；Phase 2 确认未添加新视觉/交互决策）

**Threat model:** not applicable（Phase 2 不引入新认证/沙箱/权限边界；所有路由决策都在已认证 `/v1/messages` → 已认证 `/responses` 通路内部；probe 脚本读取的 `~/.codex/auth.json` 是现有 `SubscriptionSessionLoader` 已在读的同一文件，沿用其读取模式）

---

## Scope & Constraints Recap

来自 dev-guide Phase 2（每个 task 自检是否偏离）：

- S1: 新增 `Sources/CCRouterCore/ModelRouting.swift`（`ModelRoute` / `ModelRoutingRule` / `ModelRoutingTable`）
- S2: `RouterConfiguration` 扩 `routingTable` + `advisorRoute`，老配置自动迁移为 fallback route
- S3: `AnthropicBridge.buildInitialPayload` + 续轮 payload 改为解析 Claude `model` → `resolve` → `ModelRoute` → `makeResponsesPayload`
- S4: `makeResponsesPayload` 改签名接 `ModelRoute`（去掉硬编码 `xhigh` / `low`）
- S5: `PendingToolTurn` 追加 `resolvedRoute: ModelRoute`
- S6: 三个 probe 脚本 + research report（模型 ID / effort / verbosity）

**DP-001 chosen:** C — 默认路由表用白名单 ship，同时 probe 用户想要的 `gpt-4.5` / `gpt-5.3-codex-spark`；probe 通过的 ID 在 Phase 6 UI 提示可切换（Phase 2 只 ship 白名单默认，不把未验证 ID 写入默认表）。
**DP-002 chosen:** A — `reasoning.effort` probe 验证 `low/medium/high/xhigh` 真实接受性，只把 200 的值写入后续 UI 枚举（Phase 2 probe 结果落盘为 research report；UI 枚举归 Phase 6 使用，Phase 2 不引入 UI）。

**Phase 2 scope 明确排除**（Phase 6 才做；DO NOT 在本 phase 添加）：
- Routing UI 编辑器（Settings 表格：新增/编辑/删除 rule）→ Phase 6
- Dashboard 的 "Routing insights" 分组显示（haiku/sonnet/opus per-Claude-model 聚合）→ Phase 6
- Token 状态卡片 + refresh 按钮 → Phase 6（也依赖 Phase 5 refresh）
- TraceLogger 字段 `claude_model` / `reasoning_effort` / `text_verbosity` / `resolved_route_match` 这四个**Phase 6 专属**字段——Phase 2 只加 `upstream_model`（Phase 2 acceptance 的 `grep upstream_model ... sort -u ≥ 2` 所需最小子集），不提前触动 Phase 6 scope
- Per-upstream-model 聚合统计 `TraceDiagnostics` 改造 → Phase 6

**已验证必须保留的形状**：
- `/responses` 请求顶层字段 `model` / `instructions` / `input` / `tools` / `tool_choice` / `parallel_tool_calls` / `reasoning.effort` / `store` / `stream` / `include` / `service_tier` / `prompt_cache_key` / `text.verbosity` / `client_metadata`（`docs/scheme3/16 §3` 四样本一致）——Phase 2 只改 `model` / `reasoning.effort` / `text.verbosity` 三个字段的来源，其它字段保持位、保持值
- 已验证上游模型白名单（`docs/scheme3/10 §7.8`）：`gpt-5.4` / `gpt-5.4-mini` / `gpt-5.3-codex`
- 已验证拒绝清单：`gpt-5.2-codex` / `gpt-5.1-codex-max`

**默认路由表**（Phase 2 ship 的 fallback 基线；probe 结果回来后在 Phase 6 的 UI 中由用户切换，不在 Phase 2 内自动更新）：

| Claude model substring（lowercased） | upstream model      | reasoning.effort | text.verbosity |
|-------------------------------------|---------------------|------------------|----------------|
| `opus`                              | `gpt-5.4`           | `xhigh`          | `low`          |
| `sonnet`                            | `gpt-5.4`           | `xhigh`          | `low`          |
| `haiku`                             | `gpt-5.3-codex`     | `xhigh`          | `low`          |
| `<fallback>`（无匹配）               | `gpt-5.4`           | `xhigh`          | `low`          |
| advisorRoute                        | `gpt-5.4`           | `xhigh`          | `low`          |

白名单依据：`docs/scheme3/10 §7.8`；effort/verbosity 值沿用 Phase 0 已验证默认（`docs/scheme3/09 §3.2`）以避免 probe 未完成前的 400。

---

## Decisions

### [DP-001-P2] ContentView（Upstream tab）Executor/Advisor 文本字段迁移策略（recommended）

**Context:** `ModelBridge/ContentView.swift:422-531` 现有 Upstream tab 有两个文本输入字段 `executorModelDraft` / `advisorModelDraft`，直接绑到 `RouterConfiguration.executorModel` / `advisorModel`。Phase 2 把这两个字段从 RouterConfiguration 的 stored 属性退化为派生属性（由 `routingTable.fallback.upstreamModel` / `advisorRoute.upstreamModel` 派生）。ContentView 这 UI 组件在 Phase 6 会整体换成 Routing 表格，但 Phase 2 必须让它**现在**就能读/写 legacy 两个字段，否则用户现版本 UI 断。

**Options:**
- A: 保留 ContentView 现有两个文本字段语义——让它们分别读/写 `fallback.upstreamModel` / `advisorRoute.upstreamModel`；RouterConfiguration 提供 legacy init `(..., executorModel: String, advisorModel: String, ...)` 构造 single-rule fallback 表，保存时若用户只改了这两个字符串，整个 `routingTable.rules` 保持不变，只改 fallback 的 upstream。ContentView.swift 改动最小（单字段来源切换）。Phase 6 整块换成表格时再动一次。
- B: Phase 2 立刻给 ContentView 加一个"Routing 规则"的 inline JSON 编辑器 textarea——用户可以编辑整个 JSON 路由表。代价：Phase 6 立刻又要换成正式表格 UI，两次改动都触达 ContentView；且 textarea 没有校验层面会产生难排查错误。
- C: Phase 2 砍掉 Upstream tab 的这两个文本字段——用户只能改 config.json。代价：违反"用户可见行为"决策权归属规则（未经用户授权改 UI 可见行为）；DP-001-P2 本身就是为了避免这个。

**Chosen:** A — 用户确认理解了 executor/advisor 在代码里的分工（executor 按 Claude model 拆分 → routingTable；advisor 保持独立单一 ModelRoute），接受 legacy init 保留 UI 的两个文本框语义，Phase 6 再整体换表格。

### [DP-002-P2] Probe 脚本运行方式（recommended）

**Context:** dev-guide Phase 2 acceptance 要求产出 `docs/research/2026-04-22-upstream-model-probe.md`（以及 effort / verbosity 两份），内容是真实上游响应码 + 错误正文。执行 probe 脚本会消耗用户订阅配额（每个 ID 一条真实 `/responses` 请求），且必须用户本地的 `~/.codex/auth.json`——无法由 execute-plan 的自动化路径跑。

**Options:**
- A: Phase 2 plan 只负责 **创建 probe 脚本**（`scripts/probe_upstream_models.py` / `scripts/probe_reasoning_effort.py` / `scripts/probe_text_verbosity.py`），并在 `docs/research/2026-04-22-upstream-model-probe.md` 预留 template 骨架（已验证字段结构 + 空 response 列表）；脚本**由用户手动在本地 run**，粘贴输出到 research report。plan 验证只 grep "文件存在 + 脚本可 `--help`"；acceptance 的 probe 结果填写归**真机验证**一栏。
- B: plan 里直接把 probe 运行列为一个 execute-plan task，由 run-phase 的自动化跑。代价：violates 用户全局规则"不擅自加限制 / 不擅自 API 外部"，且 execute-plan 的 sonnet agent 不应消耗用户订阅配额；若 probe 失败（401 / 网络错）会阻塞整个 plan 完成。
- C: 把 probe 放到 `scripts/smoke_local_gateway.sh` 的 opt-in flag 里。代价：偏离 dev-guide 的 scope（smoke 是 Phase 7 端到端验收的载体，不该塞 Phase 2 独立 probe 逻辑）。

**Chosen:** B — 用户已显式授权消耗 Codex quota。plan 在 execute-plan 阶段直接用 `~/.codex/auth.json` 跑三个 probe（总共 ~12 条最小 `/responses` 请求：5 × model + 4 × effort + 3 × verbosity），把真实 HTTP status + 错误正文填入对应 research report。probe 任一条失败不阻塞 plan（每条请求独立捕获，失败也记录并继续）。

---

<!-- section: task-1 keywords: model-routing, route, rule, table -->
### Task 1: ModelRouting 核心类型（`ModelRoute` / `ModelRoutingRule` / `ModelRoutingTable`）

**Files:**
- Create: `Sources/CCRouterCore/ModelRouting.swift`

**Steps:**

1. 新建 `Sources/CCRouterCore/ModelRouting.swift`，定义三个 value type，全部 `public` + `Codable` + `Sendable` + `Equatable`：

```swift
import Foundation

/// 单条路由解析产物：一次 `/responses` 请求所需的全部 per-route 字段。
public struct ModelRoute: Codable, Sendable, Equatable {
    public let upstreamModel: String
    public let reasoningEffort: String
    public let textVerbosity: String

    public init(upstreamModel: String, reasoningEffort: String, textVerbosity: String) {
        self.upstreamModel = upstreamModel
        self.reasoningEffort = reasoningEffort
        self.textVerbosity = textVerbosity
    }
}

/// 一条匹配规则：`match` 为对 Claude model 小写 substring 匹配的关键字，命中则返回 `route`。
public struct ModelRoutingRule: Codable, Sendable, Equatable {
    public let match: String
    public let route: ModelRoute

    public init(match: String, route: ModelRoute) {
        self.match = match
        self.route = route
    }
}

/// 完整路由表：rules 按顺序匹配，miss 落入 fallback。
public struct ModelRoutingTable: Codable, Sendable, Equatable {
    public let rules: [ModelRoutingRule]
    public let fallback: ModelRoute

    public init(rules: [ModelRoutingRule], fallback: ModelRoute) {
        self.rules = rules
        self.fallback = fallback
    }

    /// 对 Claude 请求的 `model` 字段小写化 substring 匹配；rules 按数组顺序取首个命中。
    /// 不做 regex，不做复杂解析——与 dev-guide `ModelRoutingRule.match` 定义一致。
    public func resolve(for claudeModel: String) -> ModelRoute {
        let needle = claudeModel.lowercased()
        for rule in rules {
            if needle.contains(rule.match.lowercased()) {
                return rule.route
            }
        }
        return fallback
    }
}

/// Phase 2 默认路由表——见 plan `默认路由表` 表格。白名单来源 `docs/scheme3/10 §7.8`。
public extension ModelRoutingTable {
    static let defaultTable = ModelRoutingTable(
        rules: [
            ModelRoutingRule(match: "opus",   route: ModelRoute(upstreamModel: "gpt-5.4",       reasoningEffort: "xhigh", textVerbosity: "low")),
            ModelRoutingRule(match: "sonnet", route: ModelRoute(upstreamModel: "gpt-5.4",       reasoningEffort: "xhigh", textVerbosity: "low")),
            ModelRoutingRule(match: "haiku",  route: ModelRoute(upstreamModel: "gpt-5.3-codex", reasoningEffort: "xhigh", textVerbosity: "low")),
        ],
        fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
    )

    static let defaultAdvisorRoute = ModelRoute(
        upstreamModel: "gpt-5.4",
        reasoningEffort: "xhigh",
        textVerbosity: "low"
    )
}
```

2. 确认 Codable 表示形态：`ModelRoutingTable { rules: [{ match, route: { upstreamModel, reasoningEffort, textVerbosity } }], fallback: {...} }`。这会是用户后续可以在 config.json 里手写的形态。

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | grep -E "error:|ModelRouting\.swift"`
Expected: 零 error，ModelRouting.swift 被 CCRouterCore 模块识别。
<!-- /section -->

<!-- section: task-2 keywords: model-routing, unit-test, substring, fallback -->
### Task 2: ModelRouting 单元测试

**Files:**
- Create: `Tests/CCRouterCoreTests/ModelRoutingTests.swift`

**Steps:**

1. 新建 `Tests/CCRouterCoreTests/ModelRoutingTests.swift`，使用 Swift Testing：

```swift
import Foundation
@testable import CCRouterCore
import Testing

struct ModelRoutingTests {
    private static func makeRoute(_ model: String) -> ModelRoute {
        ModelRoute(upstreamModel: model, reasoningEffort: "xhigh", textVerbosity: "low")
    }

    private static func makeTable() -> ModelRoutingTable {
        ModelRoutingTable(
            rules: [
                ModelRoutingRule(match: "opus",   route: makeRoute("gpt-5.4")),
                ModelRoutingRule(match: "sonnet", route: makeRoute("gpt-5.4")),
                ModelRoutingRule(match: "haiku",  route: makeRoute("gpt-5.3-codex")),
            ],
            fallback: makeRoute("gpt-5.4-fallback")
        )
    }

    @Test func claudeOpus47MatchesOpusRule() {
        let route = Self.makeTable().resolve(for: "claude-opus-4-7")
        #expect(route.upstreamModel == "gpt-5.4")
    }

    @Test func claudeSonnet46MatchesSonnetRule() {
        let route = Self.makeTable().resolve(for: "claude-sonnet-4-6")
        #expect(route.upstreamModel == "gpt-5.4")
    }

    @Test func claudeHaiku45MatchesHaikuRule() {
        let route = Self.makeTable().resolve(for: "claude-haiku-4-5-20251001")
        #expect(route.upstreamModel == "gpt-5.3-codex")
    }

    @Test func uppercaseMixedCaseStillMatches() {
        let route = Self.makeTable().resolve(for: "Claude-Opus-4-7")
        #expect(route.upstreamModel == "gpt-5.4")
    }

    @Test func noMatchFallsThroughToFallback() {
        let route = Self.makeTable().resolve(for: "some-unknown-model")
        #expect(route.upstreamModel == "gpt-5.4-fallback")
    }

    @Test func emptyRulesAlwaysReturnsFallback() {
        let table = ModelRoutingTable(rules: [], fallback: Self.makeRoute("only-fallback"))
        #expect(table.resolve(for: "opus").upstreamModel == "only-fallback")
    }

    @Test func firstRuleWinsWhenMultipleMatch() {
        // "opus" 会同时 contains "opus"，但也 contains "us"；加一条 "us" 放后面验证首个规则赢。
        let table = ModelRoutingTable(
            rules: [
                ModelRoutingRule(match: "opus", route: Self.makeRoute("first-wins")),
                ModelRoutingRule(match: "us",   route: Self.makeRoute("should-not-reach")),
            ],
            fallback: Self.makeRoute("fallback")
        )
        #expect(table.resolve(for: "claude-opus-4-7").upstreamModel == "first-wins")
    }

    @Test func defaultTableHasExpectedShape() {
        let table = ModelRoutingTable.defaultTable
        #expect(table.rules.count == 3)
        #expect(table.resolve(for: "claude-opus-4-7").upstreamModel == "gpt-5.4")
        #expect(table.resolve(for: "claude-haiku-4-5-20251001").upstreamModel == "gpt-5.3-codex")
        #expect(table.fallback.upstreamModel == "gpt-5.4")
    }

    @Test func codableRoundTripPreservesTable() throws {
        let original = Self.makeTable()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelRoutingTable.self, from: data)
        #expect(decoded == original)
    }
}
```

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ModelRoutingTests 2>&1 | tail -20`
Expected: 9/9 tests pass, 0 failures.
<!-- /section -->

<!-- section: task-3 keywords: router-configuration, migration, routing-table, advisor-route -->
### Task 3: RouterConfiguration + Store 增加 `routingTable` / `advisorRoute` 字段 + 老配置自动迁移

**Files:**
- Modify: `Sources/CCRouterCore/RouterConfiguration.swift`
- Modify: `Sources/CCRouterCore/RouterConfigurationStore.swift`

**Steps:**

1. `RouterConfiguration.swift`: 把 `executorModel` / `advisorModel` 从 stored 属性**改为 computed**，同时新增 stored `routingTable` + `advisorRoute`：

```swift
public struct RouterConfiguration: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let healthPath: String
    public let messagesPath: String
    public let countTokensPath: String
    public let responsesURL: String
    public let routingTable: ModelRoutingTable    // 新增 stored
    public let advisorRoute: ModelRoute            // 新增 stored
    public let gatewayAuthToken: String
    public let gatewayAuthHeader: String
    public let subscriptionAuthFilePath: String
    public let subscriptionAuthBookmarkData: Data?
    public let configurationPath: String
    public let configurationWarning: String?

    /// 派生字段：DoctorSnapshot + ContentView 的 legacy 展示路径继续用此名读取。
    public var executorModel: String { routingTable.fallback.upstreamModel }
    public var advisorModel: String { advisorRoute.upstreamModel }

    // 新 init（canonical）
    public init(
        host: String,
        port: Int,
        healthPath: String,
        messagesPath: String,
        countTokensPath: String,
        responsesURL: String,
        routingTable: ModelRoutingTable,
        advisorRoute: ModelRoute,
        gatewayAuthToken: String,
        gatewayAuthHeader: String,
        subscriptionAuthFilePath: String,
        subscriptionAuthBookmarkData: Data? = nil,
        configurationPath: String,
        configurationWarning: String?
    ) { /* 直赋 */ }

    // Legacy init（DP-001-P2 Option A）：接受 executorModel/advisorModel 字符串，
    // 构造 single-rule fallback 表。ContentView.swift:488-531 与既有测试均走此路径。
    public init(
        host: String,
        port: Int,
        healthPath: String,
        messagesPath: String,
        countTokensPath: String,
        responsesURL: String,
        executorModel: String,
        advisorModel: String,
        gatewayAuthToken: String,
        gatewayAuthHeader: String,
        subscriptionAuthFilePath: String,
        subscriptionAuthBookmarkData: Data? = nil,
        configurationPath: String,
        configurationWarning: String?
    ) {
        self.init(
            host: host, port: port, healthPath: healthPath, messagesPath: messagesPath,
            countTokensPath: countTokensPath, responsesURL: responsesURL,
            routingTable: ModelRoutingTable(
                rules: [],
                fallback: ModelRoute(upstreamModel: executorModel, reasoningEffort: "xhigh", textVerbosity: "low")
            ),
            advisorRoute: ModelRoute(upstreamModel: advisorModel, reasoningEffort: "xhigh", textVerbosity: "low"),
            gatewayAuthToken: gatewayAuthToken, gatewayAuthHeader: gatewayAuthHeader,
            subscriptionAuthFilePath: subscriptionAuthFilePath,
            subscriptionAuthBookmarkData: subscriptionAuthBookmarkData,
            configurationPath: configurationPath, configurationWarning: configurationWarning
        )
    }
}
```

2. `Codable` 手写 `init(from:)` / `encode(to:)`（因为新旧字段并存且 Auto-generated Codable 会 require 全部 stored 字段；也需要从老 JSON 迁移）：

```swift
private enum CodingKeys: String, CodingKey {
    case host, port, healthPath, messagesPath, countTokensPath, responsesURL
    case routingTable, advisorRoute
    case executorModel, advisorModel   // legacy keys — read-only for migration
    case gatewayAuthToken, gatewayAuthHeader
    case subscriptionAuthFilePath, subscriptionAuthBookmarkData
    case configurationPath, configurationWarning
}

public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    host = try c.decode(String.self, forKey: .host)
    port = try c.decode(Int.self, forKey: .port)
    healthPath = try c.decode(String.self, forKey: .healthPath)
    messagesPath = try c.decode(String.self, forKey: .messagesPath)
    countTokensPath = try c.decode(String.self, forKey: .countTokensPath)
    responsesURL = try c.decode(String.self, forKey: .responsesURL)

    // 优先读新字段；缺失则从 legacy executorModel/advisorModel 合成 fallback route。
    if let table = try c.decodeIfPresent(ModelRoutingTable.self, forKey: .routingTable) {
        routingTable = table
    } else {
        let legacyExecutor = try c.decodeIfPresent(String.self, forKey: .executorModel) ?? "gpt-5.4"
        routingTable = ModelRoutingTable(
            rules: [],
            fallback: ModelRoute(upstreamModel: legacyExecutor, reasoningEffort: "xhigh", textVerbosity: "low")
        )
    }
    if let route = try c.decodeIfPresent(ModelRoute.self, forKey: .advisorRoute) {
        advisorRoute = route
    } else {
        let legacyAdvisor = try c.decodeIfPresent(String.self, forKey: .advisorModel) ?? "gpt-5.4"
        advisorRoute = ModelRoute(upstreamModel: legacyAdvisor, reasoningEffort: "xhigh", textVerbosity: "low")
    }

    gatewayAuthToken = try c.decode(String.self, forKey: .gatewayAuthToken)
    gatewayAuthHeader = try c.decode(String.self, forKey: .gatewayAuthHeader)
    subscriptionAuthFilePath = try c.decode(String.self, forKey: .subscriptionAuthFilePath)
    subscriptionAuthBookmarkData = try c.decodeIfPresent(Data.self, forKey: .subscriptionAuthBookmarkData)
    configurationPath = try c.decode(String.self, forKey: .configurationPath)
    configurationWarning = try c.decodeIfPresent(String.self, forKey: .configurationWarning)
}

public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(host, forKey: .host)
    try c.encode(port, forKey: .port)
    try c.encode(healthPath, forKey: .healthPath)
    try c.encode(messagesPath, forKey: .messagesPath)
    try c.encode(countTokensPath, forKey: .countTokensPath)
    try c.encode(responsesURL, forKey: .responsesURL)
    try c.encode(routingTable, forKey: .routingTable)
    try c.encode(advisorRoute, forKey: .advisorRoute)
    try c.encode(gatewayAuthToken, forKey: .gatewayAuthToken)
    try c.encode(gatewayAuthHeader, forKey: .gatewayAuthHeader)
    try c.encode(subscriptionAuthFilePath, forKey: .subscriptionAuthFilePath)
    try c.encodeIfPresent(subscriptionAuthBookmarkData, forKey: .subscriptionAuthBookmarkData)
    try c.encode(configurationPath, forKey: .configurationPath)
    try c.encodeIfPresent(configurationWarning, forKey: .configurationWarning)
    // 注意：encode 不再写 legacy executorModel/advisorModel；新文件只保留新 key。
    // 老文件被读入后首次 save 即被迁移为新结构（StoredConfiguration 同步下方）。
}
```

**Read-only impact (no change needed, but affected by `executorModel`/`advisorModel` computed-property transition):**
- `Sources/CCRouterCore/GatewayDaemon.swift:54, 97`（读 `configuration.executorModel/advisorModel` 传 DoctorSnapshot；computed property 透明兼容）
- `Sources/CCRouterCore/DoctorSnapshot.swift:14-15, 40-41, 65-66`（`executorModel: String` stored field，与 RouterConfiguration 解耦，不受影响）
- `ModelBridge/SettingsView.swift:401, 410, 501`（读 `configuration.executorModel` drafts；computed 透明兼容）
- `ModelBridge/ContentView.swift:422-531`（legacy init 保留，见本 task step 1 legacy init 定义）

3. `RouterConfigurationStore.swift`: 更新 `StoredConfiguration` + `normalizedConfiguration` + `resolveConfiguration` + `save` + `regenerateGatewayToken`：

```swift
private struct StoredConfiguration: Codable {
    let host: String?
    let port: Int?
    let healthPath: String?
    let messagesPath: String?
    let countTokensPath: String?
    let responsesURL: String?
    // 新字段（新文件只写这两个）
    let routingTable: ModelRoutingTable?
    let advisorRoute: ModelRoute?
    // 老字段（只读用于迁移，encode 时不写）
    let executorModel: String?
    let advisorModel: String?
    let gatewayAuthToken: String?
    let gatewayAuthHeader: String?
    let subscriptionAuthFilePath: String?
    let subscriptionAuthBookmarkData: Data?
}
```

- `normalizedConfiguration` 里先看 `routingTable`/`advisorRoute` 是否存在；若不存在则区分**两条不同迁移路径**：

  1. **Legacy migration**（用户旧 config.json 有 `executorModel` 字符串，或设置了 `CC_ROUTER_EXECUTOR_MODEL` env）：合并成 single-rule 表。用户没授权我们主动给他加三行规则。
  2. **Fresh install**（config.json 根本不存在，env 也没设；`loadOrCreate` 走"文件缺失"分支传全 nil StoredConfiguration）：用 `ModelRoutingTable.defaultTable`（opus/sonnet/haiku 三条默认规则），让新用户开箱即有三模型 fan-out（Phase 2 acceptance #4+#5 在 fresh install 下可达）。

```swift
private func normalizedConfiguration(from configuration: StoredConfiguration) -> StoredConfiguration {
    let routingTable: ModelRoutingTable
    if let table = configuration.routingTable {
        routingTable = table
    } else if let legacyExec = configuration.executorModel ?? environment["CC_ROUTER_EXECUTOR_MODEL"] {
        // Legacy migration: user had only one executor string; preserve single-rule shape.
        routingTable = ModelRoutingTable(
            rules: [],
            fallback: ModelRoute(upstreamModel: legacyExec, reasoningEffort: "xhigh", textVerbosity: "low")
        )
    } else {
        // Fresh install: ship 3-rule baseline so opus/sonnet/haiku fan out immediately.
        routingTable = .defaultTable
    }
    let advisorRoute: ModelRoute
    if let route = configuration.advisorRoute {
        advisorRoute = route
    } else if let legacyAdvisor = configuration.advisorModel ?? environment["CC_ROUTER_ADVISOR_MODEL"] {
        advisorRoute = ModelRoute(upstreamModel: legacyAdvisor, reasoningEffort: "xhigh", textVerbosity: "low")
    } else {
        advisorRoute = .defaultAdvisorRoute
    }
    return StoredConfiguration(
        host: configuration.host ?? environment["CC_ROUTER_HOST"] ?? "127.0.0.1",
        port: configuration.port ?? parsePort(environment["CC_ROUTER_PORT"]) ?? 4317,
        healthPath: configuration.healthPath ?? "/health",
        messagesPath: configuration.messagesPath ?? "/v1/messages",
        countTokensPath: configuration.countTokensPath ?? "/v1/messages/count_tokens",
        responsesURL: configuration.responsesURL ?? environment["CC_ROUTER_RESPONSES_URL"] ?? "https://chatgpt.com/backend-api/codex/responses",
        routingTable: routingTable,
        advisorRoute: advisorRoute,
        executorModel: nil,   // 写回时不保留 legacy 字段
        advisorModel: nil,
        gatewayAuthToken: configuration.gatewayAuthToken ?? environment["CC_ROUTER_GATEWAY_TOKEN"] ?? makeGatewayToken(),
        gatewayAuthHeader: configuration.gatewayAuthHeader ?? "x-api-key",
        subscriptionAuthFilePath: resolvedSubscriptionAuthFilePath(storedPath: configuration.subscriptionAuthFilePath),
        subscriptionAuthBookmarkData: configuration.subscriptionAuthBookmarkData
    )
}
```

- `resolveConfiguration` 构造 `RouterConfiguration` 时直接传 `routingTable:` + `advisorRoute:`（而不是走 legacy init）：

```swift
return RouterConfiguration(
    host: environment["CC_ROUTER_HOST"] ?? stored.host ?? "127.0.0.1",
    port: parsePort(environment["CC_ROUTER_PORT"]) ?? stored.port ?? 4317,
    healthPath: stored.healthPath ?? "/health",
    messagesPath: stored.messagesPath ?? "/v1/messages",
    countTokensPath: stored.countTokensPath ?? "/v1/messages/count_tokens",
    responsesURL: environment["CC_ROUTER_RESPONSES_URL"] ?? stored.responsesURL ?? "https://chatgpt.com/backend-api/codex/responses",
    routingTable: envRoutingTableOverride() ?? stored.routingTable ?? fallbackSingleRuleTable(stored: stored),
    advisorRoute: envAdvisorRouteOverride() ?? stored.advisorRoute ?? fallbackAdvisorRoute(stored: stored),
    gatewayAuthToken: environment["CC_ROUTER_GATEWAY_TOKEN"] ?? stored.gatewayAuthToken ?? makeGatewayToken(),
    gatewayAuthHeader: stored.gatewayAuthHeader ?? "x-api-key",
    subscriptionAuthFilePath: resolvedSubscriptionAuthFilePath(storedPath: stored.subscriptionAuthFilePath),
    subscriptionAuthBookmarkData: stored.subscriptionAuthBookmarkData,
    configurationPath: storageURL.path,
    configurationWarning: warnings.isEmpty ? nil : warnings
)
```

- `envRoutingTableOverride()` / `envAdvisorRouteOverride()`: 保持现有 `CC_ROUTER_EXECUTOR_MODEL` / `CC_ROUTER_ADVISOR_MODEL` env var 语义——若 env 设置，覆盖 fallback.upstreamModel / advisorRoute.upstreamModel；其它 rules 保持 stored 值。实现示意：

```swift
private func envRoutingTableOverride() -> ModelRoutingTable? {
    guard let envExec = environment["CC_ROUTER_EXECUTOR_MODEL"] else { return nil }
    // env 仅覆盖 fallback.upstreamModel；保留 stored.rules
    // （若 stored.rules 也无，则给一个 empty-rules table）
    let baseRules = /* read stored.routingTable?.rules ?? [] */
    return ModelRoutingTable(
        rules: baseRules,
        fallback: ModelRoute(upstreamModel: envExec, reasoningEffort: "xhigh", textVerbosity: "low")
    )
}
```

⚠️ 实现细节：env override 需要访问 `stored` 才能知道既有 rules；把这两个 helper 重构成接受 `stored:` 参数的纯函数（或 inline 到 `resolveConfiguration` 主体里），避免借用 instance state 跨函数边界。

- `save` 里构造 StoredConfiguration 时直接传 `routingTable: configuration.routingTable` + `advisorRoute: configuration.advisorRoute`，不再写 `executorModel:/advisorModel:`：

```swift
let stored = normalizedConfiguration(
    from: StoredConfiguration(
        host: configuration.host,
        port: configuration.port,
        healthPath: configuration.healthPath,
        messagesPath: configuration.messagesPath,
        countTokensPath: configuration.countTokensPath,
        responsesURL: configuration.responsesURL,
        routingTable: configuration.routingTable,
        advisorRoute: configuration.advisorRoute,
        executorModel: nil, advisorModel: nil,
        gatewayAuthToken: configuration.gatewayAuthToken,
        gatewayAuthHeader: configuration.gatewayAuthHeader,
        subscriptionAuthFilePath: configuration.subscriptionAuthFilePath,
        subscriptionAuthBookmarkData: configuration.subscriptionAuthBookmarkData
    )
)
```

4. `regenerateGatewayToken` 重构：目前它通过 legacy init 重建 RouterConfiguration（`executorModel: configuration.executorModel, advisorModel: configuration.advisorModel`）。把它改成新 init，传 `routingTable: configuration.routingTable, advisorRoute: configuration.advisorRoute`。

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | grep -E "error:"`
Expected: 零 error。
Run: `grep -n 'routingTable\|advisorRoute' Sources/CCRouterCore/RouterConfiguration.swift Sources/CCRouterCore/RouterConfigurationStore.swift | wc -l`
Expected: ≥ 8（routingTable + advisorRoute 在两个文件里各自出现）。
<!-- /section -->

<!-- section: task-4 keywords: router-configuration-store-tests, migration, legacy-executor-model -->
### Task 4: RouterConfiguration 迁移测试 + 更新既有 Store 测试

**Files:**
- Create: `Tests/CCRouterCoreTests/RouterConfigurationMigrationTests.swift`
- Modify: `Tests/CCRouterCoreTests/RouterConfigurationStoreTests.swift`

**Steps:**

1. 新建 `RouterConfigurationMigrationTests.swift`：

```swift
import Foundation
@testable import CCRouterCore
import Testing

struct RouterConfigurationMigrationTests {
    @Test
    func legacyFlatFieldsMigrateToSingleRuleFallback() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPathURL = tempRoot.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // 写入老格式 config.json（只有 executorModel/advisorModel，无 routingTable/advisorRoute）
        let legacyJSON: [String: Any] = [
            "host": "127.0.0.1",
            "port": 4317,
            "healthPath": "/health",
            "messagesPath": "/v1/messages",
            "countTokensPath": "/v1/messages/count_tokens",
            "responsesURL": "https://chatgpt.com/backend-api/codex/responses",
            "executorModel": "gpt-5.4-legacy-exec",
            "advisorModel": "gpt-5.4-legacy-advisor",
            "gatewayAuthToken": "legacy-token",
            "gatewayAuthHeader": "x-api-key",
            "subscriptionAuthFilePath": tempRoot.appendingPathComponent("auth.json").path
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON, options: .prettyPrinted)
        try data.write(to: configPathURL)

        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPathURL.path],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let configuration = store.loadOrCreate()

        // 老 executorModel 落到 fallback.upstreamModel
        #expect(configuration.routingTable.fallback.upstreamModel == "gpt-5.4-legacy-exec")
        #expect(configuration.routingTable.rules.isEmpty)   // 没擅自加 opus/sonnet/haiku rule
        #expect(configuration.advisorRoute.upstreamModel == "gpt-5.4-legacy-advisor")
        // 派生字段向后兼容
        #expect(configuration.executorModel == "gpt-5.4-legacy-exec")
        #expect(configuration.advisorModel == "gpt-5.4-legacy-advisor")
    }

    @Test
    func loadThenSaveStripsLegacyFieldsFromDisk() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPathURL = tempRoot.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let legacyJSON: [String: Any] = [
            "host": "127.0.0.1", "port": 4317,
            "healthPath": "/health", "messagesPath": "/v1/messages",
            "countTokensPath": "/v1/messages/count_tokens",
            "responsesURL": "https://chatgpt.com/backend-api/codex/responses",
            "executorModel": "gpt-5.4-e", "advisorModel": "gpt-5.4-a",
            "gatewayAuthToken": "t", "gatewayAuthHeader": "x-api-key",
            "subscriptionAuthFilePath": tempRoot.appendingPathComponent("auth.json").path
        ]
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: configPathURL)

        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPathURL.path],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )
        _ = store.loadOrCreate()   // 首次 load 会触发 persist（normalizedConfiguration 注销 legacy key）

        let diskBytes = try Data(contentsOf: configPathURL)
        let json = try JSONSerialization.jsonObject(with: diskBytes) as? [String: Any] ?? [:]
        #expect(json["executorModel"] == nil)
        #expect(json["advisorModel"] == nil)
        #expect(json["routingTable"] != nil)
        #expect(json["advisorRoute"] != nil)
    }

    @Test
    func envExecutorModelOverridesFallbackUpstream() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        let store = RouterConfigurationStore(
            environment: [
                "CC_ROUTER_CONFIG_PATH": configPath,
                "CC_ROUTER_EXECUTOR_MODEL": "env-override-exec",
            ],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let configuration = store.loadOrCreate()
        #expect(configuration.routingTable.fallback.upstreamModel == "env-override-exec")
        #expect(configuration.executorModel == "env-override-exec")
    }

    @Test
    func freshInstallGetsDefaultThreeRuleTable() throws {
        // No config.json, no env override → should ship ModelRoutingTable.defaultTable (opus/sonnet/haiku).
        // This is required for Phase 2 acceptance #4+#5 (三条 Claude 请求分流到 ≥2 upstream).
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPath = tempRoot.appendingPathComponent("config.json").path
        // Do NOT pre-write a config.json; loadOrCreate should synthesize fresh defaults.
        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPath],   // no CC_ROUTER_EXECUTOR_MODEL / _ADVISOR_MODEL
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )

        let configuration = store.loadOrCreate()

        #expect(configuration.routingTable == ModelRoutingTable.defaultTable)
        #expect(configuration.routingTable.rules.count == 3)
        #expect(configuration.routingTable.resolve(for: "claude-opus-4-7").upstreamModel == "gpt-5.4")
        #expect(configuration.routingTable.resolve(for: "claude-sonnet-4-6").upstreamModel == "gpt-5.4")
        #expect(configuration.routingTable.resolve(for: "claude-haiku-4-5-20251001").upstreamModel == "gpt-5.3-codex")
        // Advisor route also gets default.
        #expect(configuration.advisorRoute == ModelRoutingTable.defaultAdvisorRoute)
    }

    @Test
    func newFormatConfigLoadsWithRoutingTableIntact() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configPathURL = tempRoot.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let newJSON: [String: Any] = [
            "host": "127.0.0.1", "port": 4317,
            "healthPath": "/health", "messagesPath": "/v1/messages",
            "countTokensPath": "/v1/messages/count_tokens",
            "responsesURL": "https://chatgpt.com/backend-api/codex/responses",
            "routingTable": [
                "rules": [
                    ["match": "opus", "route": ["upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"]],
                    ["match": "haiku", "route": ["upstreamModel": "gpt-5.3-codex", "reasoningEffort": "medium", "textVerbosity": "low"]],
                ],
                "fallback": ["upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"]
            ],
            "advisorRoute": ["upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"],
            "gatewayAuthToken": "t", "gatewayAuthHeader": "x-api-key",
            "subscriptionAuthFilePath": tempRoot.appendingPathComponent("auth.json").path
        ]
        try JSONSerialization.data(withJSONObject: newJSON, options: []).write(to: configPathURL)

        let store = RouterConfigurationStore(
            environment: ["CC_ROUTER_CONFIG_PATH": configPathURL.path],
            fileManager: .default,
            homeDirectoryURL: tempRoot
        )
        let config = store.loadOrCreate()

        #expect(config.routingTable.rules.count == 2)
        #expect(config.routingTable.resolve(for: "claude-opus-4-7").upstreamModel == "gpt-5.4")
        #expect(config.routingTable.resolve(for: "claude-haiku-4-5").reasoningEffort == "medium")
    }
}
```

2. 更新 `RouterConfigurationStoreTests.swift:54-91` 里的 `savePersistsUpdatedConfigurationValues` 测试——它目前用 legacy init 构造一个更新版 configuration；把它保留（legacy init 仍存在，覆盖 legacy 路径），但额外在同文件加一个测试用新 init 保存 + 读取 routingTable：

```swift
@Test
func saveWithRoutingTablePersistsExpectedRules() throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let configPath = tempRoot.appendingPathComponent("config.json").path
    let store = RouterConfigurationStore(
        environment: ["CC_ROUTER_CONFIG_PATH": configPath],
        fileManager: .default,
        homeDirectoryURL: tempRoot
    )

    let initial = store.loadOrCreate()
    let table = ModelRoutingTable(
        rules: [
            ModelRoutingRule(
                match: "sonnet",
                route: ModelRoute(upstreamModel: "gpt-5.4-mini", reasoningEffort: "high", textVerbosity: "medium")
            ),
        ],
        fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
    )
    let updated = RouterConfiguration(
        host: initial.host, port: initial.port,
        healthPath: initial.healthPath, messagesPath: initial.messagesPath,
        countTokensPath: initial.countTokensPath, responsesURL: initial.responsesURL,
        routingTable: table,
        advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
        gatewayAuthToken: initial.gatewayAuthToken, gatewayAuthHeader: initial.gatewayAuthHeader,
        subscriptionAuthFilePath: initial.subscriptionAuthFilePath,
        subscriptionAuthBookmarkData: nil,
        configurationPath: initial.configurationPath,
        configurationWarning: initial.configurationWarning
    )

    let saved = store.save(configuration: updated)
    let reloaded = store.loadOrCreate()

    #expect(saved.routingTable.rules.count == 1)
    #expect(saved.routingTable.rules.first?.match == "sonnet")
    #expect(reloaded.routingTable.resolve(for: "claude-sonnet-4-6").upstreamModel == "gpt-5.4-mini")
    #expect(reloaded.advisorRoute.upstreamModel == "gpt-5.4")
}
```

3. 既有 `environmentOverridesBecomeEffectiveConfiguration` 测试保持不变（CC_ROUTER_EXECUTOR_MODEL/ADVISOR_MODEL 的行为未变）；若 assert `configuration.executorModel == ...` 的断言仍用派生属性路径，不改。检查当前测试断言能否仍通过——如果老断言直接访问 `configuration.executorModel`，派生属性透明兼容。

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter RouterConfigurationMigrationTests 2>&1 | tail -20`
Expected: 5/5 tests pass（新增 `freshInstallGetsDefaultThreeRuleTable` + 原 4 个）。
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter RouterConfigurationStoreTests 2>&1 | tail -20`
Expected: 既有 5 + 新增 1 = 6/6 tests pass。
<!-- /section -->

<!-- section: task-5 keywords: anthropic-bridge, route-resolve, make-responses-payload, pending-tool-turn -->
### Task 5: AnthropicBridge 路由解析 + payload 构造改造

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift`

**Steps:**

1. `makeResponsesPayload(model:instructions:input:tools:toolChoice:)` 改签名（`AnthropicBridge.swift:716-742`）——把 `model: String` 换成 `route: ModelRoute`；body 内 `model` / `reasoning.effort` / `text.verbosity` 三字段改从 `route` 读：

```swift
private func makeResponsesPayload(
    route: ModelRoute,
    instructions: String,
    input: [JSONValue],
    tools: [JSONObject],
    toolChoice: JSONValue
) -> JSONObject {
    let reasoning = JSONObject(["effort": .string(route.reasoningEffort)])
    let textVerbosity = JSONObject(["verbosity": .string(route.textVerbosity)])
    let clientMeta = JSONObject(["x-codex-installation-id": .string(installationID)])
    return JSONObject.from([
        "model": .string(route.upstreamModel),
        "instructions": .string(instructions),
        "input": .array(input),
        "tools": .array(tools.map(JSONValue.object)),
        "tool_choice": toolChoice,
        "parallel_tool_calls": .bool(true),
        "reasoning": .object(reasoning),
        "store": .bool(false),
        "stream": .bool(true),
        "include": .array([.string("reasoning.encrypted_content")]),
        "service_tier": .string("priority"),
        "prompt_cache_key": .string(UUID().uuidString.lowercased()),
        "text": .object(textVerbosity),
        "client_metadata": .object(clientMeta),
    ])
}
```

2. `runInitialTurn`（`:275-347`）顶部解析 route：

```swift
private func runInitialTurn(
    writer: HTTPBodyWriter,
    anthropicModel: String,
    ...
) async throws {
    let resolvedRoute = configuration.routingTable.resolve(for: anthropicModel)
    let input = IRResponsesCodec.encodeInputItems(requestIR)
    let initialPayload = makeResponsesPayload(
        route: resolvedRoute,
        instructions: instructions,
        input: input,
        tools: tools,
        toolChoice: .string("auto")
    )
    ...
```

- `resolvedRoute` 需要在稍后存进新 PendingToolTurn（见 step 4）——把 `resolvedRoute` 透过 `handleOutputBlocks` 的参数传下去，或在 `runInitialTurn` 的 pending 构造点读出再用。最小改动：给 `handleOutputBlocks` 增加 `resolvedRoute: ModelRoute` 参数。

3. 续轮入口（`:192-199`）——把 `configuration.executorModel` 换成 `pending.resolvedRoute`：

```swift
let replayInput = IRResponsesCodec.encodeReplayBlocks(pending.replayIR)
let continuationPayload = makeResponsesPayload(
    route: pending.resolvedRoute,
    instructions: "",
    input: replayInput + toolResultInput,
    tools: pending.convertedTools,
    toolChoice: .string("auto")
)
```

4. `runAdvisorSubcall`（`:673-685`）——advisor 子 call 用独立 `configuration.advisorRoute`，不复用 executor route：

```swift
let advisorPayload = makeResponsesPayload(
    route: configuration.advisorRoute,
    instructions: "You are a planning advisor. Return only a short guidance paragraph with the best next-step strategy.",
    input: [.object(advisorMessage)],
    tools: [],
    toolChoice: .string("none")
)
```

5. `runAdvisorSubcallAndSecondPass`（`:559-565`）的 second pass payload——二次 call 仍用**executor route**（不是 advisor route）。但具体是哪个 route？advisor 场景第二遍是给 Claude CLI 的真答复，与首轮 executor route 一致。由于 `runAdvisorSubcallAndSecondPass` 被 `handleOutputBlocks` 调用，需要 resolvedRoute 作为入参：

```swift
private func runAdvisorSubcallAndSecondPass(
    anthropicModel: String,
    advisorCallID: String,
    outputIRBlocks: [IRBlock],
    pending: PendingToolTurn?,
    finalUsage: (input: Int, output: Int),
    resolvedRoute: ModelRoute,     // 新入参
    sessionID: String,
    credentials: SubscriptionCredentials,
    writer: HTTPBodyWriter,
    encoder: AnthropicSSEEncoder,
    startedAtUptimeNanoseconds: UInt64
) async throws {
    ...
    let secondPayload = makeResponsesPayload(
        route: resolvedRoute,
        instructions: "",
        input: replayInput + [.object(advisorOutputItem)],
        tools: pending?.convertedTools ?? [],
        toolChoice: .string("auto")
    )
    ...
}
```

6. `PendingToolTurn`（`:783-788`）添加 `resolvedRoute` 字段：

```swift
private struct PendingToolTurn: Sendable {
    let anthropicModel: String
    let convertedTools: [JSONObject]
    let replayIR: [IRBlock]
    let advisorEnabled: Bool
    let resolvedRoute: ModelRoute    // 新字段——保证同一 tool turn 两段一致
}
```

- 所有 `pendingToolTurns[sessionID] = PendingToolTurn(...)` 构造点（`:468-473`, `:596-601`）补传 `resolvedRoute: resolvedRoute`。

7. `handleOutputBlocks` 签名加 `resolvedRoute: ModelRoute`；`runInitialTurn` / `runStreamingTurn`（续轮入口）传入 `resolvedRoute`。runStreamingTurn 续轮分支里的 `resolvedRoute` 用 `pending.resolvedRoute`（不重新解析，保持 turn 内一致）。

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | grep -E "error:|AnthropicBridge"`
Expected: 零 error。
Run: `grep -n 'configuration.executorModel\|configuration.advisorModel' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: 零 match（bridge 不再直接读这两个派生字段；全部走 route 解析路径）。

**⚠️ grep 只是负向过滤器**（证明"没读 legacy 字段"），不能证实"路由从 Claude model 派生"。真正的行为 gate 是 Task 7 的 `opusRequestHitsOpusRule` + `haikuRequestHitsHaikuRuleWithDifferentEffort` 两个集成测试——只有它们通过才证明 per-Claude-model routing 生效。
<!-- /section -->

<!-- section: task-6 keywords: trace-logger, upstream-model, responses-out-initial, responses-out-continuation -->
### Task 6: 在 trace 事件中加 `upstream_model` 字段

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift`

**Steps:**

1. `responses_out_initial` 事件（`AnthropicBridge.swift:295-302`）添加 `upstream_model`：

```swift
await TraceLogger.shared.log(
    JSONObject.from([
        "stage": .string("responses_out_initial"),
        "session_id": .string(sessionID),
        "upstream_model": .string(resolvedRoute.upstreamModel),
        "tool_names": .array(tools.compactMap { $0.string("name").map(JSONValue.string) }),
        "advisor_enabled": .bool(advisorEnabled),
    ])
)
```

2. `responses_out_continuation` 事件（`:201-215`）添加 `upstream_model`（从 `pending.resolvedRoute.upstreamModel`）。

3. `responses_out_advisor_continuation` 事件（`:567-572`）添加 `upstream_model`（值 = advisor sub-call 本身的 advisor route，即 `configuration.advisorRoute.upstreamModel`；second pass 的 trace 事件另起——second pass 仍用 executor route）。但注意：当前代码里只有一个 `responses_out_advisor_continuation` trace 点在 second pass 之前，second pass 的 payload 本身没有独立 trace stage；这里为了保证 acceptance grep 覆盖 advisor turn 也记录 upstream_model，**在 second pass streamEvents 调用之前**补一个 `responses_out_initial` 形状的 trace（或复用已有 advisor_continuation stage 加 upstream_model = second pass 的 route）：

```swift
// runAdvisorSubcallAndSecondPass 里 second pass streamEvents 之前
await TraceLogger.shared.log(
    JSONObject.from([
        "stage": .string("responses_out_advisor_continuation"),
        "session_id": .string(sessionID),
        "upstream_model": .string(resolvedRoute.upstreamModel),
    ])
)
```

4. advisor sub-call 本身（`runAdvisorSubcall`）——目前走 `responsesClient.perform`（非 streaming），没有独立的 trace stage。这一步 per-phase 不需要 trace 它的 upstream_model（acceptance criteria 的 grep 只要求主路径）。跳过。

**Verify:**
Run: `grep -n 'upstream_model' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: ≥ 3 match（initial / continuation / advisor_continuation 三处各 1）。
<!-- /section -->

<!-- section: task-7 keywords: bridge-regression-tests, routing, model-routing, trace-upstream-model -->
### Task 7: BridgeRegressionTests / StreamingBridgeIntegrationTests 断言路由生效

**Files:**
- Modify: `Tests/CCRouterCoreTests/BridgeRegressionTests.swift`
- Modify: `Tests/CCRouterCoreTests/StreamingBridgeIntegrationTests.swift`
- Create: `Tests/CCRouterCoreTests/ModelRoutingBridgeIntegrationTests.swift`

**Steps:**

1. `BridgeRegressionTests.swift:17-28` 现用 legacy init（`executorModel: "gpt-5.4", advisorModel: "gpt-5.4"`）——保持不变（legacy init 仍可用），既有回归断言不改。这保证 §3.13 Bash tool turn + §3.14 advisor bridge 的现有 assertions 不变。

2. `StreamingBridgeIntegrationTests.swift:17-28` 同上——保持不变；新 route 路径的流测试走 Task 7-new。

3. 新建 `ModelRoutingBridgeIntegrationTests.swift`——断言 route 分流真的发生在 `/responses` payload 上：

```swift
import Foundation
@testable import CCRouterCore
import Testing

struct ModelRoutingBridgeIntegrationTests {
    private static let testCredentials = SubscriptionCredentials(
        accessToken: "test-access-token",
        accountID: "test-account-id"
    )

    private static func makeConfig(routingTable: ModelRoutingTable, advisorRoute: ModelRoute) -> RouterConfiguration {
        RouterConfiguration(
            host: "127.0.0.1", port: 4317,
            healthPath: "/health", messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            routingTable: routingTable,
            advisorRoute: advisorRoute,
            gatewayAuthToken: "t", gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/tmp/auth.json",
            subscriptionAuthBookmarkData: nil,
            configurationPath: "/tmp/config.json",
            configurationWarning: nil
        )
    }

    @Test
    func opusRequestHitsOpusRule() async throws {
        let config = Self.makeConfig(
            routingTable: ModelRoutingTable(
                rules: [
                    ModelRoutingRule(match: "opus", route: ModelRoute(upstreamModel: "opus-upstream", reasoningEffort: "xhigh", textVerbosity: "low")),
                    ModelRoutingRule(match: "haiku", route: ModelRoute(upstreamModel: "haiku-upstream", reasoningEffort: "medium", textVerbosity: "low")),
                ],
                fallback: ModelRoute(upstreamModel: "fallback-upstream", reasoningEffort: "xhigh", textVerbosity: "low")
            ),
            advisorRoute: ModelRoute(upstreamModel: "advisor-upstream", reasoningEffort: "xhigh", textVerbosity: "low")
        )

        let spy = MockResponsesEventStream.textOnlyMock(capture: true)
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: spy,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let requestFixture = try AnthropicMessagesRequest.textOnlyFixture(model: "claude-opus-4-7")
        let body = try JSONEncoder().encode(requestFixture)
        let response = await bridge.handleMessages(
            HTTPRequest(method: "POST", path: "/v1/messages", headers: ["x-claude-code-session-id": "S1"], body: body)
        )

        // Drive the streaming producer via InMemoryBodyWriter (reuses the helper at
        // Tests/CCRouterCoreTests/MockResponsesEventStream.swift:366).
        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("expected streaming response body, got non-streaming")
            return
        }
        try await producer(writer)

        let lastPayload = try #require(spy.latestRequestedPayload)
        #expect(lastPayload.string("model") == "opus-upstream")
        #expect(lastPayload.object("reasoning")?.string("effort") == "xhigh")
        #expect(lastPayload.object("text")?.string("verbosity") == "low")
    }

    @Test
    func haikuRequestHitsHaikuRuleWithDifferentEffort() async throws {
        // 同上结构，model: "claude-haiku-4-5-20251001"；assert upstreamModel == "haiku-upstream", effort == "medium"
        // ...（结构与上一个测试对称）
    }

    @Test
    func unmatchedModelFallsBack() async throws {
        // model: "claude-unknown-model"；assert upstreamModel == "fallback-upstream"
    }

    @Test
    func advisorSubcallUsesAdvisorRoute() async throws {
        // 用带 advisor_20260301 的 tools fixture 触发 advisor 子 call
        // spy 捕获第 2 次 responsesClient.perform 的 payload；assert model == "advisor-upstream"
    }

    @Test
    func pendingToolTurnSecondSegmentKeepsSameRoute() async throws {
        // 首轮触发 tool_use（非 advisor），第二轮带 tool_result 来续；
        // 两次 streamEvents 调用的 payload["model"] 相同（resolvedRoute 沿用）
    }
}
```

⚠️ 实现细节：`MockResponsesEventStream.textOnlyMock(capture: true)` 需要扩展 `MockResponsesEventStream`（当前 `Tests/CCRouterCoreTests/MockResponsesEventStream.swift`）——加一个可捕获最后一次 `streamEvents` / `perform` 调用 payload 的 spy 模式。若已有 capture 机制复用；若无，在本 task 里新增最小 capture 字段（两个 `Locked<JSONObject?>` 类型变量 `latestRequestedPayload` / `allRequestedPayloads: [JSONObject]`）。

4. `AnthropicMessagesRequest.textOnlyFixture(model:)` — `AnthropicProtocol.swift:3-14` 的 struct 有 11 stored fields 且无 convenience init；**用 raw JSON decode 构造**（避免直接调 memberwise init 的编译失败）：

```swift
extension AnthropicMessagesRequest {
    static func textOnlyFixture(model: String) throws -> Self {
        let json = """
        {
          "model": "\(model)",
          "messages": [
            {"role": "user", "content": [{"type": "text", "text": "hi"}]}
          ],
          "stream": true
        }
        """
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}
```

5. HTTP body 消费 — **复用既有 `InMemoryBodyWriter`**（`Tests/CCRouterCoreTests/MockResponsesEventStream.swift:366`，`HTTPBodyWriter` 的 actor 实现）。不新造 `drain(response:)` helper。测试里驱动 response 的 streaming 生产者：

```swift
import Foundation
@testable import CCRouterCore

// 在测试中：
let writer = InMemoryBodyWriter()
guard case .stream(let producer) = response.body else {
    Issue.record("expected streaming response body, got non-streaming")
    return
}
try await producer(writer)
let concatenated = await writer.concatenatedString
// 此时 mock client 的 capture 字段已经被 streamEvents 调用填充，spy.latestRequestedPayload 可读
```

（`response.body` 是 `LocalHTTPServer.HTTPResponse.Body` enum，`case stream(producer)` 来自 `LocalHTTPServer.swift:22`。）

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ModelRoutingBridgeIntegrationTests 2>&1 | tail -20`
Expected: 5/5 tests pass。
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests 2>&1 | tail -20`
Expected: 既有 BridgeRegressionTests 全部通过（回归断言未动）。
<!-- /section -->

<!-- section: task-8 keywords: probe, upstream-models, codex-auth, zstd -->
### Task 8: 创建 probe 脚本（上游模型 ID）+ research report 骨架

**Files:**
- Create: `scripts/probe_upstream_models.py`
- Create: `docs/research/2026-04-22-upstream-model-probe.md`

**Steps:**

1. `scripts/probe_upstream_models.py` — 直连 `https://chatgpt.com/backend-api/codex/responses`（不走本地网关），从 `~/.codex/auth.json` 读 `tokens.access_token` + `tokens.account_id`，对一组 model ID 发最小请求并记录结果。核心逻辑参考 `scripts/probe_responses_advisor_bridge.py` 的 `post_responses` / `compress_payload` / `parse_sse_events`：

```python
#!/usr/bin/env python3
"""
Probe upstream model IDs against the real Codex ChatGPT endpoint.

Reads ~/.codex/auth.json for credentials, POSTs a minimal /responses request
for each candidate model, records HTTP status + first-line error body (if any)
to stdout as one JSON record per candidate.

Usage:
    python3 scripts/probe_upstream_models.py \
        --models gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-4.5 gpt-5.3-codex-spark \
        --out docs/research/2026-04-22-upstream-model-probe.md
"""

import argparse, json, os, re, ssl, sys, urllib.request, urllib.error, zstandard as zstd
from pathlib import Path

UPSTREAM_URL = "https://chatgpt.com/backend-api/codex/responses"

def load_auth():
    p = Path(os.path.expanduser("~/.codex/auth.json"))
    if not p.exists():
        print(json.dumps({"error": f"auth file not found at {p}. Run `codex login` first."}), file=sys.stderr)
        sys.exit(2)
    data = json.loads(p.read_text("utf-8"))
    t = data.get("tokens") or {}
    if not t.get("access_token") or not t.get("account_id"):
        print(json.dumps({"error": f"auth file at {p} missing tokens.access_token or tokens.account_id"}), file=sys.stderr)
        sys.exit(2)
    return t["access_token"], t["account_id"]

def redact(text: str) -> str:
    """Strip potential auth strings from upstream error bodies before writing to disk."""
    # Redact Bearer tokens, long hex/base64 strings that look like account/access tokens
    text = re.sub(r'(?i)(bearer\s+)[A-Za-z0-9._-]+', r'\1<REDACTED>', text)
    text = re.sub(r'(?i)(access_token"\s*:\s*")[^"]+', r'\1<REDACTED>', text)
    text = re.sub(r'(?i)(account_id"\s*:\s*")[^"]+', r'\1<REDACTED>', text)
    return text

def minimal_payload(model):
    return {
        "model": model,
        "instructions": "",
        "input": [
            {"type": "message", "role": "user",
             "content": [{"type": "input_text", "text": "Reply OK."}]}
        ],
        "tools": [],
        "tool_choice": "auto",
        "parallel_tool_calls": False,
        "reasoning": {"effort": "xhigh"},
        "store": False,
        "stream": True,
        "include": ["reasoning.encrypted_content"],
        "service_tier": "priority",
        "prompt_cache_key": "probe-model",
        "text": {"verbosity": "low"},
    }

def probe(model, access_token, account_id):
    raw = json.dumps(minimal_payload(model), separators=(",", ":")).encode("utf-8")
    body = zstd.ZstdCompressor().compress(raw)
    req = urllib.request.Request(UPSTREAM_URL, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("chatgpt-account-id", account_id)
    req.add_header("accept", "text/event-stream")
    req.add_header("content-type", "application/json")
    req.add_header("content-encoding", "zstd")
    req.add_header("user-agent", "modelbridge-probe/phase2")
    try:
        with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=30) as r:
            raw_body = r.read()
            return {"model": model, "status": r.status, "body_snippet": redact(raw_body[:500].decode("utf-8", errors="replace"))}
    except urllib.error.HTTPError as e:
        return {"model": model, "status": e.code, "body_snippet": redact(e.read().decode("utf-8", errors="replace")[:500])}
    except Exception as e:
        # Never raise — per-request failures independently captured so other models still probe.
        return {"model": model, "status": None, "error": redact(str(e))}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--out")
    args = ap.parse_args()

    access_token, account_id = load_auth()
    results = [probe(m, access_token, account_id) for m in args.models]
    for r in results:
        print(json.dumps(r, ensure_ascii=False))
    if args.out:
        Path(args.out).write_text(
            "# Upstream Model Probe Report — 2026-04-22\n\n"
            "| model | status | first-500-chars body |\n|---|---|---|\n"
            + "\n".join(f"| `{r['model']}` | {r.get('status')} | `{(r.get('body_snippet','') or r.get('error','')).replace('|','\\|')}` |" for r in results)
            + "\n",
            encoding="utf-8"
        )

if __name__ == "__main__":
    raise SystemExit(main())
```

2. `docs/research/2026-04-22-upstream-model-probe.md` — 初始骨架，待真机运行后填入实际结果：

```markdown
# Upstream Model ID Probe — 2026-04-22

**Status:** ⚠️ pending real-machine run
**Script:** `scripts/probe_upstream_models.py`
**Endpoint:** `https://chatgpt.com/backend-api/codex/responses`

## How to run

~~~bash
python3 scripts/probe_upstream_models.py \
  --models gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-4.5 gpt-5.3-codex-spark \
  --out docs/research/2026-04-22-upstream-model-probe.md
~~~

## Candidate model IDs

- Whitelisted baseline (`docs/scheme3/10 §7.8`): `gpt-5.4` / `gpt-5.4-mini` / `gpt-5.3-codex`
- Known-rejected: `gpt-5.2-codex` / `gpt-5.1-codex-max`
- User-requested (to verify): `gpt-4.5` / `gpt-5.3-codex-spark`

## Results

| model | status | first-500-chars body |
|---|---|---|
| _pending_ | _pending_ | _pending_ |

## Conclusion

- Add to default routing table: _pending probe_
- Reject: _pending probe_
- Surface to Phase 6 Routing UI picker: _pending probe_
```

3. **真实运行 probe（用户已授权 Codex quota 消耗——DP-002-P2 Chosen: B）** ：

Run: `python3 scripts/probe_upstream_models.py --models gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-4.5 gpt-5.3-codex-spark --out docs/research/2026-04-22-upstream-model-probe.md`

期望：
- 脚本退出码 0
- `docs/research/2026-04-22-upstream-model-probe.md` 被改写，Results 表从 `_pending_` 变为真实 status 码 + body snippet（每个 model 一行）
- **每条请求独立捕获**：即使某个 model 返回 401/400/5xx，脚本继续处理下一个（不 raise），5 行结果齐备

**Verify:**
Run: `python3 scripts/probe_upstream_models.py --help`
Expected: argparse help 输出包含 `--models` / `--out`，脚本不 crash。
Run: `grep -c '^| .gpt-' docs/research/2026-04-22-upstream-model-probe.md`
Expected: 5（五个 model 各一行真实结果；`_pending_` 占位符被替换）。
Run: `grep -E '\| [0-9]{3} \|' docs/research/2026-04-22-upstream-model-probe.md | wc -l`
Expected: 至少 3（白名单内的 gpt-5.4/gpt-5.4-mini/gpt-5.3-codex 应该返回 200；gpt-4.5/gpt-5.3-codex-spark 预期返回 400，但也算 3-digit status）。
Run: `ls -la scripts/probe_upstream_models.py docs/research/2026-04-22-upstream-model-probe.md`
Expected: 两个文件存在且可读。

**⚠️ Probe 结果与 defaultTable 的关系：** probe 结果只记录进 research report，**不自动修改 `Sources/CCRouterCore/ModelRouting.swift` 的 `defaultTable`**。若白名单 ID（`gpt-5.4` / `gpt-5.4-mini` / `gpt-5.3-codex`）意外返回非 200，Phase 2 仍按现 hardcode 白名单 ship，由用户 review report 后在后续 phase 手动更新 `defaultTable`。若用户定向 ID（`gpt-4.5` / `gpt-5.3-codex-spark`）probe 返回 200，也由用户 review 后决定是否在 Phase 6 UI 切换时追加进 routing 表——与 DP-001 chosen C 一致。
<!-- /section -->

<!-- section: task-9 keywords: probe, reasoning-effort, enum -->
### Task 9: 创建 probe 脚本（`reasoning.effort` 枚举）+ report 骨架

**Files:**
- Create: `scripts/probe_reasoning_effort.py`
- Create: `docs/research/2026-04-22-reasoning-effort-probe.md`

**Steps:**

1. `scripts/probe_reasoning_effort.py` — 与 Task 8 结构对称，但遍历的是 `reasoning.effort` 的候选值 (`low / medium / high / xhigh`)，`model` 固定为 `gpt-5.4`（白名单内且已验证）：

```python
# 仅列出与 probe_upstream_models.py 不同的差异部分
EFFORTS = ["low", "medium", "high", "xhigh"]
def minimal_payload(effort):
    base = {
        "model": "gpt-5.4",
        # ... 同 probe_upstream_models 的 minimal_payload
        "reasoning": {"effort": effort},
    }
    return base

# main 遍历 args.efforts (默认全部 EFFORTS)
```

2. `docs/research/2026-04-22-reasoning-effort-probe.md` — 同结构骨架，列出 `low/medium/high/xhigh`。

3. **真实运行 probe（DP-002-P2 Chosen: B）** ：

Run: `python3 scripts/probe_reasoning_effort.py --efforts low medium high xhigh --out docs/research/2026-04-22-reasoning-effort-probe.md`

期望：4 行真实结果写入 report；每条请求独立捕获，失败也记录并继续。

**Verify:**
Run: `python3 scripts/probe_reasoning_effort.py --help`
Expected: 显示 help，argparse 包含 `--efforts` / `--out`。
Run: `grep -c '^| .' docs/research/2026-04-22-reasoning-effort-probe.md | head -1`
Expected: ≥ 4（四个 effort 值各一行）。
<!-- /section -->

<!-- section: task-10 keywords: probe, text-verbosity, enum -->
### Task 10: 创建 probe 脚本（`text.verbosity` 枚举）+ report 骨架

**Files:**
- Create: `scripts/probe_text_verbosity.py`
- Create: `docs/research/2026-04-22-text-verbosity-probe.md`

**Steps:**

1. `scripts/probe_text_verbosity.py` — 与 Task 9 结构对称，遍历 `text.verbosity` ∈ `{low, medium, high}`；`model` = `gpt-5.4`；`reasoning.effort` = `xhigh`。

2. `docs/research/2026-04-22-text-verbosity-probe.md` — 骨架。

3. **真实运行 probe（DP-002-P2 Chosen: B）** ：

Run: `python3 scripts/probe_text_verbosity.py --verbosities low medium high --out docs/research/2026-04-22-text-verbosity-probe.md`

期望：3 行真实结果写入 report。

**Verify:**
Run: `python3 scripts/probe_text_verbosity.py --help`
Expected: 显示 help。
Run: `grep -c '^| .' docs/research/2026-04-22-text-verbosity-probe.md | head -1`
Expected: ≥ 3。
<!-- /section -->

---

## Acceptance Checklist Mapping（plan task ↔ dev-guide acceptance）

| Dev-guide acceptance | Plan task(s) covering it |
|---|---|
| `swift test` 新增 ModelRoutingTests.swift | Task 1 + Task 2 |
| `swift test` 新增 RouterConfigurationMigrationTests.swift | Task 4 |
| Probe 任务产出 `docs/research/2026-04-22-upstream-model-probe.md` | Task 8（脚本 + 真实运行填充——DP-002-P2 Chosen: B） |
| Probe 任务产出 `docs/research/2026-04-22-reasoning-effort-probe.md` | Task 9（脚本 + 真实运行填充） |
| Probe 任务产出 `docs/research/2026-04-22-text-verbosity-probe.md` | Task 10（脚本 + 真实运行填充） |
| 真机 opus/sonnet/haiku 分流到不同上游 | Task 5 + Task 7（integration test）+ 真机验证 |
| `grep upstream_model /tmp/modelbridge-trace.jsonl` 至少 2 个值 | Task 6（trace 字段）＋ 真机验证 |
| `bash scripts/smoke_local_gateway.sh` 通过 | 真机验证（non-automated） |
| Phase 1 streaming + IR 断言仍通过 | Task 7 保留既有 BridgeRegressionTests / StreamingBridgeIntegrationTests 不改；Task 5 的 bridge 改动不触动 Phase 1 IR 边界 |

## Recommended additions (not in scope)

无。Phase 6 将扩展 trace 字段 `claude_model` / `reasoning_effort` / `text_verbosity` / `resolved_route_match`，本 phase 明确不做。

---

## Verification

- **Verdict:** Approved
- **Date:** 2026-04-22
- **Reports:**
  - Cycle 1: `.claude/reviews/plan-verifier-2026-04-22-144526.md` — must-revise (2 items: Task 3 fresh-install defaultTable; Task 7 textOnlyFixture compile)
  - Cycle 2: `.claude/reviews/plan-verifier-2026-04-22-150836.md` — must-revise (1 item: `FakeSessionLoader` → `MockSessionLoader(credentials:)`), then applied inline. Both cycle-1 items confirmed resolved.
- **Applied cycle-1 revisions:**
  - Task 3 `normalizedConfiguration`: 3-branch logic (stored routingTable → use; else legacy executorModel → single-rule migration; else fresh install → `ModelRoutingTable.defaultTable`). Same pattern for advisorRoute.
  - Task 4: added `freshInstallGetsDefaultThreeRuleTable` test asserting `configuration.routingTable == ModelRoutingTable.defaultTable` on clean install.
  - Task 7: `AnthropicMessagesRequest.textOnlyFixture(model:)` rewritten as raw-JSON decode `throws` extension.
  - Task 7: replaced synthetic `drain(response:)` helper with explicit `InMemoryBodyWriter` reuse from `Tests/CCRouterCoreTests/MockResponsesEventStream.swift:366`; deleted HTTPBodyWriter API uncertainty ⚠️.
  - Task 5 Verify: added caveat that grep is a negative filter; Task 7 integration tests are the real behavior gate.
  - Task 3: added "Read-only impact" note listing GatewayDaemon/DoctorSnapshot/SettingsView/ContentView.
  - Task 8: added `~/.codex/auth.json` existence pre-check + `redact()` for bearer/access_token/account_id in body snippets + note that probe results don't auto-update defaultTable.
- **Applied cycle-2 revision:**
  - Task 7: replaced non-existent `FakeSessionLoader()` with `MockSessionLoader(credentials: Self.testCredentials)` pattern used elsewhere in the test suite; added `testCredentials` static.
