# 方案三网关模块

Date: 2026-04-21

## 1. 文档定位

本文件把 gateway daemon 拆成可编码模块。

规则：

- 每个模块只承担一个清晰职责
- 模块边界必须贴合已验证协议边界
- 不允许为了“先跑起来”把 sidecar、advisor、tool 映射混成一个大处理器

## 2. 模块列表

### 2.1 `anthropic-edge`

输入：

- `POST /v1/messages`

职责：

- 校验 Anthropic 头与请求体
- 解析 Claude `model/messages/system/tools/thinking/context_management`
- 建立 Claude turn 上下文
- 输出 Anthropic SSE

输出：

- 文本 assistant
- `tool_use` / `tool_result`
- `server_tool_use` / `advisor_tool_result`

### 2.2 `count-tokens`

输入：

- `POST /v1/messages/count_tokens`

职责：

- 返回 Anthropic 兼容形状：
  - `{"input_tokens": ...}`
- 不把当前“已测未触发”误写成“可以不实现”

实现要求：

- 但返回形状必须兼容 Claude Code 入口

### 2.3 `subscription-session`

职责：

- 读取本机 ChatGPT 登录态
- 维护 Bearer 与 `chatgpt-account-id`
- 对主推理面和 sidecar 面统一注入认证
- 暴露登录态给 menu bar app 与 doctor

失败语义：

- 登录态缺失时要形成明确 doctor 故障，不做隐式降级

### 2.4 `responses-adapter`

职责：

- 生成 `/responses` 请求
- 处理 HTTP SSE
- 预留 websocket 能力位，但第一版不把 websocket 写成前置 gate
- 把 `/responses` 结果翻回 Anthropic SSE

必须覆盖：

- 单轮文本
- function 两段回合
- resumed 历史输入扩展

### 2.5 `tool-mapper`

职责：

- Claude function tools -> `/responses` function tools
- Claude `tool_use` / `tool_result` <-> `function_call` / `function_call_output`

当前已验证规则：

- `input_schema -> parameters`
- `type:"function"`
- `strict:false`
- 第二段最小集：
  - `reasoning + function_call + function_call_output`

### 2.6 `advisor-bridge`

职责：

- 在 Anthropic 侧保留 `advisor` server-side 语义
- 在 `/responses` 侧改成 synthetic `function name="advisor"`
- 管理 advisor 子调用与结果注入

禁止事项：

- 不允许 raw passthrough `advisor_20260301`
- 不允许把 advisor 降成普通 Anthropic `tool_result`

### 2.7 `backend-sidecar`

职责：

- 代理 `/backend-api/...`
- 当前至少覆盖已观测到的：
  - `plugins/list`
  - `plugins/featured`
  - `connectors/directory/list`
  - `wham/apps`
  - `codex/analytics-events/events`

要求：

- 不把 sidecar 与 `/responses` 绑成一个 HTTP client
- 要能独立记录 sidecar 故障

### 2.8 `doctor-and-observability`

职责：

- 提供本地 doctor 检查
- 记录结构化日志
- 对失败分类：
  - Claude ingress
  - `/responses`
  - sidecar
  - auth
  - tool mapping
  - advisor bridge

## 3. 共享状态

允许共享的只有：

- session/auth state
- Claude turn 到 upstream request 的映射
- 结构化日志 correlation id

不允许共享的有：

- 把全部协议分支塞进全局 mutable singleton
- 把 sidecar 错误状态隐式影响主推理状态

## 4. 模块调用顺序

### 4.1 文本路径

`anthropic-edge -> subscription-session -> responses-adapter -> anthropic-edge`

### 4.2 function 路径

`anthropic-edge -> tool-mapper -> subscription-session -> responses-adapter -> anthropic-edge`

### 4.3 advisor 路径

`anthropic-edge -> advisor-bridge -> subscription-session -> responses-adapter -> advisor-bridge -> anthropic-edge`

### 4.4 apps 路径

`anthropic-edge -> tool-mapper -> subscription-session -> responses-adapter + backend-sidecar -> anthropic-edge`

## 5. 第一版不拆的内容

第一版允许合在同一代码包里的只有：

- `responses-adapter` 与 SSE parser
- `doctor-and-observability` 与本地状态汇总

第一版不允许合并的有：

- `advisor-bridge` 与一般 function tool mapper
- `backend-sidecar` 与 `/responses` 主适配器
- `subscription-session` 与 UI 层
