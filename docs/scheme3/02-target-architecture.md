# 方案三目标架构

Date: 2026-04-20

## 1. 文档定位

本文件记录方案三的目标架构。

这里的“目标”是设计决策，不等同于“所有协议细节已验证”。

每个设计决策都必须由 [已验证基线](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md) 支撑。

## 2. 设计目标

方案三要解决的问题只有一个：

- 把 Claude Code 的 Anthropic Messages 入口，稳定地转成 OpenAI 订阅态下的真实远端 `https://chatgpt.com/backend-api/codex/responses`

## 3. 组件边界

### 3.1 Claude Code CLI

职责：

- 继续充当唯一前端与交互入口
- 继续发送 Anthropic Messages 请求
- 不感知上游是 OpenAI 订阅态

### 3.2 Local Gateway

职责：

- 提供 Claude Code 需要的本地 HTTP 面：
  - `POST /v1/messages`
  - `POST /v1/messages/count_tokens`
- 维护 Claude 会话和上游请求之间的映射
- 处理 Anthropic 流式响应到上游流式响应之间的转换
- 管理本地日志、重试、诊断和版本追踪

非职责：

- 不重新实现一个 agent runtime
- 不接入 `codex app-server` 做主推理

### 3.3 Upstream Responses Surface

职责：

- 承担主推理流量
- 接收本地网关转出的模型请求

已验证边界：

- 本地 override 入口路径在 `openai_base_url` 下
- 本地 override 入口已观测路径为 `/responses`
- 默认真实远端已验证为 `https://chatgpt.com/backend-api/codex/responses`

### 3.4 Backend Sidecar Surface

职责：

- 承担与产品态、额度、插件、目录相关的辅助查询

已验证边界：

- 路径在 `chatgpt_base_url` 下
- 已观测路径位于 `/backend-api/...`

## 4. 主数据流

目标主流：

1. Claude Code 向本地网关发送 `POST /v1/messages`
2. 本地网关读取 Anthropic 风格请求体和头
3. 本地网关转换为本地 `/responses` 形状对应的请求
4. 本地网关把请求发送到真实远端 `https://chatgpt.com/backend-api/codex/responses`
5. 真实远端返回流式或非流式结果
6. 本地网关把结果还原成 Claude Code 能接受的 Anthropic 响应

## 5. 辅助数据流

辅助流只做这些事情：

- 订阅态账户信息读取
- 配额和速率信息读取
- 插件与目录信息读取
- 诊断和观测补充

辅助流不承担：

- 主推理
- Claude turn 的直接执行

## 6. 关键架构决策

### 6.1 不走 `app-server`

原因：

- `app-server` 是 agent/control 协议
- 方案三的目标是把网关放在正确的模型边界上

支撑证据：

- [已验证基线 3.3 与 3.5](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md:39)

### 6.2 不把 `/wham/tasks` 当作主协议

原因：

- 当前运行态探针没有显示 `codex exec` 用 `/wham/tasks` 做主推理
- 当前直接命中的主面是 `/responses`

支撑证据：

- [已验证基线 3.3](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md:39)

### 6.3 主推理与产品态拆面

原因：

- 当前证据显示主推理走 `/responses`
- 当前证据同时显示插件、目录、分析类请求走 `/backend-api/...`

支撑证据：

- [已验证基线 3.3 与 3.4](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md:39)

### 6.4 不走 public `api.openai.com/v1/responses`

原因：

- 当前机器上的订阅登录态转发到 public Responses API 会被 scope 拒绝
- 真实可用远端已经验证为 ChatGPT backend codex responses

支撑证据：

- [已验证基线 3.9 与 3.10](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md)

## 7. 当前不写进架构图的内容

以下内容仍然不能写成“完全确认”的协议定论：

- websocket 在未来版本和未测入口里的必要性
- 新 app 家族的 sidecar 路径集合
- 新增 Anthropic server-side tool 的桥接方式

正式实现蓝图见：

- [20-implementation-blueprint.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/20-implementation-blueprint.md)
- [21-gateway-modules.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/21-gateway-modules.md)
- [22-execution-and-acceptance.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/22-execution-and-acceptance.md)
