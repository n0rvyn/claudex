# Decision Crystal: Phase 3 Visual & Protocol Expectations

Date: 2026-04-22

## Initial Idea

Phase 3 落地三类协议完备性修正（3a 图像多模态、3b extended thinking surface、3c assistant 历史 tool_use/thinking replay），目标是让 Claude Code CLI 的行为无差别接近"原生 Anthropic 体验"。用户在 scope 确认阶段补充的细节：

1. 图像路径（`input_image` 官方协议 vs `view_image` function）的 probe verification task 在 **Phase 3 内部**执行（不推迟，不拆到独立阶段）
2. Extended thinking 的 summary 文本要 **与 thinking 指示器同步 surface 到 Claude CLI**（不只是 emit 空的 indicator；用户要能看到"在想什么"的摘要）
3. 追求 Claude Code 原生级的 reasoning 连续性；历史 thinking 块的 replay 必须保持 encrypted_content 的完整 roundtrip，不走合成/裁剪

## Discussion Points

- 关于 3c 历史 thinking 降级策略的 4 个初选方案（A 静默丢弃 / B summary-only 合成 / C 合并进 assistant text / D 把 Anthropic signature 当 encrypted_content）被评估后全部被换掉，采用新方案 E：
  - **方向对应**：`/responses` reasoning item 的 `encrypted_content` ↔ Anthropic thinking block 的 `signature` 字段（两侧都是客户端不解析、只需 verbatim 回传的 opaque 字节）
  - **方向对应**：`/responses` reasoning item 的 `summary` ↔ Anthropic thinking block 的 `thinking` 字段（两侧都是 plain text）
- Evidence 支撑：`docs/scheme3/09 §4.3` 已验证 `drop_reasoning_item` 模式下真实上游仍返回 `turn.completed`，所以 signature 解码失败时的"静默丢弃"降级路径不会导致 upstream 失败
- Probe 假设：Claude CLI 对 signature 字段语义上就是 opaque passthrough（验证由 Anthropic 服务端完成），不会做客户端格式校验；需要在 Phase 3b 的 probe 里顺便验证一次

## Rejected Alternatives

- **B（合成 summary-only reasoning item）**：未验证上游是否接受"只有 summary 无 encrypted_content"的 reasoning item；可能被 400 拒绝。E 直接用上游真实 encrypted_content 绕开该风险
- **C（合并进下一条 assistant text，如 `[previous thinking: ...]` 前缀）**：改变消息语义，污染模型输出风格；下一条消息若无 assistant text（纯 tool_use 结尾）还要选注入点，工程噪声大
- **D（把 Anthropic signature 当 encrypted_content）**：方向搞反。Anthropic signature 是 Anthropic 服务端签名，上游 `/responses` 的 encrypted_content 是 OpenAI 侧密文，两者语义不同；E 的方向是"上游 encrypted_content 塞进 Anthropic signature 字段 roundtrip"，才正确

## Decisions (machine-readable)

- [D-001] Phase 3a 图像路径 probe verification task 在 Phase 3 内部执行，不推迟。Probe 针对 `input_image`（OpenAI 官方协议，`docs/scheme3/10 §3.3` 未在订阅端直接验证）vs `view_image` function（`docs/scheme3/10 §3.3` 在真实上游工具清单里有，但 ModelBridge 当前未注入）两条路径各发一条最小请求，记录真实响应码与错误正文；只把返回 200 的路径写进实现
- [D-002] Phase 3b 在 upstream `include` 参数中追加 `reasoning.summary`（当前仅 `reasoning.encrypted_content`，见 `AnthropicBridge.swift:773`），拿到 summary 文本
- [D-003] Phase 3b 把上游 reasoning item 的 `summary` 字段与 thinking indicator 同步 emit 到 Claude CLI，不只是 emit 空 indicator；最终形态是 CLI 能看到"在想什么"的摘要文本
- [D-004] Phase 3b emit 方向的 thinking 块形状：`{type: "thinking", thinking: "<upstream summary>", signature: "<base64(upstream encrypted_content)>"}`。新增 `IRBlock.thinking(encryptedContent, summary)` → Anthropic SSE content_block 的 converter
- [D-005] Phase 3c replay 方向的 thinking 块形状：`assistant` role history 里的 `{type: "thinking", thinking, signature}` → `/responses` input `{type: "reasoning", encrypted_content: base64decode(signature), summary: thinking}`
- [D-006] signature 缺失、无法 base64 解码、或格式不符时：静默丢弃该 thinking 块，不进入 `/responses` input（降级方案 A）。不合成占位 reasoning item、不污染其他消息
- [D-007] Phase 3b probe verification task 增加一条断言：向 Claude CLI emit 一条带已知 base64 signature 的 thinking 块（summary + signature 都是已知测试字符串），等待 CLI 续轮请求，断言该 signature 字段 verbatim 出现在历史里。这验证 CLI 对 signature 字段的 passthrough 假设；失败则 fallback 到方案 A 作为唯一路径

## Constraints

- signature 字段的使用必须是 opaque passthrough 语义；不改 Anthropic 协议原有字段定义
- encrypted_content 以 base64（url-safe 或标准均可，但编码方案要一致）字符串形式写入 signature；不引入新字段、新 header、新 schema
- Phase 3a probe 失败（两条路径都非 200）时 → 作为 blocking decision 回报给用户，不擅自降级为"不支持图像"
- Phase 3b probe 失败（CLI 不 verbatim 保留 signature）时 → emit 仍走 D-004（至少有 summary 显示），但 3c replay 降级为 D-006 的静默丢弃；reasoning 连续性降级，这属于可接受降级，不阻塞 Phase 3 交付
- thinking summary surface 不得引入 Claude CLI 侧额外 UI 重构；限制在现有 content_block 的 SSE 协议内完成

## Scope Boundaries

- **IN**:
  - 3a 图像块翻译 + probe（`input_image` vs `view_image`）
  - 3b extended thinking surface（encrypted_content 保留 + summary 同步显示 + signature-as-encrypted_content roundtrip）
  - 3c assistant 历史 tool_use / tool_result / thinking 块的 `/responses` input 重建
  - 3b probe 顺带验证 CLI signature passthrough 假设
- **OUT**（明确不做）：
  - 不改 `thinking` 请求字段（Claude `thinking: {type: enabled, budget_tokens}` → upstream `reasoning.effort`）的路由表策略，该策略沿用 Phase 2 路由表 + 新增"budget_tokens → effort"的直接映射（不引入新独立配置）
  - 不实现 pre-Phase-3 老会话的自动重建（老会话续轮走 D-006 降级路径，可接受）
  - 不重构 `AnthropicSSEEncoder` 的 block 开/关语义（沿用现有 open/close block 机制）

## Source Context

- Design doc: 无独立 design.md；设计输入来自 `docs/scheme3/` 已验证事实集合
- Dev-guide: `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md` Phase 3
- Relevant scheme3 sections:
  - `docs/scheme3/09 §4.2`：真实上游 reasoning item 结构（encrypted_content + summary）
  - `docs/scheme3/09 §4.3`：drop_reasoning_item 仍 turn.completed 的已验证证据
  - `docs/scheme3/10 §3.3`：真实上游工具清单含 view_image function
- Code anchors:
  - `Sources/CCRouterCore/AnthropicBridge.swift:345-355`（convertContentBlocks 只识别 text）
  - `Sources/CCRouterCore/AnthropicBridge.swift:331-343`（convertMessages 对历史 block 的处理入口）
  - `Sources/CCRouterCore/AnthropicBridge.swift:690-713`（stringifyToolResultContent）
  - `Sources/CCRouterCore/AnthropicBridge.swift:503-663`（buildAnthropicSSE，reasoning item 目前在 default: continue 分支）
  - `Sources/CCRouterCore/AnthropicBridge.swift:773`（当前 include 配置）
  - `Sources/CCRouterCore/AnthropicProtocol.swift:9`（thinking: JSONObject? 字段）
