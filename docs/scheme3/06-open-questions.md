# 方案三剩余观察项

Date: 2026-04-21

## 1. 文档定位

本文件不再登记 blocking 未决项。

当前作用只有两个：

- 记录哪些验证已经清空，可以进入正式实现
- 记录哪些事项仍然只是后续观察点，而不是实现前 blocker

## 2. 当前状态

当前 blocking 未决项已经清空。

已经收敛并移入正式文档的范围包括：

- Claude `count_tokens` 当前已测 8 条路径都未触发
- Claude function tool 与 advisor bridge 的当前协议边界
- `/responses` HTTP-only 在当前已测文本、工具、interactive apps、部分 app 动作路径里的可行性
- GitHub、Gmail、Notion 三个 app 家族对 `/backend-api/...` sidecar 的当前 hard dependency
- 当前第一版错误兼容矩阵

正式结论以这些文档为准：

- [01-validated-baseline.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/01-validated-baseline.md)
- [10-tool-mapping-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/10-tool-mapping-v1.md)
- [11-advisor-bridge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/11-advisor-bridge.md)
- [12-error-compatibility-matrix-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/12-error-compatibility-matrix-v1.md)
- [14-count-tokens-observation-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/14-count-tokens-observation-v1.md)
- [18-apps-tool-action-dependency-v1.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/18-apps-tool-action-dependency-v1.md)

## 3. 当前剩余观察点

以下事项当前不能当成实现前 blocker，但仍值得在后续版本里持续观察：

### O-01 版本漂移

- 新版 `claude` 或新版 `codex-cli` 可能改变：
  - `/v1/messages/count_tokens` 的触发时机
  - `/responses` 请求体字段
  - sidecar 路径集合
  - 错误外观

### O-02 新 app 家族

- 当前 hard dependency 只覆盖到：
  - GitHub
  - Gmail
  - Notion
- 新接入的 app 家族仍需要单独留样，不允许直接外推

### O-03 新的 Anthropic server-side tool

- 当前只正式收敛了 `advisor`
- 未来如果 Claude 再引入新的 server-side tool，仍要先抓真实样本再决定桥接方式

### O-04 更深业务语义

- 当前已经坐实的是协议边界和代表性业务动作
- 更深参数语义、复杂结果格式、长会话状态收敛仍属于实现后的增强验证

## 4. 当前不允许写成结论的话

- “HTTP `/responses` 已经足够”
- “所有路径都不需要 websocket”
- “上游请求 JSON 已经完全知道”
- “Claude tools 可以直接映射成某个固定结构”
- “raw `advisor_20260301` 可以直接透传到 `/responses`”
- “辅助产品面可以忽略”
