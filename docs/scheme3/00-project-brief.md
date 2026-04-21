# 方案三 Project Brief

Date: 2026-04-20

## 1. 项目名称

`cc-router`

## 2. 项目目标

当前项目目标直接来自用户约束：

- 用户继续使用 `Claude Code CLI`
- 流量经过本地 macOS 软件转发
- 认证与计费落到 `OpenAI subscription`

## 3. 当前问题定义

当前已验证的技术缺口是：

- Claude Code 需要 Anthropic Messages 兼容网关
- 当前证据没有显示存在一个“面向第三方、公开文档化、可直接拿 ChatGPT/Codex 订阅来调用”的通用模型 API
- Codex 当前真实主推理面已观测到 `/responses`

因此，项目不是在“发明新需求”，而是在填补一个已经被验证存在的协议与产品边界缺口。

支撑证据：

- [研究总稿第 3 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:30)

## 4. 范围边界

### 4.1 In Scope

- 本地 Anthropic-compatible gateway
- Claude Code 到本地网关的兼容层
- 本地网关到上游 `/responses` 的主推理适配
- 本地网关到 `/backend-api/...` 的辅助适配
- 方案三所需的协议验证、证据沉淀和错误翻译

### 4.2 Out of Scope

- API key 计费路线
- `LiteLLM` 之类的 API-billed proxy
- 以 `codex app-server` 为主推理通路
- 以 `codex mcp-server` 为主模型通路
- 把 `/wham/tasks` 作为方案三主推理路径

## 5. 当前技术判定

### 5.1 是否需要开发

在当前约束下，答案是：

- 需要

理由只基于已验证事实：

- Claude Code 入口需要 Anthropic Messages 兼容面
- 当前没有找到公开文档化的“ChatGPT/Codex 订阅 -> 第三方直接模型 API”方案
- 现有官方公开面不能直接把这两个硬约束拼起来

支撑证据：

- [研究总稿第 3 节与第 5 节](/Users/norvyn/Code/Projects/ModelBridge/docs/research/2026-04-20-claude-code-openai-subscription-router.md:30)

### 5.2 当前架构目标

当前架构目标是：

- `Claude Code CLI -> local Anthropic-compatible gateway -> upstream /responses`

辅助面：

- `local gateway -> /backend-api/...`

支撑证据：

- [已验证基线](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md)

## 6. 当前非目标

当前不承诺以下结果：

- 上游 `/responses` 协议细节已全部确认
- 所有路径上的 websocket 需求范围已经确认
- 所有路径上的 zstd 请求体字段已经全部确认
- tool-use 映射已设计完成

当前 blocking 验证已经完成。

后续只保留非阻塞观察点：

- [05-validation-matrix.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/05-validation-matrix.md)
- [06-open-questions.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/06-open-questions.md)

## 7. 文档落盘顺序

当前目录按以下顺序维护：

1. `00-project-brief.md`
2. `01-validated-baseline.md`
3. `02-target-architecture.md`
4. 协议边界文档
5. 验证矩阵
6. 未决问题
7. 治理规则

原因：

- 先固定目标和范围
- 再固定已经证实的事实
- 再在事实之上写设计

## 8. 进入实现前的门槛

进入正式实现前的最低门槛当前已满足：

- 已拿到被 `codex exec` 接受的本地 `/responses` 成功会话
- 已确认当前已测路径里 websocket `404` 后 HTTP 仍可完成回复
- 已解开并比较 `/responses` 请求体样本
- 已形成 Claude tools 到上游工具语义的第一版字段映射
- 已验证 advisor bridge
- 已验证 GitHub、Gmail、Notion 的 sidecar 依赖边界
