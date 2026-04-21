# 方案三实现蓝图

Date: 2026-04-21

## 1. 文档定位

本文件把方案三从“已验证可行”推进到“可以正式编码”。

这里不再讨论是否选择方案三；只固定正式实现的骨架。

所有设计都必须受这些已验证边界约束：

- Claude 入口是 Anthropic Messages
- 主推理面是 `chatgpt.com/backend-api/codex/responses`
- 辅助产品面是 `/backend-api/...`
- `advisor` 不能 raw passthrough，只能 bridge
- GitHub、Gmail、Notion 三个 app 家族当前都证明 sidecar 不是可选件

## 2. 最终产品形态

正式产品由两层组成：

1. 本地 gateway daemon
2. macOS 菜单栏壳

对外用户体验固定为：

- 用户继续运行 `Claude Code CLI`
- `Claude Code CLI` 指向本地 `ANTHROPIC_BASE_URL`
- 本地 app 负责登录态读取、网关转发、诊断与日志

## 3. 组件图

### 3.1 Menu Bar App

职责：

- 启停本地 daemon
- 展示当前 ChatGPT 登录态
- 展示当前本地监听地址
- 生成 Claude Code 环境变量
- 提供 doctor 与日志入口

非职责：

- 不直接承载协议翻译
- 不直接处理 Claude 请求

### 3.2 Gateway Daemon

职责：

- 暴露：
  - `POST /v1/messages`
  - `POST /v1/messages/count_tokens`
- 维护 Claude 会话与上游 turn 映射
- 承担 Anthropic -> `/responses` 的协议转换
- 承担 `/backend-api/...` 的 sidecar 代理
- 输出结构化日志和 doctor 数据

### 3.3 Subscription Session Layer

职责：

- 读取并缓存：
  - `Authorization: Bearer ...`
  - `chatgpt-account-id`
- 维护当前 ChatGPT 登录态的有效性
- 为 `/responses` 与 `/backend-api/...` 统一注入认证头

### 3.4 Responses Adapter

职责：

- 把 Claude `messages/system/tools/thinking/context_management` 转成 `/responses` 请求
- 处理 zstd 编码与 SSE 解析
- 把上游 `/responses` 流还原成 Anthropic SSE

### 3.5 Tool Mapping Layer

职责：

- function tools：
  - `input_schema -> parameters`
  - `type:"function"`
  - `strict:false`
- function 回合：
  - `function_call`
  - `function_call_output`
- `advisor`：
  - 走 synthetic bridge，不走 raw passthrough

### 3.6 Backend Sidecar Client

职责：

- 代理当前已观测到的 `/backend-api/...` 请求
- 保障 GitHub、Gmail、Notion 当前业务动作不因 sidecar 缺失而失败
- 记录 sidecar 故障并与主推理日志关联

## 4. 主流程

### 4.1 文本回合

1. Claude 发 `POST /v1/messages`
2. gateway 解析 Anthropic 请求
3. gateway 生成 `/responses` 请求并发送到真实远端
4. gateway 把上游 SSE 翻成 Anthropic SSE
5. Claude 正常完成本轮

### 4.2 function tool 回合

1. Claude 发带 `tools` 的 `POST /v1/messages`
2. gateway 把函数工具定义改写为 `/responses` function tools
3. 上游返回 `function_call`
4. gateway 把工具调用还原成 Anthropic `tool_use`
5. Claude 回发 `tool_result`
6. gateway 再发第二段 `/responses`：
   - `reasoning`
   - `function_call`
   - `function_call_output`
7. gateway 把第二段结果还原为 Anthropic assistant 输出

### 4.3 advisor 回合

1. Claude 请求里保留 `advisor_20260301`
2. gateway 不透传 raw advisor
3. gateway 在 `/responses` 注入 synthetic `function name="advisor"`
4. 上游返回 `function_call(name="advisor")`
5. gateway 发起 advisor 子调用拿建议文本
6. gateway 把建议文本作为 `function_call_output` 送回主请求
7. gateway 对 Claude 侧输出：
   - `server_tool_use`
   - `advisor_tool_result`

### 4.4 apps 业务动作

1. 主推理仍走 `/responses`
2. 当前本地 Swift runtime 先以 Anthropic `/v1/messages -> /responses` 桥接承接 Claude CLI 的默认工具清单
3. 若未来某类 Claude 路径证明还需要本地产品面转发，再补 `backend-sidecar`
4. 研究期 sidecar 结论继续保留，但不再直接等同于“当前本地 runtime 必须先写本地 `/backend-api/...` 模块”

## 5. 正式模块边界

正式代码按这 8 个模块设计；当前本地 runtime 已正式落地前 7 项中的核心主链路，`backend-sidecar` 保留为扩展位：

1. `anthropic-edge`
2. `count-tokens`
3. `subscription-session`
4. `local-config-and-auth`
5. `responses-adapter`
6. `tool-mapper`
7. `advisor-bridge`
8. `backend-sidecar`
9. `doctor-and-observability`

模块细节见：

- [21-gateway-modules.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/21-gateway-modules.md)

## 6. 非目标

- 不把 `app-server` 混进正式主链路
- 不接 public `api.openai.com/v1/responses`
- 不把 sidecar 当成可选优化
- 不把“当前 HTTP-only 已测可行”外推成“永远不需要 websocket”

## 7. 进入编码的 gate

当前已经满足进入正式实现的最低门槛：

- 文本路径协议已验证
- 工具映射已验证到实例级
- advisor bridge 已验证
- sidecar 依赖已验证到三个 app 家族
- 错误兼容矩阵已有第一版

后续执行顺序与验收标准见：

- [22-execution-and-acceptance.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/22-execution-and-acceptance.md)

## 8. 当前实现落点

截至 `2026-04-21`，正式代码已经落到这些文件：

- `Package.swift`
- `Sources/CZstd/module.modulemap`
- `Sources/CCRouterCore/JSONValue.swift`
- `Sources/CCRouterCore/SubscriptionSession.swift`
- `Sources/CCRouterCore/ZstdCodec.swift`
- `Sources/CCRouterCore/ResponsesClient.swift`
- `Sources/CCRouterCore/AnthropicProtocol.swift`
- `Sources/CCRouterCore/AnthropicBridge.swift`
- `Sources/CCRouterCore/GatewayDaemon.swift`
- `Sources/CCRouterCore/LocalHTTPServer.swift`
- `Sources/CCRouterCore/RouterConfiguration.swift`
- `Sources/CCRouterCore/RouterConfigurationStore.swift`
- `Sources/CCRouterCore/LocalGatewayAuthorization.swift`
- `Sources/CCRouterCore/DoctorSnapshot.swift`
- `Sources/CCRouterApp/CCRouterApp.swift`
- `Sources/CCRouterDaemon/main.swift`
- `Tests/CCRouterCoreTests/RouterConfigurationStoreTests.swift`
- `Tests/CCRouterCoreTests/LocalGatewayAuthorizationTests.swift`

当前代码已经具备：

- ChatGPT 登录态读取
- 持久化本地 gateway 配置
- `x-api-key` ingress 校验
- zstd 压缩
- Anthropic 请求解析
- `/responses` 文本桥接
- function tool 两段回合桥接
- advisor synthetic bridge
- 本地 doctor 与 trace 日志
- Swift Testing 对配置与 ingress auth 的覆盖
- 当前默认完整工具清单文本路径与代表性 Notion auth 路径的真实运行证据

当前还没有正式编码的仍是：

- 更完整的 macOS doctor 页面与日志查看 UI
- 如果未来某类 Claude CLI 路径需要它，再补本地 `/backend-api/...` sidecar 代理
