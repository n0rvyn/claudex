---
type: plan
status: active
tags: [auth, refresh, count-tokens, bpe, subscription]
refs:
  - docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
  - docs/scheme3/03-anthropic-edge.md
  - docs/scheme3/14-count-tokens-observation-v1.md
---

# Phase 5: 认证 Refresh + count_tokens 精度 Implementation Plan

**Goal:** Codex 订阅 `access_token` 过期时 daemon 自动刷新（不再 503），`/v1/messages/count_tokens` 从 `body.count/4` 启发式切到已有的 `cl100k_base` BPE 真实 tokenizer。

**Architecture:**
- **Refresh path:** `~/.codex/auth.json` 已验证存在 `tokens.refresh_token` + `tokens.id_token` + 顶层 `last_refresh`（本次 probe 已确认 4 个 tokens 子键 + last_refresh）。`SubscriptionCredentials` 扩字段 `refreshToken` + `idToken` + `lastRefresh`。新增 `AuthTokenRefresher` 用 `URLSession` 向 Task 1 探明的 refresh 端点发 POST，成功后通过 `FileManager.replaceItemAt` 原子替换 `auth.json`（保留 0600 权限，见 DP-P5-003）。**关键结构**：`handleMessages` 必须在 `prepareTurn` 成功后、返回 `HTTPResponse(200, stream: closure)` **之前**先显式调用 `responsesClient.streamEvents(...)` 建立流；若 `streamEvents` 抛 `ResponsesHTTPError.statusCode == 401` → 调 `sessionLoader.refreshAndReload()` → 成功则用新 credentials 重新 `streamEvents`；第二次仍 401 或 refresh 失败则返回 503。流建立成功后把已握手的 `AsyncThrowingStream<JSONObject, Error>` 传入 `runPreparedTurn` 的 body closure（该函数需要重构签名从"自建流"改为"接收现有流"）。这是因为 `LocalHTTPServer.swift:402-414` 先 flush 200 header 再调用 body producer 闭包，401 在 header flush 之后捕获已无法改 status code。
- **count_tokens path:** `Sources/CCRouterCore/AnthropicInputTokenCounter.swift:7` + `CL100KEncoder` 已在 Phase 4 前建好（`cl100k_base.tiktoken` resource 已打包，`AnthropicInputTokenCounterTests` 已覆盖 identical/longer/tool-schema 三种场景）；现有工作仅在 `AnthropicBridge.swift:417/344` 两处 `messageStartInputTokens` 调用。Phase 5 把 `GatewayDaemon.swift:130` `max(1, request.body.count / 4)` 替换为 Anthropic 请求 → responses-shape payload → `AnthropicInputTokenCounter.countInputTokens` 的路径；`DoctorSnapshot.countTokensStrategy` 字符串从 `"body-size-heuristic"` 改为 `"cl100k-bpe"`（共 3 处：`GatewayDaemon.swift:52`、`:96`、`Tests/CCRouterCoreTests/DoctorSnapshotTests.swift:11`）。
- **Scope boundary:** Phase 5 只动 Anthropic 入口的 count_tokens 精度与订阅 token 生命周期。`/responses` 上游侧仍用 `usage.input_tokens` 作为 ground truth（不改 `AnthropicBridge.processUpstreamStream` 的 usage 路径）。**只拦截"第一次"streamEvents 的 401**：`AnthropicBridge.swift:791`（tool 续回合的 second-pass streamEvents）与 `:947`（advisor subcall perform）的 401 在 Phase 5 不处理 — 这两处发生在同一会话的第二轮 HTTP 调用，access_token 刚在第一次握手用过，瞬时过期概率极低；若真发生则沿用现有 500 映射，依赖下一次 fresh 请求走到 Phase 5 的 retry 路径。

**Tech Stack:** Swift 6 actor + `URLSession` + `FileManager` atomic write + 现有 `CL100KEncoder` BPE。

**Design doc:** none（design evidence 来自 `docs/scheme3/03-anthropic-edge.md §4.3` + `docs/scheme3/14-count-tokens-observation-v1.md` + `Sources/CCRouterCore/AnthropicInputTokenCounter.swift` 已实现代码）

**Design analysis:** none

**Crystal file:** none（Phase 5 无视觉决策；全部是后台逻辑）

**Threat model:** included

---

## Threat Model

### 1. Attack surface

| Input source | Attack class | Mitigation |
|--------------|--------------|-----------|
| `~/.codex/auth.json` 文件内容 | 恶意替换导致 JSON 注入/token 外泄 | 已存在：`SubscriptionSessionLoader.loadCurrent` 走 `JSONDecoder.decode(AuthFile.self,...)`，非 JSON 即 `authFileInvalid`。Phase 5 新增字段沿用 strict decode，不加 `try?` 容错 |
| Refresh 响应 body | 响应注入含 `access_token: "<script>"` 等奇异字符 | `AuthTokenRefresher` 对响应做 strict JSON decode 到 `RefreshResponse` struct；未知字段忽略；token 值直接写入 bearer header，不进 HTML/shell |
| Refresh 失败时的 retry loop | 401 → refresh → 401 → refresh 的死循环 | 单次重试上限：`handleMessages` 捕获 401 只触发一次 refresh，第二次 401 直接返回错误；`AnthropicBridge` 不维持 "refreshed-this-turn" 状态之外的标记 |
| 并发请求共同触发 refresh | 多请求竞态写入 auth.json | `SubscriptionSessionLoader` 是 actor；refresh+write-back 在 actor 方法内串行化；并发请求要么看到新 token，要么等 refresh 完成 |

### 2. Failure modes

- **Refresh endpoint 返回非 200 / 响应 body 不是预期 JSON：** `AuthTokenRefresher` 抛 `AuthRefreshError.refreshFailed(statusCode, body)`。`SubscriptionSessionLoader.refreshAndReload()` 捕获后重置 authState 为 `.authorizationRequired` 并 rethrow。`AnthropicBridge` 看到 rethrow 后直接返回 503 + Anthropic error envelope，不再重试。
- **Refresh 成功但 auth.json 写失败（disk full / permission denied）：** refresh 已完成但磁盘未更新 —— 当前请求用新 token 重发（内存中已有新 credentials）；下次 daemon 重启若读到旧 auth.json 会再次触发 refresh。这是可接受的 "degraded but self-healing" 行为。记录 warning trace 供用户排查。
- **BPE tokenizer resource 缺失（打包 bug）：** `CL100KEncoder.loadFromBundle` 已经抛 `missingTokenizerResource`。count_tokens endpoint 捕获后返回 500 + "tokenizer resource missing" 错误正文；不悄悄退回 `body.count/4`（见 DP-P5-002）。
- **BPE encode 抛 `unknownTokenPiece`：** cl100k_base 是 byte-level BPE，理论上不会遇到 unknown；若真发生说明 resource 损坏。同 resource 缺失，返回 500。
- **401 在 non-refresh 路径（token 本身有效但权限变更）：** `AuthTokenRefresher` 的 refresh 请求返回 401 / 403 时，走 refresh-failed 路径；Phase 5 不区分 "token expired" vs "权限被撤销"。

### 3. Resource lifecycle

| Task | Temp files / handles | Cleanup on success | Cleanup on error | Cleanup on signal |
|------|---------------------|--------------------|-----------------|-------------------|
| Task 4 原子写 auth.json | `FileManager.default.replaceItemAt` 写入 item replacement directory 的 temp file，rename 覆盖 destination 并保留 0600 权限 | 自动：`replaceItemAt` rename 成功后 temp 消失 | 自动：`replaceItemAt` 失败保留原 auth.json 和 temp（稍后可能被 macOS 清理） | N/A：写入是 sync 调用，信号处理由 OS |
| Task 3 AuthTokenRefresher URLSession | 默认 shared config；无文件句柄 | 自动：URLSession 管 socket | `try await` rethrow；不泄漏 task | 进程退出时 URLSession 自动 teardown |
| Task 5 并发 refresh | 无额外资源；走 actor 同步 | actor 自身 | actor 自身 | actor 进程退出时释放 |

### 4. Input validation requirements

- **`AuthFile.Tokens.refresh_token` 解码后：** 直接用在 POST body 的 JSON `refresh_token` 字段（不进 shell / SQL / regex）；Task 3 必须用 `JSONEncoder` 构造 body，不拼接字符串。
- **Refresh endpoint URL：** 来自 Task 1 probe 结果硬编码在 `AuthTokenRefresher`（如 `https://auth.openai.com/oauth/token` 等）；不从 `auth.json` 读 endpoint（防 `auth.json` 篡改跳转到攻击者域名）。
- **Anthropic `count_tokens` 请求 body：** 已有 `JSONDecoder().decode(AnthropicMessagesRequest.self,...)` 约束类型；Task 6 新增路径直接用同样的 decoder。

---

<!-- section: task-1 keywords: refresh-endpoint, codex-cli, probe, research -->
### Task 1: Probe Codex 刷新端点并记录请求/响应形状（verification task）

**Goal:** 从开源 `codex-cli 0.121.0` 源码确认 refresh 端点 URL、HTTP 方法、请求 body 字段、响应 body 字段、以及 `last_refresh` 在写回时的格式。无源码理解就实现 refresh 会被代表同一个函数签名猜错。

**Files:**
- Create: `docs/research/2026-04-23-codex-refresh-endpoint-probe.md`

**Steps:**
1. 用 `WebFetch` 拉取 `https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/lib.rs` 与 `.../codex-rs/core/src/auth.rs` 与 `.../codex-rs/chatgpt/src/chatgpt_client.rs` 等候选文件，搜索 `refresh_token` / `refresh` / `token_endpoint`。若 main 分支与 0.121.0 差异明显，fetch `https://raw.githubusercontent.com/openai/codex/rust-v0.121.0/...` 对照。
2. 记录下列字段到 probe 报告：
   - Refresh endpoint URL（完整 scheme + host + path）
   - HTTP method（通常 POST）
   - Request Content-Type（`application/x-www-form-urlencoded` 或 `application/json`）
   - Request body 字段列表（典型 OAuth refresh：`grant_type=refresh_token` + `refresh_token=<value>` + `client_id=<value>`）
   - Response body 字段列表（典型：`access_token` / `refresh_token` / `id_token` / `expires_in`）
   - `last_refresh` 写回格式（ISO 8601 timestamp？`Date().timeIntervalSince1970`？）
   - **Refresh_token rotation semantics（并发安全关键 — DP-002）**：源码路径里新 refresh_token 是否替换旧 refresh_token？
     - 若响应 body 含新的 `refresh_token` 字段且源码逻辑显示旧 token 在服务端失效（one-time-use / rotating）→ 记 `rotating: true`；Task 4 必须启用 cache-hit short-circuit（见 Task 4 Step 3）
     - 若响应 body 不含 `refresh_token` 或含但源码显示旧 token 仍有效 → 记 `rotating: false`；plan 显式声明 "并发双 refresh 幂等，actor 串行化足够"
     - 若源码无决定性证据 → 记 `rotating: unknown; defaulting to "true" for safety`；Task 4 走保守路径（启用 cache-hit short-circuit）
3. 报告 conclusion 段落包含：
   - "Endpoint confirmed: `<url>`"
   - "Request shape: `<curl example>`"
   - "Response shape: `<typescript-style interface>`"
   - "Refresh_token rotating: `<true|false|unknown>`" 附源码 file:line 引用
   - "If endpoint differs between main and 0.121.0: `<diff summary>`"
4. 报告开头附 frontmatter：`type: research` / `date: 2026-04-23` / `phase: 5` / `source: github.com/openai/codex`。

**Verify:**
Run: `ls -la docs/research/2026-04-23-codex-refresh-endpoint-probe.md && grep -E "^(Endpoint confirmed|Request shape|Response shape|Refresh_token rotating):" docs/research/2026-04-23-codex-refresh-endpoint-probe.md`
Expected: 四行都非空；endpoint URL 以 `https://` 开头；Request shape 含 `refresh_token`；Refresh_token rotating 取值 `true|false|unknown` 之一。

⚠️ No test: 纯 research 产物，不进入编译路径。验证由后续 Task 3 在实现中引用此报告的 endpoint 字符串作为证据。
<!-- /section -->

---

<!-- section: task-2 keywords: auth-file, subscription-credentials, decoder -->
### Task 2: 扩展 `AuthFile` decoder + `SubscriptionCredentials` 字段

**Files:**
- Modify: `Sources/CCRouterCore/SubscriptionSession.swift:3-11` (`SubscriptionCredentials` struct)
- Modify: `Sources/CCRouterCore/SubscriptionSession.swift:198-205` (`AuthFile` + `Tokens` decoder)
- Modify: `Sources/CCRouterCore/SubscriptionSession.swift:112-132` (`loadCurrent` 读取逻辑)
- Test: `Tests/CCRouterCoreTests/SubscriptionSessionTests.swift` (新增 `refreshTokenAndLastRefreshParsedFromAuthFile` 测试)

**Steps:**
1. `SubscriptionCredentials` 增加两个 optional 字段 + 显式 init（保留默认参数以向后兼容）：
   ```swift
   public struct SubscriptionCredentials: Sendable, Equatable {
       public let accessToken: String
       public let accountID: String
       public let refreshToken: String?
       public let lastRefresh: Date?

       public init(
           accessToken: String,
           accountID: String,
           refreshToken: String? = nil,
           lastRefresh: Date? = nil
       ) {
           self.accessToken = accessToken
           self.accountID = accountID
           self.refreshToken = refreshToken
           self.lastRefresh = lastRefresh
       }
   }
   ```
   **保留现有 2-arg 调用路径**（`BridgeRegressionTests.swift:31` 等 12 处 test 站点）通过默认参数自动兼容。生产代码路径（`SubscriptionSessionLoader.loadCurrent` Step 5）显式传 4 参。
2. `AuthFile.Tokens` 扩展字段：
   ```swift
   let access_token: String?
   let account_id: String?
   let refresh_token: String?
   let id_token: String?
   ```
3. `AuthFile` 顶层扩展 `last_refresh: String?`（probe 显示是顶层字段，不是 tokens 子对象 — 见 Task 1 probe 报告；如 Task 1 报告 conclusion 不同则以 probe 结果为准）。
4. `loadCurrent` 解析 `last_refresh`：若 ISO 8601 字符串（probe 报告定格式），用 `ISO8601DateFormatter` 解析；失败返回 `nil` 但不 throw（last_refresh 是辅助字段）。
5. `loadCurrent` 构造 `SubscriptionCredentials` 时带上 `refreshToken: payload.tokens?.refresh_token` + `lastRefresh: parsedLastRefresh`。
6. 新测试 `refreshTokenAndLastRefreshParsedFromAuthFile`:
   - Fixture JSON：`{"tokens":{"access_token":"a","account_id":"b","refresh_token":"r","id_token":"i"},"last_refresh":"2026-04-23T10:00:00Z"}`
   - Assert credentials.refreshToken == "r"，credentials.lastRefresh != nil。
7. 新测试 `missingRefreshTokenDoesNotBreakLoad`:
   - Fixture 只含 `access_token` + `account_id`（老 auth.json 格式）
   - Assert credentials.accessToken == "a"，credentials.refreshToken == nil，不 throw。

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -20`
Expected: Build success；`Sources/CCRouterCore/SubscriptionSession.swift` 无编译错误。
Run: `grep -n "refreshToken\|lastRefresh\|refresh_token\|id_token" Sources/CCRouterCore/SubscriptionSession.swift | head`
Expected: 至少 6 行命中。
<!-- /section -->

---

<!-- section: task-3 keywords: token-refresher, urlsession, oauth -->
### Task 3: 实现 `AuthTokenRefresher`

**Files:**
- Create: `Sources/CCRouterCore/AuthTokenRefresher.swift`
- Test: `Tests/CCRouterCoreTests/AuthTokenRefresherTests.swift`

**Steps:**
1. 定义 protocol：
   ```swift
   public protocol AuthTokenRefreshing: Sendable {
       func refresh(refreshToken: String, clientID: String?) async throws -> RefreshedTokens
   }

   public struct RefreshedTokens: Sendable, Equatable {
       public let accessToken: String
       public let refreshToken: String   // upstream may rotate
       public let idToken: String?
       public let lastRefresh: Date
   }

   public enum AuthRefreshError: Error {
       case refreshFailed(statusCode: Int, body: String)
       case invalidResponseBody(String)
   }
   ```
2. 实现 `public actor AuthTokenRefresher: AuthTokenRefreshing`：
   - Init 接受 `endpoint: URL`（默认来自 Task 1 probe — 硬编码 const；如 probe 报告显示与 0.121.0 分支差异，按 0.121.0 为准）。
   - Init 接受 `session: URLSession`（默认构造如下；测试时注入 URLProtocol stub）：
     ```swift
     let config = URLSessionConfiguration.default
     config.timeoutIntervalForRequest = 10      // first byte deadline
     config.timeoutIntervalForResource = 15     // overall refresh deadline
     self.session = session ?? URLSession(configuration: config)
     ```
     **Rationale**：默认 60s timeout 对 refresh 过长；若 refresh endpoint hang，用户请求会 hang 60s 后才 fallback 503。10s/15s 与人类等待容忍度一致。
3. `refresh(...)` 方法：
   - 按 Task 1 probe 的请求形状构造 `URLRequest`（form-urlencoded 或 JSON 由 probe 决定）。**严格按 probe 报告的字段列表**，不擅自增减。
   - `let (data, response) = try await session.data(for: request)`
   - 非 2xx → 抛 `refreshFailed(statusCode, bodyString)`
   - 2xx → `JSONDecoder().decode(RefreshResponse.self, from: data)`；decode 失败抛 `invalidResponseBody`。
   - 成功返回 `RefreshedTokens(accessToken:, refreshToken:, idToken:, lastRefresh: Date())`。
4. 新测试 `AuthTokenRefresherTests`:
   - `successfulRefreshReturnsNewTokens`：用 URLProtocol stub 返回 200 + valid JSON，assert `RefreshedTokens.accessToken == "new-access"`。
   - `http401ThrowsRefreshFailed`：stub 返回 401，assert throw `refreshFailed(statusCode: 401, ...)`。
   - `malformedJSONThrowsInvalidResponseBody`：stub 返回 200 + `"not json"`，assert throw `invalidResponseBody`。
   - `networkErrorThrowsURLError`：stub 返回 URLError，assert rethrown URLError（让 caller 区分 network vs auth）。

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | grep -E "error|warning" | head -5`
Expected: 无 error；`AuthTokenRefresher.swift` 编译通过。
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter AuthTokenRefresherTests 2>&1 | tail -10`
Expected: 4/4 tests pass。
<!-- /section -->

---

<!-- section: task-4 keywords: auth-json, atomic-write, session-loader -->
### Task 4: `SubscriptionSessionLoader` 增加 `refreshAndReload` + 原子写回 `auth.json`

**Files:**
- Modify: `Sources/CCRouterCore/SubscriptionSession.swift:91-93` (`SubscriptionSessionProviding` 协议)
- Modify: `Sources/CCRouterCore/SubscriptionSession.swift:95-196` (`SubscriptionSessionLoader` actor)
- Test: `Tests/CCRouterCoreTests/SubscriptionSessionTests.swift` (新增 refresh 相关 3 测试)

**Steps:**
1. `SubscriptionSessionProviding` 协议扩展：
   ```swift
   public protocol SubscriptionSessionProviding: Sendable {
       func loadCurrent() async throws -> SubscriptionCredentials
       func refreshAndReload() async throws -> SubscriptionCredentials
   }
   ```
   提供默认实现：
   ```swift
   public extension SubscriptionSessionProviding {
       func refreshAndReload() async throws -> SubscriptionCredentials {
           throw SubscriptionSessionError.authorizationRequired(URL(fileURLWithPath: "/"))
       }
   }
   ```
   这样现有 test fakes（`MockSessionLoader` 等）不需要实现新方法即可编译。
2. `SubscriptionSessionLoader` init 增加 `refresher: any AuthTokenRefreshing = AuthTokenRefresher()` 参数（测试可注入 mock）。
3. 实现 `refreshAndReload`:
   - **Cache-hit short-circuit（DP-002 保守分支）**：actor 内维护 `private var lastSuccessfulRefreshAt: Date?` + `private var cachedCredentialsAfterRefresh: SubscriptionCredentials?`；进入方法先判断：
     ```swift
     if let last = lastSuccessfulRefreshAt,
        Date().timeIntervalSince(last) < 5.0,
        let cached = cachedCredentialsAfterRefresh {
         return cached
     }
     ```
     这一段**条件性启用**：如果 Task 1 probe 报告写 `rotating: false`，注释掉此 block 并在注释中引用 probe 报告；如果 `rotating: true` 或 `rotating: unknown`（默认保守），保留此 block。读取 probe 报告后执行者决定 — 不是运行时 flag。
   - 读当前 `auth.json`（复用现有 `loadAuthFileData`），保留结果中的 `url` 用作 destination（bookmark 路径会给出 scopedURL；否则是 authFileURL）
   - `guard let refreshToken = current.refreshToken else { throw authorizationRequired }`
   - `let refreshed = try await refresher.refresh(refreshToken: refreshToken, clientID: <probe-determined-value>)`
   - 在内存中更新 credentials 并立刻返回给 caller — **先返回 credentials，再尝试写回**。写回失败不影响当前请求（degraded but self-healing：本次请求用新 token 继续，下次启动会再次触发 refresh）。具体控制流：
     ```swift
     let newCredentials = SubscriptionCredentials(
         accessToken: refreshed.accessToken,
         accountID: current.accountID,
         refreshToken: refreshed.refreshToken,
         lastRefresh: refreshed.lastRefresh
     )
     // Update actor-local cache BEFORE write-back so the short-circuit covers
     // concurrent callers even if disk write fails.
     lastSuccessfulRefreshAt = refreshed.lastRefresh
     cachedCredentialsAfterRefresh = newCredentials
     do {
         try writeAuthFileAtomically(refreshed: refreshed, destinationURL: resolvedURL)
     } catch {
         await TraceLogger.shared.log(JSONObject.from([
             "stage": .string("subscription_refresh_writeback_failed"),
             "error_message": .string(String(describing: error).prefix(200)),
         ]))
         // Do NOT rethrow: memory cache has fresh credentials.
     }
     return newCredentials
     ```
4. 实现 `writeAuthFileAtomically(refreshed:destinationURL:)`:
   - 解码 destination 当前 JSON → 生成可变 dict（保留 `OPENAI_API_KEY` 等 probe 报告中列出的其他顶层字段；仅更新 `tokens.access_token` + `tokens.refresh_token` + `tokens.id_token` + 顶层 `last_refresh`）
   - 编码为 `Data`（`JSONSerialization.data(withJSONObject:options:.prettyPrinted)`）
   - 取 item replacement directory（与 destination 同 volume）：
     ```swift
     let tempDir = try FileManager.default.url(
         for: .itemReplacementDirectory,
         in: .userDomainMask,
         appropriateFor: destinationURL,
         create: true
     )
     let tempURL = tempDir.appendingPathComponent("auth.json.tmp")
     try encodedData.write(to: tempURL)
     ```
   - `replaceItemAt` 原子替换（保留 destination 的 0600 权限）：
     ```swift
     _ = try FileManager.default.replaceItemAt(
         destinationURL,
         withItemAt: tempURL,
         backupItemName: nil,
         options: []
     )
     ```
   - **security-scoped bookmark 写回路径**：若 `securityScopedBookmarkData` 非空，整个写入必须在 `startAccessingSecurityScopedResource() / stop` 区间内执行（mirror 读入路径的 `loadWithSecurityScopedBookmark`）：
     ```swift
     guard scopedURL.startAccessingSecurityScopedResource() else {
         throw SubscriptionSessionError.authorizationRequired(scopedURL)
     }
     defer { scopedURL.stopAccessingSecurityScopedResource() }
     // tempDir must be appropriateFor: scopedURL (not authFileURL) so temp is on same volume
     // ... writeData + replaceItemAt within this defer window ...
     ```
   - `replaceItemAt` 抛 `NSFileWriteNoPermissionError` 或其他 Cocoa error 时，rethrow；`refreshAndReload` 的外层 catch（见 Step 3）会 log warning 并吞掉错误，保持 memory credentials 新鲜。
5. 新测试 `refreshAndReloadUpdatesCredentials`:
   - Temp dir 写一个 fixture `auth.json`（含 `OPENAI_API_KEY: "sk-test"`, `tokens.access_token: "old"`, `tokens.refresh_token: "r-old"`, `tokens.account_id: "acc-1"`）
   - Inject mock refresher 返回 `RefreshedTokens(accessToken: "new-a", refreshToken: "r-new", ...)`
   - 调 `refreshAndReload()`
   - Assert 返回 credentials.accessToken == "new-a"
   - Assert temp dir 里的 `auth.json` 被 JSON decode 后 `tokens.access_token == "new-a"`、`tokens.refresh_token == "r-new"`、`OPENAI_API_KEY` 字段**保持** "sk-test"（不被 refresh 擦除）
6. 新测试 `refreshAndReloadPreservesFilePermissions`:
   - 写 fixture 并 `chmod 0600`
   - 调 `refreshAndReload()`
   - Assert `FileManager.default.attributesOfItem(atPath:)` 的 `.posixPermissions` 仍是 `0o600`
7. 新测试 `refreshWithNoRefreshTokenThrowsAuthorizationRequired`:
   - Fixture `auth.json` 只有 access_token（老格式）
   - `refreshAndReload()` 应 throw `authorizationRequired`
   - Fixture 文件内容不变
8. 新测试 `refreshFailureDoesNotCorruptAuthFile`:
   - Fixture `auth.json` 含 refresh_token
   - Inject mock refresher 抛 `refreshFailed(401, ...)`
   - `refreshAndReload()` 应 rethrow
   - Fixture 文件内容保持原样（byte-for-byte 相同）
9. 新测试 `refreshWritebackFailureReturnsCredentialsWithoutThrow`:
   - Fixture `auth.json` 位于可读但不可写的路径（用 `chmod 0400` 或写到只读目录）
   - Inject mock refresher 返回 `RefreshedTokens`
   - `refreshAndReload()` 应**不 throw**，返回 credentials.accessToken == "new-a"
   - Trace log 应含 `subscription_refresh_writeback_failed` stage

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter SubscriptionSessionTests 2>&1 | tail -15`
Expected: 原有测试全绿 + 新增 3 测试全绿（共 ≥ 原有 + 3）。
<!-- /section -->

---

<!-- section: task-5 keywords: anthropic-bridge, retry-on-401, preflight-stream, token-refresh-integration -->
### Task 5: `AnthropicBridge` preflight streamEvents + 401 → refresh → retry once

**Architectural rewrite：** 当前 `handleMessages`（`AnthropicBridge.swift:44-96`）在 `prepareTurn` 成功后立刻 `return HTTPResponse(statusCode: 200, ..., stream: { writer in runPreparedTurn(...) })`；`runPreparedTurn`（line 429-）内部才调 `streamEvents`。`LocalHTTPServer.swift:402-414` 先 flush 200 headers 再调 body producer，所以 `streamEvents` 抛的 401 永远在 header-flushed 之后捕获，无法改 response 状态码。Phase 5 必须把**第一次** `streamEvents` 的 TLS 握手 + 状态码拿到 → 在 `handleMessages` 外层（headers 未 flush）就捕获 401 → refresh → 重建流 → 成功后把**已建立**的 `AsyncThrowingStream<JSONObject, Error>` 传给 body closure。

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:44-96` (`handleMessages` — 加 preflight streamEvents + retry loop)
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:429-` (`runPreparedTurn` 签名改为接收 `initialStream: AsyncThrowingStream<JSONObject, Error>`，不再内部调 streamEvents)
- Modify: `Tests/CCRouterCoreTests/MockResponsesEventStream.swift:448` (`MockSessionLoader` 扩展 `refreshAndReload`)
- Test: `Tests/CCRouterCoreTests/BridgeRegressionTests.swift` (新增 3 测试)

**Steps:**
1. 重构 `runPreparedTurn` 签名：
   ```swift
   private func runPreparedTurn(
       writer: HTTPBodyWriter,
       preparedTurn: PreparedTurn,
       sessionID: String,
       credentials: SubscriptionCredentials,
       startedAtUptimeNanoseconds: UInt64,
       initialStream: AsyncThrowingStream<JSONObject, Error>   // NEW: pre-established stream
   ) async throws
   ```
   原 `let stream = try await responsesClient.streamEvents(request: preparedTurn.firstPassPayload, credentials: credentials)`（约 `:441`）删除，改用传入的 `initialStream`。其余逻辑（advisor subcall / second pass / `:791` / `:947`）保持不变，继续内部 `streamEvents`（不在 Phase 5 scope）。
2. 在 `handleMessages` 的 `case .turn(let preparedTurn)` 分支（约 `:79-95`），在 `return HTTPResponse(stream:...)` **之前**新增 preflight 重试块：
   ```swift
   // Preflight: establish the first /responses stream before flushing 200 headers.
   // If 401, refresh once and retry. Second 401 or refresh failure → return 503.
   var activeCredentials = credentials
   var initialStream: AsyncThrowingStream<JSONObject, Error>
   do {
       initialStream = try await responsesClient.streamEvents(
           request: preparedTurn.firstPassPayload,
           credentials: activeCredentials
       )
   } catch let error as ResponsesHTTPError where error.statusCode == 401 {
       await TraceLogger.shared.log(JSONObject.from([
           "stage": .string("subscription_refresh_attempt"),
           "session_id": .string(sessionID),
           "trigger": .string("upstream_401"),
       ]))
       do {
           activeCredentials = try await sessionLoader.refreshAndReload()
       } catch let refreshError {
           await TraceLogger.shared.log(JSONObject.from([
               "stage": .string("subscription_refresh_failure"),
               "session_id": .string(sessionID),
               "error_message": .string(String(describing: refreshError).prefix(200)),
           ]))
           let response = anthropicError(
               statusCode: 503,
               errorType: "authentication_error",
               message: "Subscription authorization expired; refresh failed: \(refreshError.localizedDescription)"
           )
           await logRequestOutcome(sessionID: sessionID, response: response,
               startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
               result: "refresh_failed", errorType: "authentication_error",
               errorMessage: refreshError.localizedDescription)
           return response
       }
       await TraceLogger.shared.log(JSONObject.from([
           "stage": .string("subscription_refresh_success"),
           "session_id": .string(sessionID),
           "access_token_suffix": .string(String(activeCredentials.accessToken.suffix(4))),
           "last_refresh": activeCredentials.lastRefresh.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
       ]))
       // Second attempt; if this also 401s, surface as 503.
       do {
           initialStream = try await responsesClient.streamEvents(
               request: preparedTurn.firstPassPayload,
               credentials: activeCredentials
           )
       } catch let retryError as ResponsesHTTPError where retryError.statusCode == 401 {
           let response = anthropicError(
               statusCode: 503,
               errorType: "authentication_error",
               message: "Subscription authorization expired after refresh"
           )
           await logRequestOutcome(sessionID: sessionID, response: response,
               startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
               result: "double_401", errorType: "authentication_error",
               errorMessage: "upstream rejected refreshed token")
           return response
       }
   }
   // (Other errors — 5xx, network — fall through to the existing outer catch
   //  which maps them to Anthropic api_error responses.)
   return HTTPResponse(
       statusCode: 200, reasonPhrase: "OK",
       headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
       stream: { [self, preparedTurn, sessionID, activeCredentials, initialStream] writer in
           try await self.runPreparedTurn(
               writer: writer, preparedTurn: preparedTurn, sessionID: sessionID,
               credentials: activeCredentials, startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
               initialStream: initialStream
           )
       }
   )
   ```
3. Note：preflight block 抛的非-401 error（如 5xx、network）继续 bubble 到现有 `handleMessages` 外层 catch（`AnthropicBridge.swift:97-111`）→ 走现有 500 / Anthropic error envelope 路径；不需要新增 catch arm。
4. 扩展 `MockSessionLoader`（`Tests/CCRouterCoreTests/MockResponsesEventStream.swift:448`）。**DP-003 Chosen: A**：修改原 struct 定义为 `final class`（不是 extension，因为 struct extension 不能加 stored property）；保持构造签名不变（20+ 现有 call sites 无需修改）；用 `NSLock` 保护 mutable fields；标 `@unchecked Sendable`：
   ```swift
   final class MockSessionLoader: SubscriptionSessionProviding, @unchecked Sendable {
       let credentials: SubscriptionCredentials
       private let lock = NSLock()
       private var _refreshedCredentials: SubscriptionCredentials?
       private var _refreshError: Error?
       private var _refreshAndReloadCallCount: Int = 0

       init(
           credentials: SubscriptionCredentials,
           refreshedCredentials: SubscriptionCredentials? = nil,
           refreshError: Error? = nil
       ) {
           self.credentials = credentials
           self._refreshedCredentials = refreshedCredentials
           self._refreshError = refreshError
       }

       var refreshAndReloadCallCount: Int {
           lock.lock(); defer { lock.unlock() }
           return _refreshAndReloadCallCount
       }

       func loadCurrent() async throws -> SubscriptionCredentials { credentials }

       func refreshAndReload() async throws -> SubscriptionCredentials {
           lock.lock()
           _refreshAndReloadCallCount += 1
           let error = _refreshError
           let cred = _refreshedCredentials
           lock.unlock()
           if let error { throw error }
           return cred ?? credentials
       }
   }
   ```
   **`let credentials` 读取路径不变**（class property 与 struct property Swift 语法相同；不需要 await）。`refreshedCredentials` / `refreshError` 改为 constructor 参数；新增 `.refreshAndReloadCallCount` 属性供测试断言用。
5. 新测试 `handleMessagesRetriesOnce401AfterRefresh`（在 `BridgeRegressionTests.swift`）:
   - Mock responses client：第一次 streamEvents 抛 `ResponsesHTTPError(statusCode: 401, body: "expired")`，第二次返回 valid SSE 流（含 `response.completed`）
   - Mock session loader：`loadCurrent` 返回初始 credentials，`refreshAndReload` 返回 `refreshedCredentials` with accessToken "new-a"
   - 调 `handleMessages(fixture)`
   - Assert response.statusCode == 200
   - Assert mock responses client.streamEventsCallCount == 2
   - Assert mock session loader.refreshAndReloadCallCount == 1
   - Assert trace log 含 `stage=subscription_refresh_success` 且 `access_token_suffix == "ew-a"`（末 4 位）
6. 新测试 `secondConsecutive401ReturnsAuthorizationRequired`:
   - Mock responses client：两次 streamEvents 都抛 401
   - Mock session loader：`refreshAndReload` 成功返回新 credentials
   - Assert response.statusCode == 503
   - Assert response body 含 `"authentication_error"` 类型
   - Assert mock session loader.refreshAndReloadCallCount == 1（不再第二次 refresh）
7. 新测试 `refreshFailureDuringRetryReturns503`:
   - Mock responses client：第一次抛 401
   - Mock session loader：`refreshAndReload` 抛 `SubscriptionSessionError.authorizationRequired(...)`
   - Assert response.statusCode == 503
   - Assert response body 含 `"authentication_error"` 与 `"refresh failed"` 关键词

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | grep -E "error:|warning:" | head -10`
Expected: 无 error；`runPreparedTurn` 签名变更没有漏补的 call site。
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests 2>&1 | tail -10`
Expected: 原有测试全绿 + 新增 3 测试全绿。
Run: `grep -n "subscription_refresh_success\|subscription_refresh_failure\|initialStream\|refreshAndReload" Sources/CCRouterCore/AnthropicBridge.swift | head`
Expected: 至少 6 行命中。
<!-- /section -->

---

<!-- section: task-6 keywords: count-tokens-endpoint, cl100k, gateway-daemon, bpe-wire -->
### Task 6: `/v1/messages/count_tokens` 端点接入 `AnthropicInputTokenCounter`

**Files:**
- Modify: `Sources/CCRouterCore/GatewayDaemon.swift:9-18` (init / bridge 保有 counter 的可见性)
- Modify: `Sources/CCRouterCore/GatewayDaemon.swift:116-132` (count_tokens route case)
- Modify: `Sources/CCRouterCore/GatewayDaemon.swift:52,96` (`countTokensStrategy: "cl100k-bpe"`)
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift` (新 public method `handleCountTokens(_ request: HTTPRequest) async -> HTTPResponse`)
- Modify: `Tests/CCRouterCoreTests/DoctorSnapshotTests.swift:11` (字面量 `"body-size-heuristic"` → `"cl100k-bpe"`)
- Test: `Tests/CCRouterCoreTests/CountTokensEndpointTests.swift` (新 file)

**Steps:**
1. `AnthropicBridge` 新增 public method。**Hard-require：必须走 IR codec 复用路径（DP-001 Chosen: C）**，不允许 inline 重写。`IRAnthropicCodec`（`Sources/CCRouterCore/IR/IRAnthropicCodec.swift:7`）与 `IRResponsesCodec.encodeFullHistory`（`Sources/CCRouterCore/IR/IRResponsesCodec.swift:233`）均为 `public enum` / `public static`，无可见性障碍。实现形如：
   ```swift
   public func handleCountTokens(_ request: HTTPRequest) async -> HTTPResponse {
       do {
           let anthropicRequest = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request.body)
           let responsesShapePayload = buildCountablePayload(from: anthropicRequest)
           let count = try await inputTokenCounter.countInputTokens(for: responsesShapePayload)
           return try HTTPResponse.json(value: CountTokensResponse(input_tokens: count))
       } catch {
           return anthropicError(statusCode: 400, errorType: "invalid_request_error", message: "Count tokens: \(error.localizedDescription)")
       }
   }

   private func buildCountablePayload(from request: AnthropicMessagesRequest) -> JSONObject {
       // Must reuse the same IR path as prepareTurn (AnthropicBridge.swift:~178) so
       // count_tokens endpoint's output is byte-identical to the bridge's messageStartInputTokens
       // computation. Any divergence (e.g., inline minimal conversion) causes silent drift
       // where CLI sees different counts from actual upstream usage.
       let requestIR: [IRMessage] = request.messages.map { msg in
           IRMessage(
               role: msg.role,
               content: IRAnthropicCodec.decodeRequestBlocks(msg.content)
           )
       }
       let instructions = joinedSystemText(request.system)   // reuse existing private helper at AnthropicBridge.swift:~840
       let convertedTools = convertTools(request.tools)      // reuse existing helper (prepareTurn path)
       return JSONObject.from([
           "instructions": .string(instructions),
           "input": .array(IRResponsesCodec.encodeFullHistory(requestIR)),
           "tools": .array(convertedTools.map(JSONValue.object)),
       ])
       // counter.collectCountableStrings only reads instructions / input / tools —
       // model/route/effort/verbosity fields are intentionally omitted.
   }
   ```
   若 `joinedSystemText` / `convertTools` / `IRAnthropicCodec.decodeRequestBlocks` 任一不是 accessible（actor-private 跨文件 / filePrivate），在同文件内新增 wrapper 或调整现有函数为 `fileprivate` → `internal`。**禁止**用 inline minimal conversion 绕开 IR 路径。
2. `GatewayDaemon.route` 的 `("POST", configuration.countTokensPath)` case：
   - 现有授权检查保留
   - 授权通过 → `return await bridge.handleCountTokens(request)`
   - 移除 `let heuristic = max(1, request.body.count / 4)` 与 `CountTokensResponse` 局部定义
3. `countTokensStrategy` 字段值从 `"body-size-heuristic"` 改为 `"cl100k-bpe"` — 共 3 处：`Sources/CCRouterCore/GatewayDaemon.swift:52` + `:96` + `Tests/CCRouterCoreTests/DoctorSnapshotTests.swift:11`。执行前运行 `grep -rn "body-size-heuristic" Sources/ Tests/` 确认 3 处全覆盖；执行后同样命令应返回 0 行。
4. 公开 `CountTokensResponse`（从 `private` 提到 `internal` 或 `public`），让 `AnthropicBridge.handleCountTokens` 可以复用；或在 AnthropicBridge 里重新定义（选择后者避免跨文件 public 扩散）。
5. 新测试 `CountTokensEndpointTests`：
   - `singleTextMessageReturnsPositiveCount`：payload `{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":[{"type":"text","text":"hello world"}]}]}`，assert response.input_tokens > 0。
   - `largerPayloadReturnsLargerCount`：两个 payload，第二个多一条 200-char message，assert count2 > count1。
   - `invalidJSONReturns400`：payload `"not json"`，assert response.statusCode == 400，error.type == "invalid_request_error"。
   - `toolSchemaIncreasesCount`：base payload vs base + tools[{"name":"Bash","description":"...","parameters":{...}}]，assert withTools > withoutTools。
   - `endpointCountMatchesInputTokenCounterDirectly`：构造 anthropic payload；端点返回值与 `AnthropicInputTokenCounter().countInputTokens(for:)` 直接调用（传构造的 responses-shape payload）返回的值**完全相等**（校验两条路径合一）。
   - `toolCallHistoryIsCounted`：fixture 含历史 `tool_use` + `tool_result` 块（assistant role 的 tool_use block + user role 的 tool_result block）；assert count 显著 > 仅含首条 user text 的 baseline（防止 Phase 1/3 IR codec 漏字段导致历史 tokens 被漏算）。
   - `endpointMatchesBridgePrepareTurnInitialPayload`：**锁定端点路径与 bridge 真实路径字节级一致**（DP-001 Chosen: C）。构造同一 `AnthropicMessagesRequest` fixture；一路通过 `bridge.handleCountTokens` 拿到 `input_tokens`；另一路通过 expose `AnthropicBridge.prepareTurn`（或 test-only hook method 读 `PreparedTurn.messageStartInputTokens`）拿到真实 bridge 路径的 token count；assert 两者**完全相等**。若 `prepareTurn` 是 private，在 AnthropicBridge 加 internal test-only method `__prepareInitialPayloadForTesting(_:) -> JSONObject`，测试单独调用 counter 比较；**无论如何不允许测试绕开 IR codec**。

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -10`
Expected: Build success。
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter CountTokensEndpointTests 2>&1 | tail -10`
Expected: 5/5 tests pass。
Run: `grep -rn "cl100k-bpe\|body-size-heuristic" Sources/ Tests/`
Expected: 3 行 cl100k-bpe（Sources:52, Sources:96, Tests/DoctorSnapshotTests.swift:11）；0 行 body-size-heuristic。
<!-- /section -->

---

<!-- section: task-7 keywords: doctor-snapshot, token-status-field, subscription-metadata -->
### Task 7: `DoctorSnapshot` 暴露 token refresh 状态

**Files:**
- Modify: `Sources/CCRouterCore/DoctorSnapshot.swift` (新增两个字段)
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift` (`doctorStatus` 方法返回新字段)
- Modify: `Sources/CCRouterCore/GatewayDaemon.swift:43-70,87-113` (`snapshot()` + health route 填充新字段)
- Test: `Tests/CCRouterCoreTests/DoctorSnapshotTests.swift` (新测试 `doctorSnapshotIncludesLastRefreshAndRefreshTokenPresence`)

**Steps:**
1. `DoctorSnapshot` 新增：
   ```swift
   public let lastRefresh: Date?            // 从 auth.json 顶层 last_refresh 解析
   public let hasRefreshToken: Bool         // tokens.refresh_token != nil
   ```
   Init 同步扩展，更新所有 call site（`GatewayDaemon.swift` 2 处 + test fixtures）。
2. `AnthropicBridge.doctorStatus` 返回扩展：
   ```swift
   struct DoctorStatus {
       // ... existing fields
       let lastRefresh: Date?
       let hasRefreshToken: Bool
   }
   ```
   实现：读 `sessionLoader.loadCurrent()`；从返回的 `SubscriptionCredentials` 取 `lastRefresh` + `refreshToken != nil`。
3. 测试 `doctorSnapshotIncludesLastRefreshAndRefreshTokenPresence`:
   - Fixture auth.json 含 refresh_token + last_refresh
   - 构造 GatewayDaemon + mock session loader
   - 调 `snapshot()`
   - Assert snapshot.lastRefresh != nil，snapshot.hasRefreshToken == true
4. 扩展测试 `snapshotHandlesLegacyAuthFileWithoutRefreshToken`:
   - Fixture 只有 access_token
   - Assert snapshot.lastRefresh == nil，snapshot.hasRefreshToken == false

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter DoctorSnapshotTests 2>&1 | tail -10`
Expected: 原有测试全绿 + 新增 2 测试全绿。
<!-- /section -->

---

<!-- section: task-8 keywords: trace-logging, refresh-events, diagnostics -->
### Task 8: Trace log 事件 for refresh + count_tokens

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift` (refresh 成功/失败两处 TraceLogger 调用；count_tokens 入口 1 处)
- Modify: `Sources/CCRouterCore/GatewayDaemon.swift:116-132` (count_tokens trace stage)
- Test: `Tests/CCRouterCoreTests/SubscriptionSessionTests.swift` 或新 `TraceLoggerRefreshEventsTests.swift`

**Steps:**
1. 在 Task 5 的 refresh 路径中已加入：
   - `stage: "subscription_refresh_success"`，字段：`session_id`、`access_token_suffix`（仅末 4 位 — 不泄漏完整 token）、`last_refresh`
   - `stage: "subscription_refresh_failure"`，字段：`session_id`、`error_type`、`error_message` (截断 200 chars)
2. 在 Task 6 的 count_tokens 路径中新增：
   - `stage: "count_tokens_in"`，字段：`path`、`body_size`
   - `stage: "count_tokens_out"`，字段：`input_tokens`、`duration_ms`
3. 测试 `refreshSuccessEmitsTraceEvent`:
   - Drive Task 5 的 retry-once 路径
   - 读 `TraceLogger.shared.recentLines(limit: 20)` 断言含 `stage=subscription_refresh_success`
   - 断言 trace 不含完整 access token（grep + assert not contains）
4. 测试 `countTokensEndpointEmitsTraceEvents`:
   - 发 count_tokens 请求
   - 断言 trace 连续两行：先 `count_tokens_in`、后 `count_tokens_out`
   - 断言 `count_tokens_out.input_tokens` 与响应 body 的 `input_tokens` 相等

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest 2>&1 | grep -E "Test Suite|Test Case" | tail -20`
Expected: 所有新测试绿。
Run: `grep -n "subscription_refresh_success\|subscription_refresh_failure\|count_tokens_in\|count_tokens_out" Sources/CCRouterCore/*.swift`
Expected: ≥ 4 行命中（各 stage 至少 1 处 emit）。
<!-- /section -->

---

## Decisions

### [DP-P5-001] BPE 失败时的 count_tokens 退化策略 (recommended)

**Context:** `CL100KEncoder.encode` 理论上不抛（byte-level BPE 保证任意字节可编码），但 `missingTokenizerResource` 或打包 bug 会使 `countInputTokens` 抛异常。端点返回 500 vs 静默降级到 `body.count/4` 的选择影响用户可观测性。

**Options:**
- A: 返回 500 + 明确错误信息（"tokenizer resource missing"）；不降级
- B: Catch 异常 → fall back 到 `max(1, body.count / 4)` + 在 trace 里记 warning
- C: Catch 异常 → 返回 `input_tokens: -1` + 错误字符串（Anthropic 客户端对 -1 未定义）

**Chosen:** A — auto mode 下按 Recommendation 记录；`CL100KEncoder.bundledResourceData()` 在 `Sources/CCRouterCore/AnthropicInputTokenCounter.swift:124-128` 的 `Bundle.module.url` 失败只在打包错误下发生；这是部署问题不是 runtime 问题，静默降级会让打包 bug 长期不可见。500 + 明确 message 是最快暴露回归的方式。`AnthropicInputTokenCounterTests` 已有 `identicalPayloadsCountTheSame` 等保护，生产环境遇到 encode 异常属严重 bug，应显式 fail fast。

### [DP-P5-002] Refresh retry 的 trace 粒度 (recommended)

**Context:** 每次 refresh 至少触发 1 条 trace 事件；是否需要同时记录 refresh 前的 access token 前后 8 字符（用于 debug "token 真的换了吗"）涉及安全 vs 可调试性 trade-off。

**Options:**
- A: 只记 `access_token_suffix: "...abcd"`（末 4 位），不记 prefix
- B: 记 `access_token_prefix: "ey..."` + `access_token_suffix: "...abcd"` + 长度
- C: 不记任何 token 片段，只记 `refresh_token_rotated: true/false` + `new_token_length`

**Chosen:** A — auto mode 下按 Recommendation 记录；OAuth access token 末 4 位在截图/log 共享场景下最难被还原；`Dashboard` 现有其他 trace 的习惯（`AnthropicBridge.doctorStatus` 已显示 `accountIDSuffix`）也是末 suffix 形式。B 的 prefix 在 JWT access token 场景下几乎恒定（`eyJ...`），debug 价值低；C 的 `refresh_token_rotated` 需要 Task 3 返回的 old vs new 对比，额外状态。

### [DP-P5-003] 原子写 auth.json 的文件权限保留 (recommended)

**Context:** `~/.codex/auth.json` 通常是 `0600`（只有 owner 可读写）。`Data.write(to:options:[.atomic])` 在创建临时文件时可能产生 `0644`，rename 后破坏原权限。

**Options:**
- A: Write 完 `chmod 0600`（`FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath:)`）
- B: 先读原文件 permission，写完恢复
- C: 使用 `FileManager.default.replaceItemAt` 自动保留原文件属性

**Chosen:** C — auto mode 下按 Recommendation 记录；`replaceItemAt` 的 semantics 本身保留 destination 文件的属性（Apple File System docs 明确）；比 A 少一次 syscall，比 B 少 race condition。实现上 `replaceItemAt` 需要一个临时文件 URL，可用 `FileManager.default.url(for: .itemReplacementDirectory, ...)` 获取。失败时 `replaceItemAt` 保证原文件不被修改 — 与 threat model §3 的 cleanup 要求一致。

### [DP-P5-004] count_tokens 实现路径（blocking）— *added cycle 2 revision*

**Context:** `buildCountablePayload` 可选择复用 IR codec 或 inline minimal conversion。Inline 路径必然与 bridge `prepareTurn.initialPayload` 产生编码漂移（tools / instructions / 历史 tool_use block），导致端点 count ≠ bridge `messageStartInputTokens`。`IRAnthropicCodec` + `IRResponsesCodec.encodeFullHistory` 均为 `public enum/static`，无可见性障碍。

**Options:**
- A: Hard-require 复用 IR codec 路径
- B: Inline minimal conversion — 简单但漂移风险
- C: A + 新增 `endpointMatchesBridgePrepareTurnInitialPayload` 测试锁定字节级一致

**Chosen:** C — auto mode 下按 Recommendation 记录；IR codec 复用无可见性障碍，额外测试可防止 Phase 5 后 IR 内部改动导致静默漂移。Task 6 Step 1 已 hard-require IR 路径，Task 6 Step 5 已加入 parity 测试。

### [DP-P5-005] refresh_token rotating 假设验证（blocking）— *added cycle 2 revision*

**Context:** `SubscriptionSessionLoader` actor 串行化 refresh，但若 OAuth refresh_token 是 rotating（one-time-use），并发两个 401 请求第二个会用已失效的 old token 调 refresh endpoint → invalid_grant。

**Options:**
- A: Task 1 probe 确认 rotating 状态；若非 rotating，plan 显式声明"actor 串行化足够，并发双 refresh 幂等"
- B: 无论 probe 结果都加 5s cache-hit short-circuit（保守）
- C: 分布式锁（over-engineering）

**Chosen:** A with fallback to conservative — auto mode 下按 Recommendation 记录；Task 1 probe 新增 rotating 字段确认；若 probe 返回 `rotating: false` 则 Task 4 Step 3 注释掉 cache-hit block；若返回 `true` 或 `unknown` 则保留（Task 1 默认保守回退到 `unknown`）。最小化改动同时保证安全默认。

### [DP-P5-006] MockSessionLoader 类型选择（recommended）— *added cycle 2 revision*

**Context:** Task 5 Step 4 需要 mutable state 追踪（refreshedCredentials / refreshError / call-count），但现有是 `let`-only struct；struct 不能 extension 加 stored property，20+ 现有 call sites 不希望改。

**Options:**
- A: `final class MockSessionLoader, @unchecked Sendable` + NSLock — 现有 call sites 零改动
- B: `actor MockSessionLoader` — 20+ call sites 读 `.credentials` 需 await
- C: Struct + external atomic tracker — 范型混合

**Chosen:** A — auto mode 下按 Recommendation 记录；A 是最小侵入方案，NSLock 开销对测试场景可忽略；避免 await 扩散到 20+ 测试文件。Task 5 Step 4 已按 A 实现。

---

## Recommended Additions (not in scope)

- **Token 过期时间从 `id_token` JWT claim 解析：** `id_token` 是 JWT，payload 的 `exp` 可以告诉我们 access_token 还剩多久，避免到期才 401。但 Phase 5 以 "401 被动 refresh" 为最小可用方案；主动 refresh 属 Phase 6 Dashboard 的 "Token status" 卡片范畴。
- **Refresh 的 backoff：** 当前 refresh 失败直接让本次请求 503；若 refresh endpoint 自己也不稳定，连续 5 次都被 refresh 失败会浪费网络。Phase 5 暂不加 backoff（refresh 失败多半是 refresh_token 真的无效了，不该 retry）。

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-04-23
- **Cycle:** 3 (cycle 1 + 2 revisions applied; see `.claude/reviews/plan-verifier-2026-04-23-175953.md`)
- **Advisories (non-blocking):**
  1. Task 5 Step 4 `MockSessionLoader` init — add default value for `credentials` param if any existing call site uses zero-arg constructor; surface at build time.
  2. Task 6 Step 1 code sketch precision — `joinedSystemText(from: request.system ?? [])`, `try convertTools(request.tools ?? [])`; executor resolves at implementation time.
  3. Task 6 Verify test count — plan lists 7 tests (update Expected from "5/5" to "7/7" when test file is finalized).
