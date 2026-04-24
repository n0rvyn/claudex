## Feature Review Report

### 功能
Phase 6 Routing Insights + Settings Routing Editor — Dashboard shows per-Claude-model metrics and routing targets; Settings allows routing table + advisor route editing + token refresh status.

---

## Part A: 产品完整性

### A1. User Story 覆盖

#### Journey 1: Routing Editor (Settings / Upstream tab)

| Story | Entry Point | Status |
|-------|-------------|--------|
| User sees current routing rules | `UpstreamSettingsTab` renders `routingRulesDraft` List from `AppModel` | ✅ `SettingsView.swift:408-421` |
| User adds a rule | `addRoutingRule()` button at `SettingsView.swift:423-425` | ✅ `ContentView.swift:526-530` |
| User edits a rule | `RoutingRuleDraftRow` with bound `$draft` pickers at `SettingsView.swift:599-635` | ✅ bound to `routingRulesDraft` |
| User deletes a rule | Delete button `onDelete: { model.removeRoutingRule(id: rule.id) }` | ✅ `SettingsView.swift:413` |
| User saves and routing hot-reloads | `saveRoutingAndApply()` at `ContentView.swift:540-612` | ✅ |
| Hot reload actually updates `AnthropicBridge` in-memory state | `daemon.applyRoutingUpdate(table:table, advisorRoute:advisor)` → `AnthropicBridge.updateRouting()` at `AnthropicBridge.swift:308-317` | ✅ |
| Routing save persists to disk | `configurationStore.save()` → `RouterConfigurationStore.swift:64-96` | ✅ |
| Error: save with empty keyword | Guard at `ContentView.swift:557-560` sets `routingSaveError` | ✅ |
| Error: save with invalid port | Guard at `ContentView.swift:541-545` sets `routingSaveError` | ✅ |
| Feedback: routingSaveError shown in UI | `if let error = model.routingSaveError` at `SettingsView.swift:403-407` | ✅ |
| Feedback: statusText updated after save | `refreshSnapshot(runningText: "Routing and upstream settings saved")` at `ContentView.swift:611` | ✅ |

**Story 覆盖: 11/11 ✅**

#### Journey 2: Token Status (Settings / Upstream tab, bottom)

| Story | Entry Point | Status |
|-------|-------------|--------|
| User sees access token preview | `doctorSnapshot?.accessTokenPreview` at `SettingsView.swift:483` | ✅ |
| User sees last_refresh time | `relativeRefreshText(model.doctorSnapshot?.lastRefresh)` at `SettingsView.swift:489` | ✅ |
| User clicks "Refresh now" | `Button(action: { Task { await model.refreshTokenNow() } })` at `SettingsView.swift:503` | ✅ |
| Refresh shows progress indicator | `if model.isRefreshingToken { ProgressView() }` at `SettingsView.swift:507-509` | ✅ |
| Refresh button disabled during refresh | `.disabled(model.isRefreshingToken)` at `SettingsView.swift:506` | ✅ |
| Refresh success: statusText updated | `refreshSnapshot(runningText: "Subscription token refreshed")` at `ContentView.swift:625` | ✅ |
| Refresh failure: error surfaced in UI | `if let error = model.tokenRefreshError` at `SettingsView.swift:513-517` | ✅ |
| Token state dot reflects refresh state | `tokenDotState` computed at `SettingsView.swift:578-582` | ✅ |
| Token status auto-refreshes every 30s | `startTokenStatusPolling()` task at `SettingsView.swift:532-534` | ✅ |

**Story 覆盖: 9/9 ✅**

#### Journey 3: Dashboard Routing Insights

| Story | Entry Point | Status |
|-------|-------------|--------|
| Dashboard shows three rows (haiku/sonnet/opus) | `routingInsights` computed at `ContentView.swift:317-336`, rendered at `ContentView.swift:1185` | ✅ |
| Each row shows upstream model + effort | `row.currentRouteLabel = "upstreamModel · effort"` at `ContentView.swift:326` | ✅ |
| Each row shows request count + avg latency | `routingInsightMetricText(row.metrics)` at `ContentView.swift:1272-1275` | ✅ |
| Metrics come from trace aggregation | `TraceLogger.diagnostics()` computes `perClaudeModelMetrics` → `TraceDiagnostics.perClaudeModelMetrics` → `ClaudeModelMetrics` | ✅ |

**Story 覆盖: 4/4 ✅**

---

### A2. 用户旅程死路检测

| Journey Path | Verdict |
|-------------|---------|
| Dashboard popover → routing insights rows | ✅ Dead end: rows have no tap gesture, no navigation. Not a crash — just no drill-down. See scope gap below. |
| Settings → Upstream tab → Add rule → empty keyword → Save | ✅ Error message shown, user can fix and retry. No dead end. |
| Settings → Upstream tab → Token refresh → fails | ✅ Error text shown (`tokenRefreshError`), button re-enabled, user can retry. No dead end. |
| Settings → Upstream tab → Save routing | ✅ `statusText` confirms save. No dead end. |
| Save routing with invalid auth bookmark | ✅ `canPersistDraftAuthPath()` guards, `statusText` set. No dead end. |

**死路检测: 5 paths, 0 dead ends** (1 design-intent gap — drill-down — flagged in Part B)

---

### A3. 导航深度

- Dashboard popover (root) → routing insights rows: depth 1 ✅
- Settings window (root) → Upstream tab (depth 1) ✅
- No navigation deeper than 1 level in Phase 6 features ✅

---

## Part B: UX 完整性

### B1. 操作反馈完整性

| Operation | Success feedback | Failure feedback | In-progress feedback |
|-----------|-----------------|-----------------|---------------------|
| Save routing + upstream | `statusText = "Routing and upstream settings saved"` | `routingSaveError` shown in red text | — (synchronous save, no async) |
| Token refresh | `statusText = "Subscription token refreshed"` + dot state | `tokenRefreshError` shown in red text | `ProgressView()` + disabled button |
| Choose auth file | `statusText` set on success/error | `statusText` set on error | Panel blocks UI |
| Reload config | `statusText = "Configuration reloaded"` | — | — |

**Missing: no toast/alert/sheet for save success confirmation beyond a brief statusText** — statusText is ephemeral and may be overwritten by the 2.5s refresh loop. No persistent confirmation.

### B2. 关键操作确认流程

- **Routing rule deletion**: no confirmation dialog. `removeRoutingRule` removes immediately. Risk: moderate (rules can be re-added, not irreversible).
- **Advisor route change**: no confirmation. Saved directly.
- **Gateway token regeneration**: no confirmation dialog. Regenerates immediately at `ContentView.swift:639-647`.
- No destructive operations involving irreversible data loss.

**No `.confirmationDialog` for any destructive action** — `RoutingRuleDraftRow` delete button is unprotected. Since rules are persisted to disk, deletion is permanent until next save.

### B3. 空状态处理

| List | Empty state |
|------|-------------|
| Recent trace lines (`recentSection`) | ✅ `Text(MBCopy.trafficEmptyLong)` at `ContentView.swift:1130-1135` |
| Routing insights metrics | ✅ "—" shown when `row.metrics == nil` at `ContentView.swift:1199-1201` |
| Routing rules List | ❌ No empty state — List renders with `frame(minHeight:150, maxHeight:260)`, shows empty space with no placeholder text or "Add your first rule..." guidance |
| Token status access token | ✅ "—" when `accessTokenPreview` is nil at `SettingsView.swift:483` |

---

## 🔴 必须修复

### 🔴-1: Routing Insights rows — 设计意图缺口 (scope omission)

- **Location**: `ContentView.swift:1185-1208`
- **Problem**: Dev-guide line 328 states "点击单行可下钻到该 Claude 模型的详细 trace 列表" — clicking a row should drill down to per-model trace list. The `routingInsightsSection` `HStack` rows have no `.onTapGesture`, no `NavigationLink`, no drill-down destination. Rows are static display-only.
- **Impact**: The Phase 6 acceptance criteria explicitly calls for drill-down; this is a scope omission, not a bug. User cannot inspect per-model traces from the Dashboard.
- **Evidence**: `routingInsightsSection` body — only `Text` and `VStack`, zero interactive modifiers on rows.
- **建议**: Add `@State private var selectedInsight: RoutingInsightRow?` + `.sheet` or `NavigationLink` to a detail view showing the selected model's trace lines filtered by `claudeModelKey`. Alternatively, document this as a deferred Phase 8 item and acknowledge the gap in the Phase 6 checklist.

### 🔴-2: Routing rules List — 无空状态占位符

- **Location**: `SettingsView.swift:408-421`
- **Problem**: `List` shows empty when `routingRulesDraft` is empty. No `ContentUnavailableView`, no "Add your first rule" text, no placeholder.
- **Impact**: User may not understand how to start adding rules; the Add button is below the empty list.
- **建议**: Wrap the `List` with an `if model.routingRulesDraft.isEmpty` branch showing `MBCopy.trafficEmptyShort` or a custom empty label with the "Add rule" button inline, before the list.

### 🔴-3: Token refresh error — 重新登录引导缺失

- **Location**: `SettingsView.swift:513-517` + `ContentView.swift:626-628`
- **Problem**: When `refreshTokenNow()` throws (e.g., expired refresh_token requiring full re-auth), the error string is shown but there is no "Re-authorize" action or link to the auth file chooser. The Upstream tab already has an auth re-authorization block for `model.requiresAuthAttention` — but token refresh failure does not set `requiresAuthAttention`, so that block does not appear.
- **Impact**: User sees "Token refresh failed: ..." with no clear recovery path.
- **建议**: In `refreshTokenNow()`, on specific error types (401, 403), set a flag that triggers the same re-authorization guidance as `requiresAuthAttention`. Or add an inline `Button(action: { model.chooseSubscriptionAuthFile() })` that appears in the error state.

---

## 🟡 建议修复

### 🟡-1: Save success feedback is ephemeral

- **Location**: `ContentView.swift:611`
- **Problem**: `statusText = "Routing and upstream settings saved"` is written, but the 2.5s `refresh()` timer overwrites it at the next cycle with whatever the daemon reports. User gets a flash of confirmation but no durable record.
- **建议**: Consider adding a transient `.overlay` toast, or a dedicated `MBKpi` card in the Settings footer that briefly highlights "Saved" before reverting.

### 🟡-2: Routing hot reload — no daemon restart required, correct

- **Location**: `ContentView.swift:610` → `GatewayDaemon.swift:75-77` → `AnthropicBridge.swift:308-317`
- **Status**: Hot reload is correctly implemented — `bridge.updateRouting()` mutates the actor's in-memory `routingTable` and `advisorRoute` without server restart. `TraceLogger` emits a `routing_hot_reload` stage log.
- **Verdict**: ✅ Correctly implemented.

### 🟡-3: Advisor route save scope — correctly isolated from executor

- **Location**: `ContentView.swift:581-585` + `AppModel.syncRoutingDraftsFromConfiguration` at line 842
- **Status**: `advisorRouteDraft` is separate from the routing table. The `saveRoutingAndApply()` path at line 581-585 constructs `advisor` from `advisorRouteDraft` and passes it to `updateRouting()`. The executor routing table is unaffected.
- **Verdict**: ✅ Correctly scoped.

### 🟡-4: Gateway token regeneration — no confirmation

- **Location**: `ContentView.swift:639-647`
- **Problem**: Regenerating the gateway token invalidates the current `x-api-key`. If the daemon is running, Claude Code CLI will fail auth until the user copies the new token. No confirmation dialog.
- **建议**: Add a `.confirmationDialog` before regeneration explaining that Claude Code will need to re-copy the environment snippet.

### 🟡-5: Trace diagnostics limit — 64 lines may be insufficient for Phase 6 observability

- **Location**: `GatewayDaemon.swift:42`
- **Observation**: `diagnostics(limit: 64)` reads only the last 64 trace lines for aggregation. With 3 Claude models active, 64 lines may not capture enough per-model samples for reliable p50/p95. The `perClaudeModelMetrics` aggregation at `TraceLogger.swift:203-219` depends on having enough `anthropic_out` events in the window.
- **建议**: Consider increasing the limit to 200-500, or making the limit configurable, to ensure stable per-model metrics during light usage.

---

## 设计意图缺口 (Scope)

### Drill-down for Routing Insights rows — not in Phase 6 scope

Per the dev-guide (line 328), clicking a row should drill down to per-model trace list. The Phase 6 plan scope (line 319-329) explicitly mentions this behavior in the user-visible changes, but the Task list does not include a drill-down implementation task. The current implementation (static `HStack` rows with no interaction) confirms Task 4 did not include drill-down.

**结论**: This is a scope omission, not a bug. Phase 6 implementation is complete against its stated task list, but the user-visible spec at line 328 was not fully implemented. Recommend: add drill-down to Phase 8 scope or to Phase 6 scope expansion, and update the dev-guide to reflect the gap.

---

## Part C: 设备验证清单

请在设备上验证：

- [ ] 从 Dashboard popover → 打开后 Routing insights 三行是否存在？每行的上游模型标签是否正确反映当前配置？
- [ ] 发起一条 sonnet 请求后，Dashboard 的 Routing insights sonnet 行是否更新了请求计数？延迟是否出现？
- [ ] 打开 Settings → Upstream tab → 将 haiku 路由的 upstream model 从 gpt-5.3-codex-spark 改为 gpt-5.4 → 保存 → 立即发一条 haiku 请求 → trace log 里的 `upstream_model` 字段是否反映新配置（无需重启 daemon）？
- [ ] 验证上一步的 `routing_hot_reload` 阶段是否出现在 trace log 中。
- [ ] 打开 Settings → Upstream tab → 将一个路由规则的 keyword 留空 → 点击 Save → 是否看到红色错误提示"Routing rule keywords cannot be empty"？
- [ ] 打开 Settings → Upstream tab → Token status 区 → 确认 access token 前缀和 last_refresh 时间是否显示（需要先有 trace 数据）→ 点击 Refresh now → 按钮是否变为禁用 + 显示 ProgressView？
- [ ] Token refresh 失败时（例如模拟 auth.json 缺失 refresh_token），错误信息是否出现？是否有重新授权的引导？
- [ ] 在 Routing rules List 全空时，是否有任何空状态提示还是一片空白？
- [ ] 点击 Gateway tab 的 Regenerate 按钮 → 是否弹出确认对话框？点击确认后，Claude Code 是否需要重新复制新的 token 才能继续工作？
- [ ] Dashboard routing insights 行点击是否产生任何响应？（预期：无响应 — 缺口已记录）

---

## 总结

| Category | Result |
|----------|--------|
| User Story 覆盖 | 24/24 ✅ |
| 死路检测 | 5 paths, 0 dead ends ✅ |
| 导航深度 | Max 1 level ✅ |
| 操作反馈完整性 | 4/4 operations have success/failure/in-progress paths; 1 ephemeral feedback concern |
| 关键操作确认 | 0 unreviewed destructive actions (delete/regenerate unguarded, advisory only) |
| 空状态处理 | 3/4 lists have empty states; routing rules List is missing one |
| 🔴 必须修复 | 3 |
| 🟡 建议修复 | 5 |
| 设计意图缺口 | 1 (drill-down not in Phase 6 task scope, per dev-guide line 328) |
| 设备验证项 | 10 |

**Verdict: FAIL** (due to 3 🔴 issues: drill-down design-intent gap, missing routing rules empty state, missing re-login guidance on token refresh failure).

---

Report: `.claude/reviews/feature-reviewer-2026-04-24-110005.md`
