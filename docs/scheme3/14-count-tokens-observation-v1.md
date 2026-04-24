# Claude `count_tokens` 观测结果 v1

Date: 2026-04-20

## 1. 文档定位

本文件只记录当前已测 Claude CLI 路径里，`/v1/messages/count_tokens` 是否真的被调用。

这里不推导“未来一定不会调用”；只记录当前实测结果。

本轮新增样本的本机 CLI 版本：

- `claude --version`
  - `2.1.116 (Claude Code)`

## 2. 官方要求

Anthropic 官方当前要求 Claude Code 网关提供：

- `POST /v1/messages`
- `POST /v1/messages/count_tokens`

同时，官方 `Count tokens in a Message` 文档当前把该接口返回对象写成：

- `{"input_tokens": ...}`

来源：

- <https://code.claude.com/docs/en/llm-gateway>
- <https://platform.claude.com/docs/en/api/messages/count_tokens>

## 3. 本机验证方法

本机新增 loopback probe：

- [probe_anthropic_count_tokens.py](/Users/norvyn/Code/Projects/ModelBridge/scripts/probe_anthropic_count_tokens.py)

探针行为：

- 逐条记录 `POST /v1/messages` 与 `POST /v1/messages/count_tokens`
- `count_tokens` 若被调用，返回：
  - `{"input_tokens":1}`
- `messages` 返回最小文本 SSE 成功流

## 4. 当前已测路径

### 4.1 `claude`

命令形状：

- `export ANTHROPIC_BASE_URL=http://127.0.0.1:8799; export ANTHROPIC_AUTH_TOKEN=test-token; claude`，TUI 输入 prompt: `reply with exactly BARE_CT_OK`

观测结果：

- 总请求数：`2`
- `POST /v1/messages/count_tokens`：`0`
- `POST /v1/messages`：`2`
- 请求形状：
  - 第 `1` 条是 `claude-haiku-4-5-20251001` 的标题生成请求，`tools=[]`
  - 第 `2` 条是 `claude-sonnet-4-6` 的主回复请求，`tools=4`

### 4.2 `claude`

命令形状：

- `export ANTHROPIC_BASE_URL=http://127.0.0.1:8800; export ANTHROPIC_AUTH_TOKEN=test-token; claude`，TUI 输入 prompt: `reply with exactly DEFAULT_CT_OK`

观测结果：

- 总请求数：`1`
- `POST /v1/messages/count_tokens`：`0`
- `POST /v1/messages`：`1`
- 请求形状：
  - 唯一请求是 `claude-sonnet-4-6`
  - `tools=56`

### 4.3 `claude` + `-r <session-id>`

命令形状：

- 首轮：
  - `export ANTHROPIC_BASE_URL=http://127.0.0.1:8801; export ANTHROPIC_AUTH_TOKEN=test-token; claude --session-id c7c1591a-c87b-49e2-9c6f-963b0ff70d48`，TUI 输入 prompt: `reply with exactly RESUME_CT_OK`
- 续轮：
  - `export ANTHROPIC_BASE_URL=http://127.0.0.1:8801; export ANTHROPIC_AUTH_TOKEN=test-token; claude -r c7c1591a-c87b-49e2-9c6f-963b0ff70d48`，TUI 输入 prompt: `reply with exactly RESUME2_CT_OK`

观测结果：

- 总请求数：`3`
- `POST /v1/messages/count_tokens`：`0`
- `POST /v1/messages`：`3`
- 请求形状：
  - 首轮仍是 bare 模式的两段请求：
    - `haiku title`
    - `sonnet main`
  - 续轮只发 `1` 条 `claude-sonnet-4-6` 请求
  - 续轮请求体里的 `messages=3`

### 4.4 交互 TTY：`claude --bare`

命令形状：

- `export ANTHROPIC_BASE_URL=http://127.0.0.1:8802; export ANTHROPIC_AUTH_TOKEN=test-token; claude --bare --session-id 8f13d3e9-53f8-4cf0-b0bc-3fe578ed14ab`，TUI 输入 prompt: `reply with exactly INTERACTIVE_CT_OK`

观测结果：

- 总请求数：`2`
- `POST /v1/messages/count_tokens`：`0`
- `POST /v1/messages`：`2`
- 请求形状：
  - 第 `1` 条是 `haiku title`
  - 第 `2` 条是 `sonnet main`

### 4.5 默认交互 TTY：`claude`

命令形状：

- `export ANTHROPIC_BASE_URL=http://127.0.0.1:8803; export ANTHROPIC_AUTH_TOKEN=test-token; claude --session-id 4c1ca360-b690-487a-ba4f-5cfe5fa10bc9`，TUI 输入 prompt: `reply with exactly DEFAULT_INTERACTIVE_CT_OK`

观测结果：

- 总请求数：`2`
- `POST /v1/messages/count_tokens`：`0`
- `POST /v1/messages`：`2`
- 请求形状：
  - 第 `1` 条是 `claude-haiku-4-5-20251001` 的标题生成请求，`tools=0`
  - 第 `2` 条是 `claude-sonnet-4-6` 的主回复请求，`tools=33`

### 4.6 `claude --continue`

命令形状：

- 首轮：
  - `export ANTHROPIC_BASE_URL=http://127.0.0.1:8804; export ANTHROPIC_AUTH_TOKEN=test-token; claude`，TUI 输入 prompt: `reply with exactly CONTINUE_SEED_OK`
- `--continue`：
  - `export ANTHROPIC_BASE_URL=http://127.0.0.1:8804; export ANTHROPIC_AUTH_TOKEN=test-token; claude -c`，TUI 输入 prompt: `reply with exactly CONTINUE2_OK`

观测结果：

- 总请求数：`2`
- `POST /v1/messages/count_tokens`：`0`
- `POST /v1/messages`：`2`
- 请求形状：
  - 首轮是 `claude-sonnet-4-6`，`tools=56`，`messages=1`
  - `-c` 续轮是 `claude-sonnet-4-6`，`tools=56`，`messages=3`

### 4.7 默认 `claude` 的真实 tool roundtrip

命令形状：

- `export ANTHROPIC_BASE_URL=http://127.0.0.1:8805; export ANTHROPIC_AUTH_TOKEN=test-token; claude`，TUI 输入 prompt: `reply with exactly TOOL_ROUND_OK after any required tool use`

probe 行为：

- 第 `1` 条 `/v1/messages` 返回 `Read` 的 `tool_use`
- 第 `2` 条 `/v1/messages` 在收到 `tool_result` 后返回最终文本

观测结果：

- 总请求数：`2`
- `POST /v1/messages/count_tokens`：`0`
- `POST /v1/messages`：`2`
- 请求形状：
  - 第 `1` 条是 `claude-sonnet-4-6`，`tools=56`，`messages=1`
  - 第 `2` 条是 `claude-sonnet-4-6`，`tools=56`，`messages=3`
  - 第 `2` 条请求体最后一个 content block 是：
    - `tool_result`
  - 当前样本里的 `tool_use_id` 是：
    - `toolu_probe_roundtrip_01`

### 4.8 `claude`

命令形状：

- 无效调用：
  - 旧非交互 JSON 输出 probe（已废弃，不作为验收路径）
- 有效调用：
  - `export ANTHROPIC_BASE_URL=http://127.0.0.1:8896; export ANTHROPIC_AUTH_TOKEN=test-token; claude`，TUI 输入 prompt: `reply with exactly COUNT_TOKENS_CT_OK`

已验证结果：

- 旧非交互 probe 不再作为有效测试路径：
  - `Error: legacy non-interactive probe required verbose mode`
- 交互式有效调用里：
  - 总请求数：`1`
  - `POST /v1/messages/count_tokens`：`0`
  - `POST /v1/messages`：`1`
  - 当前样本请求路径是：
    - `/v1/messages?beta=true`
  - CLI 最终完成并输出响应

## 5. 当前结论

当前已测的八条 Claude CLI 路径里，`/v1/messages/count_tokens` 都没有被调用：

- `claude`
- `claude`
- `claude` 首轮 + `-r` 续轮
- 交互 TTY `claude --bare`
- 默认交互 TTY `claude`
- `claude --continue`
- 默认 `claude` 的真实 tool roundtrip
- `claude`

同时，官方文档仍要求网关提供该 endpoint。

所以当前能写进正式文档的结论只有两条：

- 方案三的 Anthropic 边必须实现 `POST /v1/messages/count_tokens`
- 在当前已测路径里，不能把它当成启动前置依赖或每轮必经请求

## 6. 当前不能外推的内容

以下内容当前还不能写成定论：

- 未来版本会不会调用 `count_tokens`
- 仅凭当前 runtime 行为，能不能推出比 `{"input_tokens": ...}` 更强的最小响应契约
