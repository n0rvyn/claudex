# 方案三执行顺序与验收

Date: 2026-04-21

Migration note:

- The active project root is now `/Users/norvyn/Code/Projects/ModelBridge`.
- The old `/Users/norvyn/Code/Projects/cc-router` root only retains `.build/` cache and is no longer the active source root.

## 1. 文档定位

本文件只回答两件事：

1. 正式实现按什么顺序做
2. 每一步以什么结果算完成

## 2. 执行顺序

### Phase 1. 本地 daemon 骨架

交付：

- 本地 HTTP server
- `POST /v1/messages`
- `POST /v1/messages/count_tokens`
- 基础日志与 correlation id
- 本地 gateway token 校验与持久化配置

完成标准：

- 本地 health/doctor 可显示 daemon 在线
- `count_tokens` 返回 Anthropic 兼容 JSON
- `messages` 与 `count_tokens` 对错误 token 返回本地鉴权错误

当前状态：

- 已完成
- 当前运行态证据：
  - `curl -sS http://127.0.0.1:4317/health`
  - `curl -sS http://127.0.0.1:4317/v1/messages/count_tokens ...`
  - 当前返回样本：`{"input_tokens":13}`
  - 当前本地 ingress auth 样本：
    - 错误 `x-api-key` -> `HTTP/1.1 401 Unauthorized`
    - 正确 `x-api-key` -> `HTTP/1.1 200 OK` + `{"input_tokens":1}`

### Phase 2. 文本路径打通

交付：

- `anthropic-edge`
- `subscription-session`
- `responses-adapter`

完成标准：

- Claude Code 文本路径成功
- 本地 `/responses` 到真实远端可完成一轮回复
- 日志里能关联 Claude request 与 upstream request

当前状态：

- 已完成
- 当前真实命令：
  - `claude --bare -p 'Reply exactly DEFAULTOK.'`
  - `claude --bare -p --output-format json 'Reply exactly CCRUN.'`
  - `claude -p --output-format json 'Reply exactly FULLTOOLOK.'`

### Phase 3. function tool 路径打通

交付：

- `tool-mapper`
- 两段 function 回合处理

完成标准：

- 至少验证：
  - `Bash`
  - `Read`
  - `Edit`
  - `Write`
- Claude Code 真路径里能成功完成工具回合

当前状态：

- 已完成第一版正式代码
- 当前真实命令：
  - `claude --bare -p --output-format json 'Use the Read tool ...'`
  - `claude --bare -p --output-format json 'Use the Bash tool ...'`
- 当前 trace：
  - `/tmp/modelbridge-trace.jsonl`
- 说明：
  - 代码当前已经解决了旧 `tool_result` 历史重放导致的 `No tool call found for function call output` 问题
  - `Write / Edit` 的强制 CLI prompt 当前仍会受模型自行改写路径或工具选择影响；当前 trace 已经证明本地 daemon 收到了这两类真实 `function_call` 并完成了后续 continuation，但这两条 prompt 当前不能当稳定金标准

### Phase 4. advisor 路径打通

交付：

- `advisor-bridge`

完成标准：

- Claude 侧看到：
  - `server_tool_use`
  - `advisor_tool_result`
- 上游侧走 synthetic advisor bridge
- 续轮能保留 advisor 相关 block

当前状态：

- 已完成第一版正式代码
- 当前真实命令：
  - `claude --bare -p --output-format json 'Use the advisor tool before answering. After consulting it, reply with exactly ADVISOROK.'`
- 当前结果：
  - `result = "ADVISOROK"`

### Phase 5. 默认完整工具清单与代表性 connector 路径

交付：

- 默认 `claude -p` 完整工具清单桥接
- 至少一条代表性 connector 路径的真实成功样本

完成标准：

- 默认 `claude -p` 完整工具清单文本路径成功
- 至少一条默认 connector 路径真成功

当前状态：

- 已完成
- 当前真实命令：
  - `claude -p --output-format json 'Reply exactly FULLTOOLOK.'`
  - `claude -p --output-format json 'Call the mcp__plugin_Notion_notion__authenticate tool now. After the tool returns, reply with exactly NOTIONAUTHSEEN.'`
- 当前结果：
  - `result = "FULLTOOLOK"`
  - `result = "NOTIONAUTHSEEN"`

### Phase 6. macOS 壳与 doctor

交付：

- menu bar app
- 环境变量生成
- doctor 页面
- 日志查看入口

完成标准：

- 用户能从 app 里拿到可直接用于 Claude Code 的配置
- doctor 能显示：
  - daemon 状态
  - ChatGPT 登录态
  - trace 路径
  - 最近 trace 片段

当前状态：

- 已完成
- 已完成：
  - daemon 启停
  - endpoint 展示
  - 持久化 Claude CLI 环境变量片段
  - `Copy Env`
  - `launch at login` 状态与开关接线
  - ChatGPT auth 状态
  - 本地 config path
  - 订阅 auth 文件路径
  - connector diagnostics 摘要
  - 最近 trace 查看 UI
  - 设置页 doctor 明细
  - Xcode app target now hosts the active menu bar app shell under `ModelBridge/`
  - `bash scripts/build_app_bundle.sh` now produces `dist/ModelBridge.app`
  - `bash scripts/smoke_local_gateway.sh` passes from the `ModelBridge` root
  - `codesign -dv --verbose=4 dist/ModelBridge.app` shows `Signature=adhoc`
  - `codesign --verify --deep --strict --verbose=2 dist/ModelBridge.app` passes

## 3. 正式验收矩阵

| 验收项 | 通过标准 |
| --- | --- |
| Claude 文本路径 | `Claude Code CLI` 指向本地网关后完成一轮文本回复 |
| Claude function 路径 | `Bash / Read` 真路径成功；`Write / Edit` 当前 trace 已证实真实 `function_call` 与 continuation，经由本地 daemon 完成桥接 |
| Claude advisor 路径 | `server_tool_use + advisor_tool_result` 真路径成功 |
| 默认完整工具清单 | 默认 `claude -p` 文本路径真成功 |
| 代表性 connector 路径 | `mcp__plugin_Notion_notion__authenticate` 真路径成功 |
| count_tokens | endpoint 存在且返回 Anthropic 兼容 JSON |
| 本地 ingress auth | 错误 token 被拒绝；正确 token 可完成真实 Claude 路径 |
| doctor | 可以独立检查 auth、主推理配置、config path、订阅 auth 文件路径、trace、connector diagnostics |
| Xcode project migration | `ModelBridge.xcodeproj` build 通过；`ModelBridgeTests` 通过；旧 `cc-router` 根目录不再承载源码 |
| packaged app | `bash scripts/build_app_bundle.sh` 产出 `dist/ModelBridge.app`；`adhoc` 签名验证通过；`bash scripts/smoke_local_gateway.sh` 通过 |
| launch at login | API 接线与状态映射编译通过；真实 packaged-app register/unregister 仍按系统状态验证处理 |

## 4. 禁止验收替代项

以下都不能替代正式验收：

- 只跑 unit test
- 只跑 mock probe
- 只看 build 成功
- 只看 `/responses` 文本路径成功

原因：

- 方案三的价值不在“单轮文本能跑”
- 真实默认工具清单、advisor bridge、代表性 connector 路径都必须过本地桥接层

## 5. 失败处理规则

如果某个 phase 不通过：

- 先修当前 phase 的 blocker
- 不允许跳到后一个 phase 做替代性推进
- 不允许把 bridge、sidecar、app 家族问题降成“后续增强”
