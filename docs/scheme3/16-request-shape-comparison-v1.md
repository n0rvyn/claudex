# `/responses` 请求体四样本对照 v1

Date: 2026-04-21

## 1. 文档定位

本文件只记录当前四份已解压 `/responses` 首轮请求样本的对照结果。

这里只写已经被二次验证的字段，不把更深回合、续轮或工具回合写成已知。

## 2. 适用范围

当前结论只覆盖：

- `codex-cli 0.121.0`
- 当前四份已解压首轮请求样本：
  - `/tmp/responses-forward-8797/008-request.json`
  - `/tmp/responses-forward-8797/016-request.json`
  - `/tmp/codex-apps-http-only-8806/008-request.json`
  - `/tmp/codex-interactive-errors-8821/008-request.json`

当前结论不覆盖：

- 续轮请求
- 工具回合的第 2 段请求
- 更深 apps 回合
- 未来 CLI 版本

## 3. 当前四样本共享骨架

当前四份样本的顶层字段完全一致：

- `client_metadata`
- `include`
- `input`
- `instructions`
- `model`
- `parallel_tool_calls`
- `prompt_cache_key`
- `reasoning`
- `service_tier`
- `store`
- `stream`
- `text`
- `tool_choice`
- `tools`

当前四份样本的共享值一致：

- `model = "gpt-5.4"`
- `stream = true`
- `store = false`
- `tool_choice = "auto"`
- `parallel_tool_calls = true`
- `include = ["reasoning.encrypted_content"]`
- `service_tier = "priority"`
- `prompt_cache_key` 都是字符串
- `text` 字段都存在
- `client_metadata` 字段都存在
- `input_len = 3`

## 4. 当前已验证差异

### 4.1 非交互两份样本

样本：

- `/tmp/responses-forward-8797/008-request.json`
- `/tmp/responses-forward-8797/016-request.json`

当前已验证：

- `tools_len = 16`
- 工具类型分布：
  - `function = 13`
  - `custom = 1`
  - `web_search = 1`
  - `namespace = 1`
- 当前唯一 `namespace`：
  - `mcp__pencil__`

### 4.2 交互 `features.apps=true` 两份样本

样本：

- `/tmp/codex-apps-http-only-8806/008-request.json`
- `/tmp/codex-interactive-errors-8821/008-request.json`

当前已验证：

- `tools_len = 21`
- 工具类型分布：
  - `function = 13`
  - `custom = 1`
  - `web_search = 1`
  - `namespace = 6`
- 当前 `namespace` 清单：
  - `mcp__codex_apps__adobe_photoshop`
  - `mcp__codex_apps__figma`
  - `mcp__codex_apps__github`
  - `mcp__codex_apps__gmail`
  - `mcp__codex_apps__notion__legacy`
  - `mcp__pencil__`

## 5. 当前结论

当前可以写成结论的只有三条：

- 当前四份 `/responses` 首轮请求样本的主骨架一致
- 当前已验证差异不是顶层 payload，而是工具清单
- `features.apps=true` 的当前首轮文本路径会引入额外的 `namespace` 工具

## 6. 当前不能扩大解释

当前不能把这里的结果扩大成：

- “所有 `/responses` 请求都会保持同一顶层骨架”
- “续轮、工具回合和更深 apps 回合也只有工具清单不同”
- “当前四份样本里缺席的字段以后都不会出现”

## 7. 证据位置

- `/tmp/responses-forward-8797/008-request.json`
- `/tmp/responses-forward-8797/016-request.json`
- `/tmp/codex-apps-http-only-8806/008-request.json`
- `/tmp/codex-interactive-errors-8821/008-request.json`
