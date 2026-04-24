# ModelBridge Sandboxed Auth Flow Repair

## 0. Summary / 摘要

修复当前 sandboxed `ModelBridge.app` 在真实运行路径里仍然无法访问 `~/.codex/auth.json` 的问题。目标不是继续把错误信息写得更清楚，而是把“缺少授权”变成明确的阻断状态和主路径入口，让用户在第一次运行时就完成授权，并让 `/health`、菜单栏面板和真实 `Claude Code CLI -> 4317` 路径保持一致。

## 1. Goals & Non-Goals / 目标与非目标

- Goals:
  - [ ] sandbox 保持开启时，用户第一次使用就能完成 `~/.codex/auth.json` 授权，不需要猜去哪里点设置
  - [ ] 未授权状态下，app 不再表现成“daemon 正常运行但请求必失败”
  - [ ] `/health` 能区分“未授权 / bookmark 丢失 / 文件缺失 / token 缺失”
  - [ ] 用户完成授权后，daemon 使用持久化 bookmark 正常读取 auth 文件，真实 CLI 请求可通过
- Non-goals:
  - 不改 `ENABLE_APP_SANDBOX`
  - 不改上游 `/responses` 协议桥接逻辑
  - 不把 `~/.codex/auth.json` 内容复制进 app container 或 Keychain

## 2. Current State Recon / 现状勘察（只读证据）

- 真实监听进程：
  - `lsof -nP -iTCP:4317 -sTCP:LISTEN`
  - 结果：当前监听 `4317` 的是 `ModelBrid` app 进程，不是独立 CLI daemon
- 当前 health：
  - `curl -sS http://127.0.0.1:4317/health`
  - 结果：
    - `subscriptionAuthFilePath = /Users/norvyn/.codex/auth.json`
    - `chatGPTAuthenticated = false`
    - `authError = Sandbox access is not authorized for /Users/norvyn/.codex/auth.json; choose the auth file in Settings.`
    - `configurationPath = /Users/norvyn/Library/Containers/com.90percent.ModelBridge/Data/Library/Application Support/ModelBridge/config.json`
- 触发错误的代码路径：
  - [SubscriptionSession.swift](/Users/norvyn/Code/Projects/ModelBridge/Sources/CCRouterCore/SubscriptionSession.swift)
  - `loadAuthFileData()` 在 `securityScopedBookmarkData == nil` 且进程 home 位于 container 时抛出 `.authorizationRequired`
- 当前授权入口：
  - [SettingsView.swift](/Users/norvyn/Code/Projects/ModelBridge/ModelBridge/SettingsView.swift)
  - 只有 `Settings > Subscription auth > Choose`
- 当前保存逻辑：
  - [ContentView.swift](/Users/norvyn/Code/Projects/ModelBridge/ModelBridge/ContentView.swift)
  - `chooseSubscriptionAuthFile()` 生成 bookmark 并调用 `persistSubscriptionAuthAuthorization`
- 当前问题本质：
  - 代码已经支持 bookmark 读取
  - 但真实用户路径没有把“必须先授权”变成主流程；daemon 仍可先启动，CLI 仍可先打进来，最后只得到 503
  - 所以这次修复只补了底层能力，没有补真实产品路径

## 2.5 Breaking Points / 断点计算

按当前代码和运行态，break 发生在这 5 个位置：

1. **配置层 break**
   - [RouterConfigurationStore.swift](/Users/norvyn/Code/Projects/ModelBridge/Sources/CCRouterCore/RouterConfigurationStore.swift:130)
   - 现在允许 `subscriptionAuthFilePath` 有值，但 `subscriptionAuthBookmarkData == nil`
   - 这会产生“看起来配置完整，实际没有 sandbox 访问权”的半有效状态

2. **启动层 break**
   - [ContentView.swift](/Users/norvyn/Code/Projects/ModelBridge/ModelBridge/ContentView.swift:162)
   - `startDaemon()` 直接启动 `GatewayDaemon`
   - 启动前没有任何 “auth 已授权” guard
   - 结果：daemon 能先绑住 `4317`

3. **运行时 break**
   - [SubscriptionSession.swift](/Users/norvyn/Code/Projects/ModelBridge/Sources/CCRouterCore/SubscriptionSession.swift:72)
   - 第一条真实请求进来时才检查 bookmark；没有 bookmark 就抛 `authorizationRequired`
   - 结果：真正的失败被推迟到请求期，而不是启动期

4. **UI 路径 break**
   - [SettingsView.swift](/Users/norvyn/Code/Projects/ModelBridge/ModelBridge/SettingsView.swift:425)
   - `Choose` 只存在于 Settings；主菜单栏面板没有同等级 CTA
   - [ContentView.swift](/Users/norvyn/Code/Projects/ModelBridge/ModelBridge/ContentView.swift:738)
   - 主面板却继续暴露 `Start` 和 `Copy env`
   - 结果：用户会先启动 daemon、复制环境变量、再让 CLI 撞上 503

5. **可观测性 break**
   - [DoctorSnapshot.swift](/Users/norvyn/Code/Projects/ModelBridge/Sources/CCRouterCore/DoctorSnapshot.swift:19)
   - `/health` 只有 `chatGPTAuthenticated` 和 `authError`
   - 它不能告诉我们到底是：
     - 根本没保存 bookmark
     - bookmark 保存了但失效
     - `startAccessingSecurityScopedResource()` 被拒绝
   - 结果：当前诊断信息不够支持精确修复

## 3. Options / 方案选择

| 方案 | 架构合理性 | 实现量 | 风险或代价 | 适用场景 |
|---|---|---|---|---|
| A. 保持现状，只靠 Settings 里的 `Choose` | 低 | 小 | 继续出现“功能存在但默认不可用”的假健康状态；用户仍会先踩坑 | 不可接受 |
| B. 保留底层 bookmark 能力，并把授权做成启动阻断 + 主界面 CTA + health 明确状态 | 高 | 中 | 需要调整菜单栏/设置页状态机与 daemon 启停逻辑 | 推荐；符合当前 sandbox 边界 |
| C. 把 auth 文件内容导入 container/Keychain，后续不再依赖原文件 | 中 | 大 | 改变安全模型；要设计 token 同步和失效策略；与当前文件授权模型不同 | 当前不选 |

### Why B

当前证据已经说明底层 bookmark 代码不是主要缺口；缺的是“真实用户路径”。继续停留在 A，只是把错误提示从隐式失败改成显式失败。B 才是把 sandbox 约束变成可用产品行为的修复。

## 4. Planned Changes / 文件与改动概览

### Files to Modify

- `ModelBridge/ContentView.swift`
  - Purpose: 把“未授权”纳入 `AppModel` 的主状态机；增加主路径授权动作；在缺少授权时阻止 daemon 进入可运行状态
  - Type of change: 状态机调整、行为修复、用户路径补全

- `ModelBridge/SettingsView.swift`
  - Purpose: 保留 `Choose`，但把授权状态与 CTA 做成更明确的阻断提示，而不是埋在文本说明里
  - Type of change: 设置 UI 调整

- `Sources/CCRouterCore/SubscriptionSession.swift`
  - Purpose: 把 auth 失败细分为稳定可消费的状态，不只是一段字符串
  - Type of change: 错误模型收敛

- `Sources/CCRouterCore/AnthropicBridge.swift`
  - Purpose: doctor/health 输出结构升级，暴露更具体的 auth state
  - Type of change: doctor 状态输出调整

- `Sources/CCRouterCore/DoctorSnapshot.swift`
  - Purpose: 新增 auth authorization state 字段
  - Type of change: 模型扩展

- `Sources/CCRouterCore/GatewayDaemon.swift`
  - Purpose: `/health` 与 app snapshot 对齐新的 auth state；必要时反映 daemon 被授权阻断
  - Type of change: snapshot 结构调整

- `Sources/CCRouterCore/RouterConfiguration.swift`
  - Purpose: 如需要，增加显式 auth state 所需字段
  - Type of change: 配置模型调整

- `Sources/CCRouterCore/RouterConfigurationStore.swift`
  - Purpose: 做“已有 path 但无 bookmark”的迁移判断，给 UI 一个稳定的“需要重新授权”状态
  - Type of change: 配置迁移与归一化

### Files to Add

- `Tests/CCRouterCoreTests/AuthorizationStateTests.swift`
  - Purpose: 覆盖未授权、bookmark 失效、文件缺失、正常读取的状态映射

### Files to Remove

- None

## 5. Milestones & Acceptance Criteria / 里程碑与验收标准

- Milestone 1: 把 auth 问题建模成显式状态
  - What changes:
    - 引入稳定的 auth state，而不是只靠 `localizedDescription`
    - 区分 `authorizationRequired`、`bookmarkResolutionFailed`、`authFileMissing`、`missingAccessToken`、`missingAccountID`
  - Files:
    - `Sources/CCRouterCore/SubscriptionSession.swift`
    - `Sources/CCRouterCore/AnthropicBridge.swift`
    - `Sources/CCRouterCore/DoctorSnapshot.swift`
    - `Sources/CCRouterCore/GatewayDaemon.swift`
  - Acceptance criteria:
    - `/health` 返回可区分的 auth state 字段
    - app UI 不再只能显示一段模糊错误字符串
  - Rollback:
    - 回退新增状态字段，保留现有 bookmark 读取逻辑

- Milestone 2: 把授权入口移到真实用户路径
  - What changes:
    - 在主面板增加明确 CTA，例如 `Authorize Auth File`
    - 检测到未授权时，点击 CTA 直接打开 `NSOpenPanel`
    - 缺少授权时禁止把 daemon 呈现成“ready”
  - Files:
    - `ModelBridge/ContentView.swift`
    - `ModelBridge/SettingsView.swift`
  - Acceptance criteria:
    - 新装或旧配置迁移后，用户不进 Settings 也能完成授权
    - 菜单栏面板在未授权时明确显示阻断状态
  - Rollback:
    - 保留 settings 内 `Choose`，移除主面板 CTA

- Milestone 3: 迁移与真实运行验证
  - What changes:
    - 针对“已有 `subscriptionAuthFilePath` 但 `bookmark == nil`”给出 `needsAuthorization` 状态
    - 授权完成后自动重启 daemon，并刷新 `/health`
  - Files:
    - `Sources/CCRouterCore/RouterConfigurationStore.swift`
    - `ModelBridge/ContentView.swift`
    - `Tests/CCRouterCoreTests/*`
  - Acceptance criteria:
    - 授权前 `/health` 显示未授权
    - 授权后 `/health` 显示 `chatGPTAuthenticated = true`
    - 真实 Claude CLI 请求不再卡在本地 gateway 503
  - Rollback:
    - 仅保留 bookmark 读写，不做迁移判断

## 6. Test Plan / 测试计划（PLAN 阶段只描述，不执行）

- Planned automated tests (to run in EXECUTE):
  - `swift test`
  - 针对 auth state 增加单测，覆盖：
    - sandbox + no bookmark
    - sandbox + stale bookmark
    - bookmark -> missing file
    - valid bookmark -> credentials loaded
  - 增加 app-model 级行为测试，覆盖：
    - 未授权时不允许进入 ready/startable 状态
    - 主面板 CTA 触发授权后会刷新状态并允许启动
- Manual checks:
  - 启动 `ModelBridge.app`
  - 在主面板看到 `Authorize Auth File` CTA
  - 选择 `~/.codex/auth.json`
  - `curl -sS http://127.0.0.1:4317/health`
  - 预期 `chatGPTAuthenticated = true`
  - 用真实 `ANTHROPIC_BASE_URL=http://127.0.0.1:4317` 跑一次 `claude`

## 7. Risks & Replan Triggers / 风险与再规划触发条件

- Risks:
  - `NSOpenPanel` 只能从前台可交互 scene 正常弹出；如果菜单栏窗口状态不对，需要调整触发点
  - bookmark 可能 stale；需要设计 UI 上的重新授权路径
  - 现有 UI 状态较多，主面板新增阻断态时要避免和 daemon running/paused 状态冲突
- Replan triggers:
  - 发现 sandbox 进程即使有 bookmark 仍无法 `startAccessingSecurityScopedResource()`
  - 发现当前 app bundle entitlement 与 user-selected file bookmark 不兼容
  - 真实 `claude` 请求在 `/health` 已 green 后仍失败，说明问题不在 auth 流程层

## 8. TODOs / 下一步工作

- [ ] 定义统一 auth state 模型
- [ ] 把主面板改成授权优先入口
- [ ] 做旧配置迁移
- [ ] 跑真实 `/health` 和 Claude CLI 验证

## Notes / 备注

- 当前 fix 不是“完全错误”，但它只解决了底层读取能力，没有解决真实用户第一次使用的路径。
- 本次正式修复必须把“授权缺失”从隐藏配置问题，升级成产品主路径的一等状态。
- 当前测试只证明了两件事：
  - [SubscriptionSessionTests.swift](/Users/norvyn/Code/Projects/ModelBridge/Tests/CCRouterCoreTests/SubscriptionSessionTests.swift:8) 直接文件读取可用
  - [SubscriptionSessionTests.swift](/Users/norvyn/Code/Projects/ModelBridge/Tests/CCRouterCoreTests/SubscriptionSessionTests.swift:26) sandbox + 无 bookmark 会失败
- 当前测试**没有**证明：
  - bookmark 保存后能在下一次 app 启动中成功恢复
  - UI 授权动作真的把 bookmark 送进了运行中的 daemon
  - 未授权时 app 会阻止用户进入坏路径
