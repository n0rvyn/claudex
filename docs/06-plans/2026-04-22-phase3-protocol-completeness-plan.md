---
type: plan
status: active
tags: [multimodal, thinking, tool-use-history, ir, protocol-bridge, streaming]
refs:
  - docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
  - docs/11-crystals/2026-04-22-phase-3-protocol-completeness-crystal.md
  - docs/research/2026-04-22-image-wire-probe.md
  - docs/scheme3/09-real-upstream-capture.md
  - docs/scheme3/10-tool-mapping-v1.md
---

# Phase 3: 协议完备性（多模态 + Thinking + 历史工具回放）Implementation Plan

**Goal:** 关闭三类协议翻译黑洞 —— 图像块丢弃、extended thinking 不 surface、assistant 历史里的 tool_use/tool_result/thinking 块 replay 丢失；采用方案 E（signature ↔ encrypted_content roundtrip）让新会话续轮具备 Claude Code 原生级 reasoning 连续性；利用 `reasoning.summary: auto` 新事件流实现实时 thinking 文本流式 surface 给 CLI。

**Architecture:** Phase 1 已铺好 IR 地基（`.image(data, mediaType)` 与 `.thinking(encryptedContent, summary)` case 在 `IRBlock`；`IRAnthropicCodec.decodeRequestBlocks` 已识别 image/thinking 类型；`IRResponsesCodec.encodeReplayBlocks` 已支持 reasoning+function_call 的 base64 encrypted_content roundtrip）。Phase 3 完成以下收尾：(1) `IRAnthropicCodec.encodeResponseBlock`/`decodeRequestBlocks` 完成 `signature` 字段与 upstream `encrypted_content` 的 base64 roundtrip（方案 E）；(2) `makeResponsesPayload` 添加 `reasoning.summary: "auto"`，在 `processUpstreamStream` 新增 4 类 SSE 事件处理（`reasoning_summary_part.added` / `reasoning_summary_text.delta` / `reasoning_summary_part.done` / reasoning 的 `output_item.done`），通过 Anthropic `thinking_delta` + `signature_delta` 增量事件流式送到 CLI；(3) `IRResponsesCodec` 里图像用 `input_image` data URL 编码进 user message content（probe Row A 验证），tool_result 内的 image 通过 `function_call_output` + synthetic user message 两段结构 emit（probe Row D 验证）；(4) 新增 `IRResponsesCodec.encodeFullHistory` 按时序把 message-nested blocks 与顶层 replay items 正确 interleave。

**Tech Stack:** Swift 6 actor + `URLSession.bytes(for:)` streaming；Swift Testing (`@Test` / `#expect`)；已证据化的 probe 结果（`docs/research/2026-04-22-image-wire-probe.md`）。

**Design doc:** 无独立 design.md；设计输入来自 `docs/scheme3/` 已验证事实 + Phase 3 dev-guide scope + Phase 3 probe 报告。

**Crystal file:** `docs/11-crystals/2026-04-22-phase-3-protocol-completeness-crystal.md`

**Threat model:** included（auth token 透传 + 客户端 opaque 字段 roundtrip 完整性 + image MIME 白名单）

---

## Threat Model

**Attack surface:**

- `~/.codex/auth.json` 的 `access_token` / `account_id`：probe 脚本读取；任何 probe 输出（`docs/research/*.md`）落盘前过 `_probe_common.redact()`
- Claude 请求里 `signature` 字段：用户会话历史的一部分，客户端可构造任意字节；decoder 用 `Data(base64Encoded:)` 已做格式校验，无法解码则按 [D-006] 静默丢弃
- 请求里 `thinking.thinking` 文本字段 + 新增的 upstream summary 文本：均作为 summary 文本透传，不 eval 不拼接进命令行
- Anthropic `image.source.data` 与 `image.source.media_type`：Phase 1 已用 `Data(base64Encoded:)` 校验格式；本 Phase 3 在编码时增加 MIME 白名单（`image/png` / `image/jpeg` / `image/webp` / `image/gif`）

**Failure modes:**

- `reasoning.summary: auto` 未来被上游禁用 → 新 SSE 事件不出现；现有 `processUpstreamStream` 的 `default: continue` 分支静默忽略未知事件，不会导致 stream 中断；降级为"reasoning 指示器不 surface"
- Thinking streaming 中途 upstream 抛错（`response.failed`）→ `processUpstreamStream` 已有 `catch` 分支处理上游流错误，close open block + emit 文本 marker
- CLI signature passthrough 假设失败 → encrypted_content roundtrip 降级为 [D-006] 静默丢弃，reasoning 连续性下降但不回归
- `encodeFullHistory` 遇到未知 message role 或未识别 block type → 沿用现有"unknown 静默丢弃"策略

**Resource lifecycle:**

- 本次实现不新增 temp file / child process / persistent socket
- probe 脚本 HTTP socket：`urllib.request.urlopen` 的 `with` 块覆盖；timeout=60 秒

**Input validation requirements:**

- Anthropic `signature` 字段 → `Data(base64Encoded:)`：只接受合法 base64；失败转 nil
- Anthropic `image.source.data` 字段 → `Data(base64Encoded:)`（Phase 1 已有）
- Anthropic `image.source.media_type`：白名单 `["image/png", "image/jpeg", "image/webp", "image/gif"]`，在编码到 `input_image.image_url` 时校验
- probe 响应正文：`redact()` 后落盘

---

<!-- section: task-1 keywords: probe, image-wire, reasoning-summary, probe-report -->
### Task 1: ✅ DONE — 上游协议 probe + 报告

**Crystal ref:** [D-001], [D-002]

**Status:** 已在 plan 草拟过程中执行完成。证据固化在 `docs/research/2026-04-22-image-wire-probe.md`，后续 Task 5/6/7/8 直接引用结论，不再做条件分支。

**Files:**
- Created: `scripts/probe_image_wire.py`
- Created: `docs/research/2026-04-22-image-wire-probe.md`

**Probe 结论（已锁）：**

1. ✅ `input_image` 在 user message content 里用 data URL 形式（`data:image/png;base64,...`），upstream 接受并 `turn.completed`（Row A）
2. ✅ `view_image` function 注入可用但**不是** 3a 的主路径（它是 path 参数的文件读取函数，不是 base64 内容携带 — Row B）
3. ❌ `include: ["reasoning.summary"]` 被上游明确拒绝（400，附带白名单：`reasoning.encrypted_content` 在单，`reasoning.summary` 不在）
4. ✅ `reasoning.summary: "auto"` 作为请求参数（不是 include）触发新 SSE 事件流（`reasoning_summary_part.added` / `reasoning_summary_text.delta` × N / `reasoning_summary_part.done`），同时 `output_item.done` 的 reasoning item 仍带 `encrypted_content`（1636 字节）（Row E/F）
5. ✅ Tool_result 内 image 通过 `function_call_output` + 后续 user message with `input_image` 两段式 emit，upstream `turn.completed`（Row D）

**Verify:** 报告已存在。`test -f docs/research/2026-04-22-image-wire-probe.md`
<!-- /section -->

---

<!-- section: task-2 keywords: cli-source, signature-passthrough, claude-code -->
### Task 2: Claude Code CLI signature 字段透传源码检查

**Crystal ref:** [D-007]

**Files:**
- Create: `docs/research/2026-04-22-cli-signature-passthrough.md`

**Steps:**

1. 用 `gh repo view anthropics/claude-code 2>&1` 确认仓库存在。若 404：跳到 fallback（步骤 5）
2. 使用 `gh api "search/code?q=repo:anthropics/claude-code+signature+thinking&per_page=10" --jq '.items[].path'` 定位包含 `signature` 与 `thinking` 的源文件
3. 对前 3 个命中文件分别 `gh api repos/anthropics/claude-code/contents/<path> --jq .content | base64 -d | grep -nE "signature|thinking" | head -30` 抓取相关行
4. 写报告 `docs/research/2026-04-22-cli-signature-passthrough.md`，至少包含：
   - 检查结论 `signature_preserved_verbatim: true/false/inconclusive`
   - 如找到代码引用，给出 repo path 与关键行
   - 如无法确认：标注 `⚠️ 需真机验证` + 具体验证步骤（启动 daemon → 用真实 Claude CLI 触发带 thinking 的会话 → 续轮检查 assistant history thinking 块的 signature 是否 verbatim 回传）
5. **Fallback path**（无法访问仓库）：
   - 查 WebFetch 公开 Anthropic 文档的 thinking block 字段说明，记录 signature 字段的文档定义（"opaque cryptographic value that must be returned verbatim"）
   - 报告结论为"依据公开文档，CLI 按 Anthropic 规范应 verbatim 保留 signature；本 Phase 按此假设推进，若真机验证失败则走 [D-006] 降级"

**Verify:**
Run: `test -f docs/research/2026-04-22-cli-signature-passthrough.md && grep -E "signature_preserved_verbatim|⚠️" docs/research/2026-04-22-cli-signature-passthrough.md`
Expected: 报告存在；含上述结论字段或标注。

⚠️ No test: 纯研究 + 报告。
<!-- /section -->

---

<!-- section: task-3 keywords: ir-codec, signature, encrypted-content, thinking, decode, summary-list -->
### Task 3: IR codec — 请求 + 响应两个方向的 thinking summary/signature 解码修正

**Crystal ref:** [D-005]

**Files:**
- Modify: `Sources/CCRouterCore/IR/IRAnthropicCodec.swift:52-57`（Anthropic 请求方向 thinking case）
- Modify: `Sources/CCRouterCore/IR/IRResponsesCodec.swift:136-140`（`decodeOutputItem` 的 reasoning case — summary 实为 list of `{type:summary_text, text:...}` 对象）

**Steps:**

1. 替换 `IRAnthropicCodec.decodeRequestBlocks` 的 `case "thinking":` 分支为：
   ```swift
   case "thinking":
       let summary = block.string("thinking")
       let signatureString = block.string("signature")
       let encryptedContent: Data?
       if let signatureString, !signatureString.isEmpty,
          let decoded = Data(base64Encoded: signatureString) {
           encryptedContent = decoded
       } else {
           encryptedContent = nil
       }
       return .thinking(encryptedContent: encryptedContent, summary: summary)
   ```
2. 更新注释：`// signature ↔ encrypted_content roundtrip (Phase 3 scheme E; crystal [D-005])`

3. 修正 `IRResponsesCodec.decodeOutputItem` 的 reasoning case（probe 证据：`docs/research/2026-04-22-image-wire-probe.md` 显示上游 summary 字段是 `list of {type:"summary_text", text:...}`，不是 plain string）：
   ```swift
   case "reasoning":
       let encBase64 = item.string("encrypted_content") ?? ""
       let encryptedContent = Data(base64Encoded: encBase64)
       let summary = Self.flattenReasoningSummary(item["summary"])
       return .thinking(encryptedContent: encryptedContent, summary: summary)
   ```
4. 在 `IRResponsesCodec` 内新增 private helper（`Private helpers` 区块里）：
   ```swift
   /// Flattens the reasoning item's summary field, which upstream emits as
   /// either a plain string (fallback / legacy) or a list of
   /// `{type: "summary_text", text: "..."}` objects (current Codex gpt-5.4 shape,
   /// verified in docs/research/2026-04-22-image-wire-probe.md Row F).
   /// Returns nil when no text content is present.
   static func flattenReasoningSummary(_ value: JSONValue?) -> String? {
       guard let value else { return nil }
       switch value {
       case .string(let s):
           return s.isEmpty ? nil : s
       case .array(let items):
           let texts = items.compactMap { item -> String? in
               guard case .object(let obj) = item else { return nil }
               guard obj.string("type") == "summary_text" else { return nil }
               return obj.string("text")
           }
           let joined = texts.joined(separator: "\n\n")
           return joined.isEmpty ? nil : joined
       case .null, .object, .number, .bool:
           return nil
       }
   }
   ```
5. `encodeReplayBlocks` 与 `encodeFullHistory` 在往 `/responses` 输入里写 reasoning item 的 `summary` 字段时：**不再** emit plain string（Phase 1 的 `"summary": .string(summary ?? "")` 会偏离真实上游 shape）。改为按条件 emit list 形状：有 summary 时发单元素列表，summary 为 nil/empty 时发空列表 `[]`：
   ```swift
   // In encodeReplayBlocks / encodeFullHistory when emitting reasoning item:
   let summaryList: [JSONValue]
   if let summary, !summary.isEmpty {
       summaryList = [.object(JSONObject.from([
           "type": .string("summary_text"),
           "text": .string(summary),
       ]))]
   } else {
       summaryList = []
   }
   // use .array(summaryList) for the "summary" field instead of .string(summary)
   ```
   这保证 replay 时发回的 reasoning item 与上游真实 shape 一致；encrypted_content 是 roundtrip 的核心，summary 是附属可读字段

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -5 && grep -nE "flattenReasoningSummary|summary_text" Sources/CCRouterCore/IR/IRResponsesCodec.swift Sources/CCRouterCore/IR/IRAnthropicCodec.swift`
Expected: build 成功；grep 命中 helper 与 list shape emission。

⚠️ No test: Task 12 (ThinkingBlockEmissionTests) 新增一个 `@Test summary_listFlattenedOnDecodeListEmittedOnEncode`。
<!-- /section -->

---

<!-- section: task-4 keywords: ir-codec, thinking, encode, signature, omit -->
### Task 4: IRAnthropicCodec — 响应方向 thinking 块完整字段

**Crystal ref:** [D-004]

**Files:**
- Modify: `Sources/CCRouterCore/IR/IRAnthropicCodec.swift:103-109`（当前 `.thinking` case 只 emit summary）

**Steps:**

1. 替换 `encodeResponseBlock` 的 `case .thinking` 分支为：
   ```swift
   case .thinking(let encryptedContent, let summary):
       var fields: [String: JSONValue] = [
           "type": .string("thinking"),
           "thinking": .string(summary ?? ""),
       ]
       if let encryptedContent, !encryptedContent.isEmpty {
           fields["signature"] = .string(encryptedContent.base64EncodedString())
       }
       return JSONObject.from(fields)
   ```
2. 关键点：nil 或 empty 时**完全省略** `signature` 字段，不写 `""`（decode 方向对 nil / "" 统一降级为 nil）
3. 更新注释为 `// signature = base64(encrypted_content) for E-scheme roundtrip; omitted when nil so replay path naturally drops per [D-006]`

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -5 && grep -n "base64EncodedString" Sources/CCRouterCore/IR/IRAnthropicCodec.swift`
Expected: build 成功；grep 命中 encrypted_content 的 base64 编码。

⚠️ No test: Task 11 覆盖。
<!-- /section -->

---

<!-- section: task-5 keywords: payload, reasoning-summary, request-param -->
### Task 5: makeResponsesPayload — 添加 reasoning.summary: auto（不改 include）

**Crystal ref:** [D-002]

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:744-762`（`makeResponsesPayload` 函数）

**Steps:**

1. 当前第 744 行 `let reasoning = JSONObject(["effort": .string(route.reasoningEffort)])` 改为：
   ```swift
   let reasoning = JSONObject([
       "effort": .string(route.reasoningEffort),
       "summary": .string("auto"),
   ])
   ```
2. `include` 数组保持不变，仍为 `["reasoning.encrypted_content"]`（probe Row C 证明 reasoning.summary 不是合法 include 值）
3. 添加注释 `// reasoning.summary: auto triggers response.reasoning_summary_text.delta events; see docs/research/2026-04-22-image-wire-probe.md Row E/F`

**Verify:**
Run: `grep -nA 3 "effort.*route.reasoningEffort" Sources/CCRouterCore/AnthropicBridge.swift`
Expected: `summary: .string("auto")` 紧随 effort 出现。

⚠️ No test: Task 11 的 `@Test makeResponsesPayload_requestsReasoningSummaryAuto` 覆盖。
<!-- /section -->

---

<!-- section: task-6 keywords: sse-encoder, thinking-delta, signature-delta, streaming -->
### Task 6: AnthropicSSEEncoder — 新增 thinking_delta + signature_delta 流式方法

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicSSEEncoder.swift`

**Steps:**

1. 在现有 `emitThinkingBlock(encryptedContent:summary:)` 方法（atomic）之后，新增三个流式方法：

   ```swift
   /// Opens a new thinking content block (stream-friendly).
   /// Calls closeOpenBlock first, increments the index, emits content_block_start
   /// with an empty initial thinking content.
   func startThinkingBlock() async throws {
       try await closeOpenBlock()
       currentBlockIndex += 1
       let contentBlock = JSONObject.from([
           "type": .string("thinking"),
           "thinking": .string(""),
       ])
       try await send(event: "content_block_start", data: JSONObject.from([
           "type": .string("content_block_start"),
           "index": .number(Double(currentBlockIndex)),
           "content_block": .object(contentBlock),
       ]))
       currentBlockKind = .thinking
   }

   /// Emits a `content_block_delta` with `{type: "thinking_delta", thinking: <delta>}`.
   /// Caller must have opened a thinking block (via startThinkingBlock).
   func emitThinkingDelta(_ delta: String) async throws {
       try await send(event: "content_block_delta", data: JSONObject.from([
           "type": .string("content_block_delta"),
           "index": .number(Double(currentBlockIndex)),
           "delta": .object(JSONObject.from([
               "type": .string("thinking_delta"),
               "thinking": .string(delta),
           ])),
       ]))
   }

   /// Emits a `content_block_delta` with `{type: "signature_delta", signature: <base64>}`.
   /// Intended to be called once, right before closing the thinking block,
   /// after upstream provides encrypted_content in the reasoning item's output_item.done.
   func emitSignatureDelta(encryptedContent: Data) async throws {
       guard !encryptedContent.isEmpty else { return }
       try await send(event: "content_block_delta", data: JSONObject.from([
           "type": .string("content_block_delta"),
           "index": .number(Double(currentBlockIndex)),
           "delta": .object(JSONObject.from([
               "type": .string("signature_delta"),
               "signature": .string(encryptedContent.base64EncodedString()),
           ])),
       ]))
   }
   ```

2. `BlockKind` enum 已含 `.thinking`（`AnthropicSSEEncoder.swift:23`），无需扩展。`closeOpenBlock` 已用 `guard currentBlockKind != nil` 的通用检查，`.thinking` 会正确触发 content_block_stop
3. 保留 `emitThinkingBlock`（atomic 版本），用于纯 `output_item.done` 只有 `encrypted_content` 而没有 summary part 事件流的回退路径（如 effort/upstream 版本差异 — 不是当前证据里观察到的情况，但保留 fallback）

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -5 && grep -nE "startThinkingBlock|emitThinkingDelta|emitSignatureDelta" Sources/CCRouterCore/AnthropicSSEEncoder.swift`
Expected: build 成功；grep 命中三个方法定义。

⚠️ No test: Task 11 (ThinkingBlockEmissionTests) 通过 AnthropicSSEEncoder 的端到端 mock 覆盖。
<!-- /section -->

---

<!-- section: task-7 keywords: upstream-stream, reasoning-summary-events, processing -->
### Task 7: AnthropicBridge.processUpstreamStream — 处理 reasoning_summary_* 事件

**Depends on:** Task 6（新增的 encoder 方法）

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:366-424`（`processUpstreamStream` 的 `switch eventType` 块）

**Steps:**

1. 在 `processUpstreamStream` 方法顶部（`let outputIRBlocks = ...` 声明之后）新增本地状态变量：
   ```swift
   var inStreamingThinking = false
   ```

2. 在当前 `switch eventType` 的 `case "response.output_text.delta":` 之前，新增三个 case：
   ```swift
   case "response.reasoning_summary_part.added":
       try await encoder.startThinkingBlock()
       inStreamingThinking = true

   case "response.reasoning_summary_text.delta":
       if let delta = event.string("delta") {
           try await encoder.emitThinkingDelta(delta)
       }

   case "response.reasoning_summary_part.done":
       break
   ```

3. 修改 `case "response.output_item.done":` 内 `switch ir` 的 `.thinking` 分支。当前（`:409-410`）是：
   ```swift
   case .thinking(let enc, let sum):
       try await encoder.emitThinkingBlock(encryptedContent: enc, summary: sum)
   ```

   改为：
   ```swift
   case .thinking(let enc, let sum):
       if inStreamingThinking {
           // Already streamed summary via reasoning_summary_text.delta — just
           // emit signature_delta and close. `sum` here is the upstream-buffered
           // flattened summary; we don't re-emit it because deltas already did.
           if let enc, !enc.isEmpty {
               try await encoder.emitSignatureDelta(encryptedContent: enc)
           }
           try await encoder.closeOpenBlock()
           inStreamingThinking = false
       } else {
           // Fallback: no summary stream events observed (e.g., older upstream
           // or effort level where summary is not emitted).
           try await encoder.emitThinkingBlock(encryptedContent: enc, summary: sum)
       }
   ```

   This local-flag approach keeps `currentBlockKind` private to the encoder — no visibility change needed.

4. Update TraceLogger in this method: for the three new events, log event_type as-is via existing `"stage": .string("responses_in_event")` logging (no change needed — the `for try await event in stream` loop's logging catches all events).

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -5 && grep -nE "reasoning_summary_part|reasoning_summary_text|emitSignatureDelta" Sources/CCRouterCore/AnthropicBridge.swift`
Expected: build 成功；grep 命中新增 case + signature emission 调用。

⚠️ No test: Task 11 (ThinkingBlockEmissionTests) 用 mock upstream stream 覆盖事件序列。
<!-- /section -->

---

<!-- section: task-8 keywords: image, input-image, encode-input-items, mime-whitelist -->
### Task 8: IRResponsesCodec — `.image` 编码为 `input_image` data URL

**Crystal ref:** [D-001]

**Files:**
- Modify: `Sources/CCRouterCore/IR/IRResponsesCodec.swift:29-36`（Phase 1 占位实现）
- Delete: `Tests/CCRouterCoreTests/IRBlockConversionTests.swift:141-160`（`irImageInMessageContentFallsBackToPlaceholderText` 依赖 Phase 1 占位，必须与本 task 同步删除，否则全量测试会直接失败）

**Steps:**

1. 把 `encodeInputItems` 的 `case .image` 分支由占位文本替换为：
   ```swift
   case .image(let data, let mediaType):
       let whitelist = ["image/png", "image/jpeg", "image/webp", "image/gif"]
       guard whitelist.contains(mediaType) else {
           fputs("IRResponsesCodec.encodeInputItems: unsupported image media_type \(mediaType) dropped (supported: \(whitelist.joined(separator: \", \")))\n", stderr)
           return nil
       }
       let base64 = data.base64EncodedString()
       return JSONObject.from([
           "type": .string("input_image"),
           "image_url": .string("data:\(mediaType);base64,\(base64)"),
       ]).asJSONValue
   ```
2. 删除 "Phase 1 placeholder" 注释
3. 添加注释 `// wire shape verified: docs/research/2026-04-22-image-wire-probe.md Row A`
4. 删除 `Tests/CCRouterCoreTests/IRBlockConversionTests.swift` 中的整块 `@Test func irImageInMessageContentFallsBackToPlaceholderText() { ... }` 测试（`:141-160`）—— 该测试断言 Phase 1 placeholder 行为，新实现改为 `input_image` 后原断言必定失败。替代覆盖由 Task 11 (ImageBlockConversionTests) 中 `@Test encodeInputItems_imageWithPngMediaType_producesDataUrl` 提供

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -5 && grep -nE "input_image" Sources/CCRouterCore/IR/IRResponsesCodec.swift && ! grep -n "irImageInMessageContentFallsBackToPlaceholderText" Tests/CCRouterCoreTests/IRBlockConversionTests.swift`
Expected: build 成功；grep 命中 `input_image` 字段；老测试已删除（grep 不命中返回 1，用 `!` 反转）。

⚠️ No test: 新行为由 Task 11 (ImageBlockConversionTests) 覆盖。
<!-- /section -->

---

<!-- section: task-9 keywords: tool-result, image, split, function-call-output -->
### Task 9: IRResponsesCodec — tool_result 内 image 分裂为 function_call_output + synthetic user message

**Crystal ref:** [D-001]（延伸：用户 scope 补充的 MCP screenshot 路径）

**Depends on:** Task 8（单 block 图像编码共享 input_image wire shape）

**Files:**
- Modify: `Sources/CCRouterCore/IR/IRResponsesCodec.swift:97-109`（`encodeToolResultOutputs`）
- Modify: `Sources/CCRouterCore/IR/IRResponsesCodec.swift:167-173`（`stringifyToolResultContent`）

**Steps:**

1. 拆出新 helper：
   ```swift
   /// Splits a single tool_result block into /responses input items.
   ///
   /// Behavior:
   /// - If content is text-only: returns [function_call_output].
   /// - If content contains images: returns
   ///   [function_call_output(placeholder), synthetic user message with input_image items].
   ///
   /// Row D of the 2026-04-22 image wire probe confirmed upstream accepts this split.
   private static func splitToolResult(toolUseID: String, content: [IRBlock]) -> [JSONValue] {
       var textParts: [String] = []
       var imageParts: [JSONValue] = []
       for block in content {
           switch block {
           case .text(let s):
               textParts.append(s)
           case .image:
               // Delegate to encodeInputItems for single-block image encoding
               // so wire shape stays defined in one place.
               let encoded = encodeInputItems([IRMessage(role: "user", content: [block])])
               if let first = encoded.first,
                  let contentArray = first.objectValue?.array("content"),
                  let imagePart = contentArray.first {
                   imageParts.append(imagePart)
               }
           default:
               break   // nested tool_use/tool_result/thinking inside tool_result are ignored
           }
       }

       var result: [JSONValue] = []
       let outputString: String
       if imageParts.isEmpty {
           outputString = textParts.joined(separator: "\n")
       } else {
           let textPart = textParts.joined(separator: "\n")
           outputString = textPart.isEmpty
               ? "[image content follows in next user message]"
               : textPart + "\n\n[image content follows in next user message]"
       }
       result.append(JSONObject.from([
           "type": .string("function_call_output"),
           "call_id": .string(toolUseID),
           "output": .string(outputString),
       ]).asJSONValue)

       if !imageParts.isEmpty {
           result.append(JSONObject.from([
               "type": .string("message"),
               "role": .string("user"),
               "content": .array(imageParts),
           ]).asJSONValue)
       }
       return result
   }
   ```
2. 修改 `encodeToolResultOutputs` 使其调用新 helper：
   ```swift
   public static func encodeToolResultOutputs(_ blocks: [IRBlock]) -> [JSONValue] {
       blocks.flatMap { block -> [JSONValue] in
           guard case .toolResult(let toolUseID, let content) = block else {
               return []
           }
           return splitToolResult(toolUseID: toolUseID, content: content)
       }
   }
   ```
3. 删除旧的 `stringifyToolResultContent` 调用（`encodeToolResultOutputs` 不再使用它），但保留函数体本身以兼容可能的其他调用点（grep 确认无调用后可删除）
4. 添加注释引用 probe Row D

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -5 && grep -nE "splitToolResult|function_call_output" Sources/CCRouterCore/IR/IRResponsesCodec.swift`
Expected: build 成功；新 helper 与引用齐全。

⚠️ No test: Task 10 (ImageBlockConversionTests) 覆盖 tool_result with image 场景。
<!-- /section -->

---

<!-- section: task-10 keywords: full-history, encode, replay, interleave -->
### Task 10: IRResponsesCodec.encodeFullHistory — 历史 replay 时序合并

**Depends on:** Task 3（decode signature 上线后历史 thinking 才有 encrypted_content）、Task 8（image 编码）、Task 9（tool_result 分裂）

**Files:**
- Modify: `Sources/CCRouterCore/IR/IRResponsesCodec.swift`（新增 `encodeFullHistory`）
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:289`（`runInitialTurn` 内 `encodeInputItems` → `encodeFullHistory`）

**Steps:**

1. 在 `IRResponsesCodec` 中新增：
   ```swift
   /// Encodes an ordered list of IRMessages into /responses `input` items,
   /// preserving temporal order across message boundaries AND block boundaries
   /// within a message.
   ///
   /// Walk rules:
   /// - `.text` / `.image` in any role → buffer into current message's content
   /// - `.toolUse` in assistant role → flush buffer, emit top-level function_call
   /// - `.toolResult` in user role → flush buffer, emit function_call_output (+ optional synthetic image message)
   /// - `.thinking` in assistant role with non-empty encrypted_content → flush buffer, emit top-level reasoning
   /// - `.thinking` with nil/empty encrypted_content → drop per [D-006]
   /// - unexpected role/block combinations (e.g., tool_use in user role) → drop silently
   public static func encodeFullHistory(_ messages: [IRMessage]) -> [JSONValue] {
       var result: [JSONValue] = []
       for message in messages {
           var pendingContent: [JSONValue] = []

           func flushPending() {
               guard !pendingContent.isEmpty else { return }
               result.append(JSONObject.from([
                   "type": .string("message"),
                   "role": .string(message.role),
                   "content": .array(pendingContent),
               ]).asJSONValue)
               pendingContent.removeAll(keepingCapacity: true)
           }

           for block in message.content {
               switch block {
               case .text(let text):
                   pendingContent.append(JSONObject.from([
                       "type": .string("input_text"),
                       "text": .string(text),
                   ]).asJSONValue)
               case .image:
                   // Reuse encodeInputItems for single-block image encoding.
                   // Invariant: a single image block produces exactly one message
                   // item whose content array contains exactly one image part.
                   let encoded = encodeInputItems([IRMessage(role: message.role, content: [block])])
                   if let first = encoded.first,
                      let contentArray = first.objectValue?.array("content"),
                      let imagePart = contentArray.first {
                       pendingContent.append(imagePart)
                   }
               case .thinking(let encryptedContent, let summary):
                   guard message.role == "assistant" else { break }
                   guard let encryptedContent, !encryptedContent.isEmpty else { break }
                   flushPending()
                   // summary emitted as list of {type:summary_text, text:...} to match
                   // upstream real shape (probe Row F); see Task 3 Step 5.
                   let summaryList: [JSONValue]
                   if let summary, !summary.isEmpty {
                       summaryList = [.object(JSONObject.from([
                           "type": .string("summary_text"),
                           "text": .string(summary),
                       ]))]
                   } else {
                       summaryList = []
                   }
                   result.append(JSONObject.from([
                       "type": .string("reasoning"),
                       "encrypted_content": .string(encryptedContent.base64EncodedString()),
                       "summary": .array(summaryList),
                   ]).asJSONValue)
               case .toolUse(let id, let name, let input):
                   guard message.role == "assistant" else { break }
                   flushPending()
                   let argsString: String
                   if let data = try? JSONEncoder().encode(input),
                      let s = String(data: data, encoding: .utf8) {
                       argsString = s
                   } else {
                       argsString = "{}"
                   }
                   result.append(JSONObject.from([
                       "type": .string("function_call"),
                       "call_id": .string(id),
                       "name": .string(name),
                       "arguments": .string(argsString),
                   ]).asJSONValue)
               case .toolResult(let toolUseID, let content):
                   guard message.role == "user" else { break }
                   flushPending()
                   let outputs = encodeToolResultOutputs([.toolResult(toolUseID: toolUseID, content: content)])
                   result.append(contentsOf: outputs)
               case .serverToolUse, .advisorToolResult:
                   // Bridge-synthesized only; should not appear in client request history.
                   break
               }
           }
           flushPending()
       }
       return result
   }
   ```
2. 保留 `encodeInputItems`（Task 10 的 image 分支复用它）。不标记 deprecated，因为它是细粒度工具
3. 修改 `AnthropicBridge.runInitialTurn`（当前 `:289` 的 `let input = IRResponsesCodec.encodeInputItems(requestIR)`）：
   ```swift
   let input = IRResponsesCodec.encodeFullHistory(requestIR)
   ```
   同步复核现有集成测试：`ModelRoutingBridgeIntegrationTests`、`StreamingBridgeIntegrationTests`、`BridgeRegressionTests` 里若断言了 initial turn 仍走旧的 `encodeInputItems` shape，需要改成 `encodeFullHistory` 的新预期。
4. `runStreamingTurn` 的 pending-tool-turn continuation 分支（`:192` 的 `encodeReplayBlocks + encodeToolResultOutputs`）保持不变。continuation 是 turn 内的 replay，不走 full history 路径
5. 添加注释：`// encodeFullHistory preserves temporal order; see Phase 3 plan Task 10`
6. 在 `.image` 分支上方加注释：`// Single-block image encoding is delegated to encodeInputItems to keep wire shape defined in one place (Task 8). Changes to image shape must update only encodeInputItems.`
7. 切换到 `encodeFullHistory` 后，runInitialTurn 的 input 项组成从"纯 message items"变为"message + 顶层 reasoning/function_call/function_call_output 混合"。确认以下既有集成测试是否断言旧 shape，若断言则需同步更新：
   - `Tests/CCRouterCoreTests/StreamingBridgeIntegrationTests.swift`
   - `Tests/CCRouterCoreTests/ModelRoutingBridgeIntegrationTests.swift`
   - `Tests/CCRouterCoreTests/BridgeRegressionTests.swift`
   
   做法：跑 `grep -nE "encodeInputItems|input_item_types" Tests/CCRouterCoreTests/*.swift`，检查每处断言。若断言的是 generic 场景（无历史 tool_use/thinking）则 `encodeFullHistory` 输出与 `encodeInputItems` 一致，不用改。若断言具体 item 数或顺序则需按新逻辑更新

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild 2>&1 | tail -5 && grep -nE "encodeFullHistory" Sources/CCRouterCore/IR/IRResponsesCodec.swift Sources/CCRouterCore/AnthropicBridge.swift`
Expected: build 成功；函数定义 1 处 + 调用点 1 处。

⚠️ No test: Task 13 (ToolUseHistoryReplayTests) 覆盖各种 interleaving 组合。
<!-- /section -->

---

<!-- section: task-11 keywords: tests, image-block-conversion, image -->
### Task 11: Tests — ImageBlockConversionTests

**Depends on:** Task 8, Task 9, Task 10

**Files:**
- Create: `Tests/CCRouterCoreTests/ImageBlockConversionTests.swift`

**Steps:**

用 Swift Testing (`@Test`/`#expect`) 覆盖：

1. `@Test decodeRequestBlocks_imageBlock_returnsIRImage`：Anthropic `{type:"image", source:{type:"base64", media_type:"image/png", data:"<valid base64>"}}` → `.image(data, "image/png")`
2. `@Test decodeRequestBlocks_imageBlock_invalidBase64_returnsNil`：data 非合法 base64 → 块被丢弃（整条 blocks 列表不含）
3. `@Test decodeRequestBlocks_imageBlock_missingMediaType_returnsNil`：source 缺 media_type → 丢弃
4. `@Test encodeInputItems_imageWithPngMediaType_producesDataUrl`：`.image(data, "image/png")` → `{type: "input_image", image_url: "data:image/png;base64,<base64>"}`
5. `@Test encodeInputItems_imageWithUnsupportedMediaType_returnsNil`：`image/tiff` 不在白名单 → nil
6. `@Test encodeFullHistory_userMessageWithTextAndImage_producesSingleMessageWithBothParts`：user `[text, image]` → 单 message item 的 content 含 input_text + input_image
7. `@Test encodeFullHistory_toolResultWithImageContent_producesFunctionCallOutputAndUserMessage`：user `[tool_result(content: [text, image])]` → 2 items：function_call_output（output 含 "image follows" 标记）+ 后续 user message with input_image
8. `@Test encodeFullHistory_toolResultWithTextOnly_producesSingleFunctionCallOutput`：user `[tool_result(content: [text])]` → 1 item function_call_output，无后续 user message

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ImageBlockConversionTests 2>&1 | tail -10`
Expected: 8 个 `@Test` 全绿。
<!-- /section -->

---

<!-- section: task-12 keywords: tests, thinking-emission, signature, streaming, mock -->
### Task 12: Tests — ThinkingBlockEmissionTests

**Depends on:** Task 3, Task 4, Task 5, Task 6, Task 7

**Files:**
- Create: `Tests/CCRouterCoreTests/ThinkingBlockEmissionTests.swift`

**Steps:**

用 Swift Testing 覆盖：

1. `@Test encodeResponseBlock_thinkingWithEncryptedContent_emitsSignature`：`.thinking(Data("test-bytes".utf8), "summary")` → `{type: "thinking", thinking: "summary", signature: "dGVzdC1ieXRlcw=="}`
2. `@Test encodeResponseBlock_thinkingWithNilEncryptedContent_omitsSignature`：`.thinking(nil, "summary")` 输出 object 不含 signature 字段
3. `@Test encodeResponseBlock_thinkingWithEmptyEncryptedContent_omitsSignature`：`.thinking(Data(), "summary")` 同上
4. `@Test decodeRequestBlocks_thinkingWithSignature_decodesToEncryptedContent`：`{type:"thinking", thinking:"s", signature:"dGVzdA=="}` → `.thinking(Data("test".utf8), "s")`
5. `@Test decodeRequestBlocks_thinkingWithoutSignature_producesNilEncryptedContent`：无 signature → `.thinking(nil, "s")`
6. `@Test decodeRequestBlocks_thinkingInvalidSignatureBase64_producesNilEncryptedContent`：`signature: "not-base64!@#"` → encryptedContent=nil
7. `@Test roundtrip_encryptedContentPreservedThroughEncodeDecode`：256 字节随机 Data → encode → 把输出当 Anthropic 请求 → decode → 字节完全一致
8. `@Test makeResponsesPayload_requestsReasoningSummaryAuto`：`makeResponsesPayload(...)` 的 `reasoning` 子对象含 `summary: "auto"`
9. `@Test makeResponsesPayload_includesOnlyEncryptedContent`：`include` 数组仅含 `reasoning.encrypted_content`（不含 reasoning.summary —— 上游明确拒绝，回归保护）
10. `@Test processUpstreamStream_summaryDeltaEvents_streamedAsThinkingDeltas`：构造 mock upstream event 序列 `[reasoning_summary_part.added, reasoning_summary_text.delta("A"), reasoning_summary_text.delta("B"), reasoning_summary_part.done, output_item.done(reasoning with encrypted_content)]`；assert 写入 CLI writer 的 SSE 文本依序含：`content_block_start` (type=thinking) → `content_block_delta` (thinking_delta "A") → `content_block_delta` (thinking_delta "B") → `content_block_delta` (signature_delta with base64) → `content_block_stop`
11. `@Test processUpstreamStream_reasoningItemWithoutSummaryStream_fallsBackToAtomic`：upstream 只发 `output_item.done` 不发 summary part 事件（模拟上游未支持 summary:auto 的版本）→ atomic emitThinkingBlock 路径被走
12. `@Test thinkingEnabledRequestField_doesNotOverrideRoute`（Decision C 验证）：带 `thinking: {type: "enabled", budget_tokens: 10000}` 的请求 → payload 的 `reasoning.effort` 与不带该字段时一致（来自 routing table 的 fallback route）
13. `@Test decodeOutputItem_reasoningWithSummaryAsList_flattensToString`：upstream reasoning item `summary: [{"type":"summary_text","text":"A"},{"type":"summary_text","text":"B"}]` → `.thinking(_, summary: "A\n\nB")`
14. `@Test decodeOutputItem_reasoningWithSummaryAsString_passesThrough`：upstream 发 legacy plain string `summary: "hello"` → `.thinking(_, summary: "hello")`（向后兼容）
15. `@Test decodeOutputItem_reasoningWithEmptySummaryList_returnsNilSummary`：`summary: []` → `.thinking(_, summary: nil)`
16. `@Test encodeReplayBlocks_emitsSummaryAsSingleElementList`：`.thinking(data, "hello")` → reasoning item 的 `summary` 字段是 `[{"type":"summary_text","text":"hello"}]`，不是 plain string（probe 证据显示上游真实 shape 是 list）
17. `@Test encodeReplayBlocks_emptySummary_emitsEmptyList`：`.thinking(data, nil)` → reasoning item 的 `summary` 字段是 `[]`

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ThinkingBlockEmissionTests 2>&1 | tail -10`
Expected: 17 个 `@Test` 全绿。

Note: Tests 10/11 需要构造 mock `AsyncThrowingStream<JSONObject, Error>` + mock writer，参考现有 `StreamingBridgeIntegrationTests.swift` 与 `MockResponsesEventStream.swift` 的模式。
<!-- /section -->

---

<!-- section: task-13 keywords: tests, history-replay, tool-use-replay, interleave -->
### Task 13: Tests — ToolUseHistoryReplayTests

**Depends on:** Task 10

**Files:**
- Create: `Tests/CCRouterCoreTests/ToolUseHistoryReplayTests.swift`

**Steps:**

用 Swift Testing 覆盖：

1. `@Test encodeFullHistory_assistantTextOnly_producesMessageItem`：baseline sanity
2. `@Test encodeFullHistory_assistantToolUseOnly_producesFunctionCall`：单 tool_use → function_call
3. `@Test encodeFullHistory_assistantTextAndToolUse_producesMessageThenFunctionCall`：`[text, tool_use]` → message + function_call 按序
4. `@Test encodeFullHistory_assistantThinkingTextToolUse_producesReasoningThenMessageThenFunctionCall`：`[thinking(encryptedContent=non-nil), text, tool_use]` → 3 items 按序（**interleaving 核心测试**）
5. `@Test encodeFullHistory_assistantThinkingWithNilEncryptedContent_isDropped`：`.thinking(nil, "orphan")` → 无 reasoning item 产出（[D-006]）
6. `@Test encodeFullHistory_userToolResult_producesFunctionCallOutput`：user `[tool_result]` → function_call_output
7. `@Test encodeFullHistory_userMultipleToolResults_producesMultipleOutputs`：user `[tool_result_a, tool_result_b]` → 2 个 function_call_output
8. `@Test encodeFullHistory_multiTurnConversation_ordersItemsAcrossMessages`：`[user{text}, assistant{thinking, text, tool_use}, user{tool_result}, assistant{text}]` → 6 items 按序
9. `@Test encodeFullHistory_thinkingInUserRole_isDropped`：user message 含 thinking 块 → 丢弃（role 不符）
10. `@Test encodeFullHistory_toolUseInUserRole_isDropped`：user message 含 tool_use 块 → 丢弃
11. `@Test encodeFullHistory_preservesMessageRole`：user text + assistant text → 两个 message items 分别 role=user / role=assistant
12. `@Test encodeFullHistory_emptyMessageList_producesEmptyInput`：`[]` → `[]`
13. `@Test encodeFullHistory_assistantThinking_emitsSummaryAsList`：`.thinking(Data(x), "hello")` in assistant message → reasoning item 的 `summary` 字段是 `[{type:"summary_text", text:"hello"}]` 列表，不是 plain string（regression 保护 Task 10 与 Task 3 的 shape 一致性）

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ToolUseHistoryReplayTests 2>&1 | tail -10`
Expected: 13 个 `@Test` 全绿。
<!-- /section -->

---

<!-- section: task-14 keywords: docs, changelog, phase-3 -->
### Task 14: 文档 — Phase 3 changelog

**Files:**
- Create: `docs/07-changelog/2026-04-22-phase3-protocol-completeness.md`

**Steps:**

创建 changelog，至少含以下段落：

1. **Summary**：Phase 3 交付的三类协议完备性修复（3a 图像 / 3b thinking surface + streaming / 3c 历史 replay）
2. **Scheme E 机制**：encrypted_content ↔ signature base64 roundtrip；probe 证据引用
3. **新增 SSE 事件处理**：`response.reasoning_summary_part.added` / `reasoning_summary_text.delta` / `reasoning_summary_part.done`
4. **变更文件清单**：
   - Core: `IRAnthropicCodec.swift`, `IRResponsesCodec.swift`, `AnthropicBridge.swift`, `AnthropicSSEEncoder.swift`
   - Tests: `ImageBlockConversionTests.swift`, `ThinkingBlockEmissionTests.swift`, `ToolUseHistoryReplayTests.swift`
   - Probes: `scripts/probe_image_wire.py`
   - Research: `docs/research/2026-04-22-image-wire-probe.md`, `docs/research/2026-04-22-cli-signature-passthrough.md`
5. **已知限制**：老会话（pre-Phase-3）续轮时 thinking 块无 signature → 走 [D-006] 静默丢弃；thinking summary 依赖上游 `reasoning.summary: auto` 支持（当前已验证 gpt-5.4 支持）
6. **下一步**：Phase 4（session state 稳定性 + prompt cache key + pendingToolTurn TTL）

**Verify:**
Run: `test -f docs/07-changelog/2026-04-22-phase3-protocol-completeness.md && grep -E "Scheme E|signature_delta|thinking_delta" docs/07-changelog/2026-04-22-phase3-protocol-completeness.md`
Expected: 文件存在，关键词齐全。

⚠️ No test: 纯文档。
<!-- /section -->

---

## Decisions

None. 所有设计假设已被 `docs/research/2026-04-22-image-wire-probe.md` 的证据解决：

- Image wire shape：`input_image` data URL（Row A verified）
- Tool_result image 路径：split into function_call_output + synthetic user message（Row D verified）
- Thinking summary：`reasoning.summary: "auto"` request 参数（Row E/F verified）+ 新 SSE 事件流
- encrypted_content + summary 同时工作：Row F verified（1636 字节 encrypted_content + 96 summary deltas）
- CLI signature passthrough：Task 2 源码检查；失败走 [D-006] 降级（不阻塞 Phase 3 交付）

---

## Out of Scope (documented for reviewer's awareness)

- 不实现 pre-Phase-3 老会话的 thinking 块重建（走 [D-006] 静默丢弃）
- 不重构 `AnthropicSSEEncoder` 的 open/close block 机制（沿用 Phase 1）
- 不新增 thinking 配置项（Decision C：`thinking.enabled` 不影响路由）
- 不改 `runAdvisorSubcall` 的 advisor 调用（Phase 4 范围）
- 不改 prompt_cache_key 策略（Phase 4 范围）
- `reasoning.summary: "concise"` 选项在当前 probe 下 summary 未出现（probe 记录在案但不采用）— 我们选 `"auto"`，上游实测会升级到 `"detailed"`

---
## Verification
- **Verdict:** Approved (after 2 revision cycles)
- **Date:** 2026-04-22
- **Cycle 1 report:** .claude/reviews/plan-verifier-2026-04-22-192406.md — 4 must-revise resolved
- **Cycle 2 report:** .claude/reviews/plan-verifier-2026-04-22-193202.md — 1 must-revise (Task 10 snippet shape inconsistency with Task 3 Step 5) + 2 advisories (image invariant inline comment, integration test audit note) all resolved inline; fix was characterized by verifier as mechanical snippet correction with no decisions.
