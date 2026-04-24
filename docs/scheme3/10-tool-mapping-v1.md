# 工具映射 V1

Date: 2026-04-20

## 1. 文档定位

本文件只记录当前已经验证过的工具层事实。

这里不写“应该怎么做”的实现结论；只写：

- Claude 侧真实样本里有哪些工具
- `/responses` 侧真实样本里有哪些工具
- 两边的结构差异和天然交集
- 当前还没验证的环节

## 2. 样本范围

当前使用了三条真实样本：

1. `claude` 指向本地抓包器
2. `claude` 指向本地抓包器
3. `codex exec --json` 的真实 `/responses` zstd 请求体

当前范围只覆盖：

- 当前机器
- 当前安装的 Claude Code / Codex CLI
- 当前会话里暴露给模型的工具集

## 3. 已验证工具清单

### 3.1 Claude `interactive claude`

当前已验证：

- 工具总数是 `4`
- 类型分布：
  - `function`: `3`
  - `advisor_20260301`: `1`

工具名：

- `Bash`
- `Edit`
- `Read`
- `advisor`

### 3.2 Claude 默认交互式工具清单

当前已验证：

- 工具总数是 `56`
- 类型分布：
  - `function`: `55`
  - `advisor_20260301`: `1`

已验证的函数工具名样本包括：

- `Agent`
- `AskUserQuestion`
- `Bash`
- `Edit`
- `Glob`
- `Grep`
- `Read`
- `TodoWrite`
- `WebFetch`
- `WebSearch`
- `Write`
- 多个 `mcp__...` 工具

### 3.3 当前 `/responses` 样本

当前已验证：

- 工具总数是 `16`
- 类型分布：
  - `function`: `13`
  - `custom`: `1`
  - `web_search`: `1`
  - `namespace`: `1`

工具名样本包括：

- `exec_command`
- `write_stdin`
- `list_mcp_resources`
- `list_mcp_resource_templates`
- `read_mcp_resource`
- `update_plan`
- `request_user_input`
- `apply_patch`
- `view_image`
- `spawn_agent`
- `send_input`
- `resume_agent`
- `wait_agent`
- `close_agent`
- `mcp__pencil__`

## 4. 已验证结构差异

### 4.1 函数工具声明层

Claude 当前函数工具的顶层键：

- `name`
- `description`
- `input_schema`

`/responses` 当前函数工具的顶层键：

- `type`
- `name`
- `description`
- `parameters`
- `strict`

当前含义：

- 两边都支持“带名称、描述、JSON schema 的函数工具”
- 但当前样本不支持“原样直转发”
- 至少需要做一层声明层重写：
  - Claude `input_schema`
  - `/responses` `parameters`

### 4.2 特种工具层

Claude 当前已验证的特种工具：

- `advisor`
  - `type: advisor_20260301`

`/responses` 当前已验证的非函数工具：

- `apply_patch`
  - `type: custom`
- web search
  - `type: web_search`
- `mcp__pencil__`
  - `type: namespace`

当前含义：

- Claude 的 `advisor_20260301` 在当前 `/responses` 样本里没有 raw 同形态对应物
- 已验证把 raw `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-4-7"}` 原样追加到 `tools` 数组后，第一段 `/responses` 会返回：
  - `400 Bad Request`
  - `{"detail":"Unsupported tool type: advisor_20260301"}`
- Anthropic 官方 `Advisor tool` 文档当前已明确：
  - 这是单请求内的 server-side tool
  - 响应里会出现 `server_tool_use`
  - 响应里会出现 `advisor_tool_result`
  - 多轮必须把 `advisor_tool_result` 一起带回
- 本机 `claude 2.1.114` 运行态也已验证：
  - `claude` 接受 `server_tool_use + advisor_tool_result`
  - 续轮请求会把这两个 block 原样带回
- `/responses` 的 `custom`、`web_search`、`namespace` 在当前 Claude 样本里也没有同形态对应物

### 4.3 当前可写成实现规则的映射骨架

| Claude 侧对象 | `/responses` 侧对象 | 当前已验证规则 |
| --- | --- | --- |
| function tool | function tool | 保留 `name` 与 `description`；把 `input_schema` 改写成 `parameters`；补 `type:"function"` 与 `strict:false` |
| function tool call | `function_call` | 当前真实远端会原样返回被强制的工具名 |
| function tool result | `function_call_output` | 第二段当前至少接受 `reasoning + function_call + function_call_output` |
| raw `advisor_20260301` | 不可直接透传 | 当前真实远端会返回 `400` 与 `Unsupported tool type: advisor_20260301` |
| Anthropic `advisor` server-side 语义 | synthetic `function name="advisor"` | 当前 bridge 已验证成功，但只能按 [11-advisor-bridge.md](/Users/norvyn/Code/Projects/ModelBridge/docs/scheme3/11-advisor-bridge.md) 的桥接路径实现 |

## 5. 已验证天然交集

当前已验证：

- 默认 `claude` 的工具名集合
- 和当前 `/responses` 样本的工具名集合
- 交集是空集

当前含义：

- 当前两边工具层不是同一套命名体系
- 如果方案三要跑通工具路径，必须做翻译层；不能把“当前抓到的两份工具清单”当成同构接口

## 6. 已验证的关键语义错位

以下对照只描述当前样本看到的参数面，不代表最终实现方案：

| Claude 工具 | Claude 参数 | `/responses` 当前近似项 | `/responses` 参数 | 当前结论 |
| --- | --- | --- | --- | --- |
| `Bash` | `command`, `timeout`, `run_in_background`, `dangerouslyDisableSandbox` | `exec_command` | `cmd`, `sandbox_permissions`, `yield_time_ms`, `tty`, `workdir` 等 | 都与命令执行相关，但参数面不一致，不能直接透传 |
| `Edit` | `file_path`, `old_string`, `new_string`, `replace_all` | `apply_patch` | `custom` grammar payload | 都与文件修改相关，但一个是 JSON 精确替换，一个是 patch grammar |
| `Read` | `file_path`, `offset`, `limit`, `pages` | 当前样本无直接同名函数 | 当前只看到 `read_mcp_resource`、`view_image` 等 | 当前样本里没有文件读取的同类函数对应物 |
| `WebSearch` | `query`, `allowed_domains`, `blocked_domains` | `web_search` | `type`, `external_web_access`, `search_content_types` | 都与联网搜索相关，但声明层形状不同 |
| `Agent` | `description`, `prompt`, `model`, `subagent_type`, `run_in_background`, `isolation` | `spawn_agent` | `message`, `model`, `agent_type`, `fork_context` 等 | 都与子代理有关，但参数面不一致 |

## 7. 当前能下的结论

- 方案三的工具层不能按“当前抓到的工具定义原样透传”来做
- 函数工具至少要做一层声明层转换
- 当前两边工具名没有天然交集
- `advisor_20260301` 是当前工具层里最明显的特种项，但它现在已经有一条已验证的替代桥接路径

### 7.1 已验证声明层接受性

当前已验证两次：

1. 以真实 `/responses` 成功请求为底稿
2. 仅替换其中的 `tools` 数组
3. 把 Claude function tools 改写成：
   - `type: "function"`
   - `name`
   - `description`
   - `parameters = input_schema`
   - `strict: false`
4. 再转发到真实远端 `https://chatgpt.com/backend-api/codex/responses`

当前结果：

- 使用 `claude` 的 `3` 个 function tools 时，得到 `turn.completed`
- 使用默认 `claude` 的 `55` 个 function tools 时，仍得到 `turn.completed`

当前含义：

- 对当前文本路径，函数工具声明层重写不是理论推测，真实远端已经接受
- 当前验证只覆盖“声明层被接受”

### 7.2 已验证 `--bare` / `Bash` 的 tool call / tool result 往返

当前范围：

- `claude` 抓到的 `3` 个 function tools
- 本地代理把它们改写成 `/responses` function tools
- 第一段 `/responses` 强制 `tool_choice = {type:"function", name:"Bash"}`
- 第二段 `/responses` 送回：
  - 第一段输出里的 `reasoning`
  - 第一段输出里的 `function_call`
  - `function_call_output`
    - `call_id = 第一段返回的 call_id`
    - `output = "success"`

当前已验证：

- 第一段真实远端返回了：
  - `response.output_item.added`
    - `item.type = "function_call"`
    - `item.name = "Bash"`
  - `response.function_call_arguments.done`
    - `arguments = "{\"command\":\"true\",\"description\":\"Run no-op command\"}"`
- 第二段真实远端返回了普通 assistant message
- 第二段最终文本是：
  - `Called \`Bash\` once with a minimal valid no-op command: \`true\`.`
- `codex exec` 最终得到：
  - `item.completed`
  - `turn.completed`

当前含义：

- 对当前 `--bare` / `Bash` 路径，tool call / tool result 不是未验证概念；真实远端已经接受这条两段往返
- 当前证据说明：
  - 改写后的 Claude function tool 名称会原样出现在上游 `function_call.name`
  - 上游接受 `function_call_output`
  - 第二段 `input` 当前至少可由 `reasoning + function_call + function_call_output` 组成
- 当前证据不支持把这条结论外推到默认 `claude` 的全部工具

### 7.3 已验证默认 `claude` 的 `55` 个 function tools 下，强制 `Bash` 也能闭环

当前范围：

- 默认 `claude` 抓到的 `55` 个 function tools
- `advisor_20260301` 不在本次转换里
- 第一段 `/responses` 强制 `tool_choice = {type:"function", name:"Bash"}`
- 第二段继续送回：
  - `reasoning`
  - `function_call`
  - `function_call_output`
    - `output = "success"`

当前已验证：

- 第一段真实远端返回：
  - `function_call.name = "Bash"`
  - `function_call_arguments.done.arguments = "{\"command\":\"true\",\"description\":\"Run a no-op command\"}"`
- 第二段真实远端返回普通 assistant message
- 第二段最终文本当前样本是：
  - `Ran a minimal Bash command successfully.`
- `codex exec` 最终得到：
  - `item.completed`
  - `turn.completed`

当前含义：

- 大工具集本身不会阻止当前 `Bash` 路径闭环
- 当前可以把“函数工具声明层被接受”进一步收窄成：
  - `--bare` 的 `Bash` 往返已验证
  - 默认 `55` 个 function tools 环境下的 `Bash` 往返已验证
- 当前仍不能把这条 `Bash` 样本外推成每一个具体工具实例都已闭环

### 7.4 已验证默认 `55` 个 function tools 下的代表性函数家族往返

当前范围：

- 默认 `claude` 抓到的 `55` 个 function tools
- `advisor_20260301` 不在本次转换里
- 第一段强制单个函数工具
- 第二段继续送回：
  - `reasoning`
  - `function_call`
  - `function_call_output`
    - `output = "success"`

当前已验证的代表性函数家族：

- `WebSearch`
  - 第一段参数：`{"query":"AI"}`
  - 第二段最终文本：
    - `WebSearch was called with the minimal valid argument set: \`query: "AI"\`.`
- `Agent`
  - 第一段参数：
    - `{"description":"Minimal agent call","prompt":"No task beyond confirming this invocation. Reply briefly."}`
  - 第二段最终文本：
    - `Invocation completed.`
- `Read`
  - 第一段参数：
    - `{"file_path":"/etc/hosts"}`
  - 第二段最终文本：
    - `Called \`Read\` once with \`file_path: /etc/hosts\`.`
- `Edit`
  - 第一段参数：
    - `{"file_path":"/tmp/x","old_string":"a","new_string":"b"}`
  - 第二段最终文本：
    - `` `Edit` was called with minimal arguments. ``

这些路径里，`codex exec` 都得到：

- `item.completed`
- `turn.completed`

当前含义：

- 当前不是只有 `Bash` 能闭环
- 代表性函数家族已经覆盖：
  - 命令执行
  - 文件读取
  - 文件编辑
  - 联网搜索
  - 子代理
  - 文件写入
  - todo 管理
  - 用户提问卡片
  - 代表性的 `mcp__...` 工具
- 当前仍不能把这组样本外推成“默认 `55` 个 function tools 全部完成往返”

新增已验证样本：

- `Write`
  - 第一段参数：
    - `{"file_path":"/tmp/a","content":""}`
  - 第二段结果：
    - `item.completed`
    - `turn.completed`
- `TodoWrite`
  - 第一段参数：
    - `{"todos":[]}`
  - 第二段最终文本：
    - `Completed.`
- `AskUserQuestion`
  - 第一段参数：
    - `{"questions":[{"question":"Which option do you prefer?","header":"Choice","options":[{"label":"Option 1","description":"Select the first option."},{"label":"Option 2","description":"Select the second option."}],"multiSelect":false}],"metadata":{"source":"developer"}}`
  - 第二段结果：
    - `item.completed`
    - `turn.completed`
- `mcp__claude_ai_Google_Drive__authenticate`
  - 第一段参数：
    - `{}`
  - 第二段最终文本：
    - `Google Drive is already authenticated in this session. The Drive MCP tools should now be available.`

### 7.5 已验证高风险具体 `mcp__...` 工具实例也能闭环

当前范围：

- 默认 `claude` 抓到的真实工具清单
- 第一段强制：
  - `mcp__plugin_Notion_notion__authenticate`
- 第二段继续送回：
  - `reasoning`
  - `function_call`
  - `function_call_output`
    - `output = "success"`

当前已验证：

- 第一段真实远端返回：
  - `function_call.name = "mcp__plugin_Notion_notion__authenticate"`
  - `function_call_arguments = "{}"`
- 第二段真实远端返回普通 assistant message
- 第二段当前最终文本是：
  - `Notion authentication flow started. Open the authorization URL shown by the tool result in your client, complete the login, then send me the callback URL from your browser address bar so I can finish setup.`
- `codex exec` 最终得到：
  - `item.completed`
  - `turn.completed`

当前含义：

- 当前高风险具体 `mcp__...` 工具实例不再停留在家族级推断
- 当前已验证的具体 `mcp__...` 实例至少包括：
  - `mcp__claude_ai_Google_Drive__authenticate`
  - `mcp__plugin_Notion_notion__authenticate`

### 7.6 已验证 raw `advisor_20260301` passthrough 会被第一段 `/responses` 拒绝

当前范围：

- 默认 `claude` 抓到的 `56` 个工具
- `55` 个 function tools 先按既有规则改写成 `/responses` function tools
- `advisor_20260301` 保持 raw 形状：
  - `{"type":"advisor_20260301","name":"advisor","model":"claude-opus-4-7"}`
- 本地代理把这个 raw advisor 直接追加到 `tools` 数组
- 第一段仍强制：
  - `tool_choice = {type:"function", name:"Bash"}`

当前已验证：

- 第一段真实远端直接返回：
  - `400 Bad Request`
- 首响应体当前样本是：
  - `{"detail":"Unsupported tool type: advisor_20260301"}`
- 这次请求没有进入第二段 `function_call_output` 往返
- `codex exec` 最终得到：
  - `turn.failed`

当前含义：

- 当前不能把 Claude 抓到的 raw advisor 对象直接透传给订阅上游
- `advisor_20260301` 的问题已经从“有没有 raw passthrough”收敛成“如何保留 Anthropic server-side 语义并在 `/responses` 侧桥接”

### 7.7 已验证 Anthropic 侧的 `advisor` 正式契约与 CLI 接受性

Anthropic 官方 `Advisor tool` 文档当前已明确：

- 请求定义：
  - `{"type":"advisor_20260301","name":"advisor","model":"..."}`
- 响应语义：
  - `server_tool_use`
  - `advisor_tool_result`
- 这两个 block 都发生在单个 `/v1/messages` 请求里
- 多轮必须把 `advisor_tool_result` 一起带回

本机当前已验证：

- 本地 mock 在主请求的 SSE 里返回：
  - `text`
  - `server_tool_use`
  - `advisor_tool_result`
  - `text`
- `claude` 正常完成
- 用相同 `session_id` 续轮后，Claude 会在 assistant content 中原样带回：
  - `server_tool_use`
  - `advisor_tool_result`

当前含义：

- 方案三在 Anthropic 入口面应该保留 advisor 的 server-side block 语义
- 不应该把 advisor 降成客户端 `tool_result` 回合

### 7.8 已验证 `/responses` synthetic advisor bridge

当前已验证两条 bridge 样本：

1. `gpt-5.4 -> gpt-5.4 advisor`
2. `gpt-5.3-codex -> gpt-5.4 advisor`

当前 bridge 方式：

- 在 `/responses` 主请求里注入一个零参数 function：
  - `name = "advisor"`
- 第一段强制上游调用该 function
- 本地收到真实 `function_call(name="advisor")` 后，再发起一次真实 `/responses` 子调用拿建议文本
- 第三段把建议文本作为 `function_call_output` 送回主请求

当前结果：

- 两条样本都得到：
  - `turn.completed`
- 当前已验证的订阅面模型探针结果：
  - 可用：
    - `gpt-5.4`
    - `gpt-5.4-mini`
    - `gpt-5.3-codex`
  - 不可用：
    - `gpt-5.2-codex`
    - `gpt-5.1-codex-max`

当前含义：

- `advisor_20260301` 当前已有一条被真实订阅上游接受的 bridge 路径
- 当前更合理的一组已验证“执行器 / advisor”分工样本是：
  - `gpt-5.3-codex -> gpt-5.4`

## 9. 当前还不能下的结论

- 不能说所有 Claude function tools 在任意路径下改写后都会被真实远端接受
- 不能说 `advisor_20260301` 可以忽略
- 不能说 raw `advisor_20260301` 可以直接透传到 `/responses`
- 不能说 `Bash -> exec_command`、`Edit -> apply_patch`、`Agent -> spawn_agent` 就是最终正式映射
- 不能说当前 `/responses` 样本里的 16 个工具就是方案三必须采用的工具集合
- 不能说默认 `claude` 的全部 function tools 都已经跑通
- 不能说 advisor bridge 原型已经等于正式实现
