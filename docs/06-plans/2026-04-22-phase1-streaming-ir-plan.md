---
type: plan
status: active
tags: [streaming, typed-ir, sse, chunked-transfer, anthropic-bridge]
refs:
  - docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
  - docs/scheme3/08-responses-http-contract.md
  - docs/scheme3/09-real-upstream-capture.md
  - docs/scheme3/16-request-shape-comparison-v1.md
  - docs/scheme3/01-validated-baseline.md
---

# Phase 1: 真流式通路 + Typed IR 基础 Implementation Plan

**Goal:** 上游每一个 `/responses` SSE event 逐个流向 Claude Code CLI；content blocks 从 ad-hoc `JSONObject` 迁移到 typed IR。

**Architecture:** 三层拆解：(a) 新 `Sources/CCRouterCore/IR/` 目录承载 typed IR 与双向 JSON 编解码器，边缘翻译用 IR 驱动；(b) `ResponsesClient` 新增 `AsyncThrowingStream<JSONObject, Error>` streaming API（基于 `URLSession.bytes(for:)`）；既有 `perform` 重构为 `streamEvents` 的 API 兼容 shim（reduce 成数组），不再是独立 HTTP 路径；(c) `LocalHTTPServer.HTTPResponse.body` 扩成 `.data | .stream` 两态，chunked transfer encoding 写出 streaming body，非 streaming callsite（health / count_tokens / 错误）通过 convenience init 保留 wire 不变。`AnthropicBridge.handleMessages` 改为 per-event 翻译：上游每到一个 IR-decoded event 立即合成 Anthropic SSE 帧写回；advisor 子 call 与 tool-use 续轮在 streaming emitter 之上叠加状态机。

**Tech Stack:** Swift 6.2（actor 并发）、Foundation `URLSession.bytes(for:)`、Network `NWConnection`（现有）、Swift Testing。

**Design doc:** `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md`（Phase 1 章节 + DP-003/DP-004 resolved chosen=A）

**Design analysis:** none（本次重构无独立 design-analysis；事实基线直接溯源到 `docs/scheme3/` 与 `file:line`）

**Crystal file:** none（Phase 1 无新增视觉/交互决策，dev-guide `confirmed_at: 2026-04-22T09:17:32` 为 scope 基线）

**Threat model:** not applicable（Phase 1 不引入新认证/沙箱/权限/加密边界；所有改动都在既有 authorized `/v1/messages` → 已认证 `/responses` 通路内部）

---

## Scope & Constraints Recap

来自 dev-guide Phase 1 的 scope 条目（用于每个 task 自检是否偏离）：

- S1: `ResponsesClient.perform` 从整包下载切到 `URLSession.bytes(for:)` + AsyncSequence 逐行解析
- S2: `LocalHTTPServer` 增加 chunked transfer 写出能力，保留 Content-Length 退化分支
- S3: `AnthropicBridge.handleMessages` 改 streaming handler：上游 event → 翻译 → 立即写回本地 SSE
- S4: 新增 `Sources/CCRouterCore/IR/` 目录；`IRBlock` enum 至少含 `.text` / `.image(data, mediaType)` / `.toolUse(id, name, input)` / `.toolResult(id, content:[IRBlock])` / `.thinking(encryptedContent, summary)` / `.serverToolUse` / `.advisorToolResult`
- S5: `convertContentBlocks` / `stringifyToolResultContent` 改由 IR 层驱动，保留 text-only 行为
- S6: `PendingToolTurn` 从 `[JSONValue]` replay items 重构为 IR-native

**DP-003 chosen:** A（chunked transfer encoding + `Connection: close`）。若 streaming 集成测试下 Claude CLI 接受性失败，本 phase 内回退到 B（close-delimited）；不升级为 persistent keep-alive。
**DP-004 chosen:** A（全面 IR）。JSONObject 仅保留在 Anthropic 入口 decode 与 `/responses` 出口 encode 的 protocol edge；核心翻译流水只碰 IR。

**Phase 1 scope 明确排除**（Phase 3/5 才做）：
- `.image` IR 到 `/responses` wire 的真实 `input_image` / `image_url` 字段形态 → Phase 3a probe 才验证；Phase 1 内 image 在 encode 到 `/responses` input 时降级为文本占位（见 Task 1 Step 4）
- `.thinking` 的 encrypted_content 回传到 Anthropic wire 的 `signature` 字段 → Phase 3b 才做；Phase 1 encode 只输出 `thinking: summary`
- count_tokens 精度改造 → Phase 5

**已验证必须保留的 SSE 事件形状**（来自 `docs/scheme3/08 §4.2` + `§4.3` + `docs/scheme3/09 §4`，Phase 1 streaming emitter 必须在任一事件缺席时仍输出相同 Anthropic SSE 帧序列）：

上游（只列 Phase 1 会消费的 stream 类型）：
- `response.created` / `response.in_progress`
- `response.output_item.added`（`item.type ∈ {message, function_call, reasoning}`）
- `response.content_part.added`
- `response.output_text.delta`（真正的字符级 delta，Phase 1 的首字节指标来源）
- `response.output_text.done`
- `response.content_part.done`
- `response.output_item.done`
- `response.completed`（含 `usage.input_tokens` / `usage.output_tokens`）

本地出口（必须对 Claude CLI 保持 wire 兼容）：
- `message_start` → `content_block_start` → `content_block_delta`(×N) → `content_block_stop` → (重复 per block) → `message_delta` → `message_stop`

---

<!-- section: task-1 keywords: ir, json, codec, content-blocks -->
### Task 1: IR Foundation（types + 双向 JSON codec）

**Files:**
- Create: `Sources/CCRouterCore/IR/IRBlock.swift`
- Create: `Sources/CCRouterCore/IR/IRMessage.swift`
- Create: `Sources/CCRouterCore/IR/IRAnthropicCodec.swift`
- Create: `Sources/CCRouterCore/IR/IRResponsesCodec.swift`

**Steps:**

1. `IRBlock.swift` 定义 enum（exhaustive — 不含 `.unknown`，decoder 对未识别 type 返回 `nil` 由调用方决定丢弃还是报错）：

```swift
public enum IRBlock: Sendable, Equatable {
    case text(String)
    case image(data: Data, mediaType: String)
    case toolUse(id: String, name: String, input: JSONObject)
    case toolResult(toolUseID: String, content: [IRBlock])
    case thinking(encryptedContent: Data?, summary: String?)
    case serverToolUse(id: String, name: String, input: JSONObject)
    case advisorToolResult(toolUseID: String, text: String)
}
```

2. `IRMessage.swift`：

```swift
public struct IRMessage: Sendable, Equatable {
    public let role: String   // "user" | "assistant" | "system"
    public let content: [IRBlock]
}
```

3. `IRAnthropicCodec.swift` 暴露两个方向：

**Decoders（从 Anthropic wire）：**
   - `decodeRequestBlocks(_ blocks: [JSONObject]) -> [IRBlock]`：识别 Anthropic wire `type ∈ {text, image, tool_use, tool_result, thinking}`；未识别 type 返回 `nil`（跳过，不 throw）。每个 case 的具体映射：
     - `text` → `.text(text)`
     - `image`：`image.source.type == "base64"` 时 base64 解码 `source.data` 到 `Data`（用 `Data(base64Encoded:)`；解码失败则跳过），`source.media_type` 写入 `mediaType`；非 base64 source 暂不支持，返回 nil
     - `tool_use` → `.toolUse(id: block.string("id")!, name: block.string("name")!, input: block.object("input") ?? JSONObject())`
     - `tool_result`：`tool_use_id` 必需。对 `content` 字段：
       - 若 `content` 是 `string` 形态：包装成 `.toolResult(toolUseID:, content: [.text(stringValue)])`
       - 若 `content` 是 `array` 形态：对每个内层 block 调用 `decodeRequestBlocks` 递归（内层 block 只允许 text / image；其他 type 跳过）
       - 若 `content` 为 null / 缺失：`content: []`
     - `thinking` → `.thinking(encryptedContent: nil, summary: block.string("thinking"))`（Anthropic 侧 thinking block 只是 plaintext summary，encrypted_content 只在 `/responses` reasoning item 有，对 Anthropic 入口永远 nil）

**Encoders（到 Anthropic wire，供 `content_block_start` 的 `content_block` 字段）：**
   - `encodeResponseBlock(_ ir: IRBlock) -> JSONObject?`（单 block 版，方便 SSE emitter per-block 调用）：
     - `.text(text)` → `{type:"text", text: text}`
     - `.toolUse(id, name, input)` → `{type:"tool_use", id, name, input}`
     - `.serverToolUse(id, name, input)` → `{type:"server_tool_use", id, name, input}`
     - `.advisorToolResult(toolUseID, text)` → `{type:"advisor_tool_result", tool_use_id: toolUseID, content: {type:"advisor_result", text: text}}`（保持与原 `makeAdvisorSSE` 第 478-489 行一致形状）
     - `.thinking(encryptedContent, summary)` → **Phase 1 内**：`{type:"thinking", thinking: summary ?? ""}`（ 不输出 `signature` 字段；encrypted_content 回写到 Anthropic wire 的 `signature` 属于 Phase 3b scope，本 phase 只让 CLI 看到可见的 summary 文本）
     - `.image / .toolResult` → Phase 1 SSE emitter 不会 emit 这两类（它们只在 request decode 侧出现），返回 `nil`；若后续调用方 Phase 1 意外传入 log warning（用 `fputs(... stderr)`），返回 nil

4. `IRResponsesCodec.swift` 暴露四个方向（**新增 `encodeReplayBlocks` 专门处理 top-level item 形态**）：

   - `encodeInputItems(_ messages: [IRMessage]) -> [JSONValue]`：把 IR message 转成 `/responses` 的 `input` array，**只处理 message-嵌套内容**（text / image / thinking placeholder）；`.toolUse` / `.toolResult` 不在 message.content 里（它们在 /responses 是独立 top-level item），遇到直接跳过并 log warning（调用方应先用 `encodeReplayBlocks` 拿出这些 top-level item）。具体 mapping：
     - `IRMessage(role:, content: [IRBlock])` → `{type:"message", role, content: [...]}`，content 数组元素：
       - `.text(text)` → `{type:"input_text", text}`
       - `.image(data, mediaType)` → **Phase 1 降级**：`{type:"input_text", text: "[image: mediaType=\(mediaType), bytes=\(data.count), content withheld until Phase 3a verifies input_image wire shape]"}` — 不 pin 未验证的 `input_image / image_url` 字段；Phase 3a probe 完成后再切换到真 wire（届时本函数改签名/行为）
       - `.thinking` → 跳过（message-level thinking 只在 Anthropic 入口侧出现；在 `/responses` input 用 reasoning top-level item，由 `encodeReplayBlocks` 处理）
       - 其他（`.toolUse / .toolResult / .serverToolUse / .advisorToolResult`）→ 跳过，调用方必须用 `encodeReplayBlocks`

   - `encodeReplayBlocks(_ blocks: [IRBlock]) -> [JSONValue]`：**新增**。专门把 reasoning / function_call 类 top-level IR block 编码为 `/responses` input 的 top-level item（不包在 message 里）。过滤规则 + mapping：
     - `.thinking(encryptedContent, summary)` → `{type:"reasoning", encrypted_content: encryptedContent?.base64EncodedString() ?? "", summary: summary ?? ""}`（保持 `docs/scheme3/09 §4.2` 真实上游 reasoning item 的字段形状；续轮必须回放 reasoning 是 `§3.13` 已验证条件）
     - `.toolUse(id, name, input)` → `{type:"function_call", call_id: id, name, arguments: encodedInputJSON}`（其中 `encodedInputJSON` 是 `JSONEncoder().encode(input)` 的 utf8 字符串表达）
     - 其他 case（`.text / .image / .toolResult / .serverToolUse / .advisorToolResult`）→ 跳过（这些不是 /responses top-level item 类别）

   - `encodeToolResultOutputs(_ blocks: [IRBlock]) -> [JSONValue]`：**新增**。从 Anthropic 续轮 request 的 user message content 里（已解码为 IR）提取 `.toolResult`，逐个转为 `/responses` `function_call_output` item：
     - `.toolResult(toolUseID, content)` → `{type:"function_call_output", call_id: toolUseID, output: stringifiedContent}`，其中 `stringifiedContent` 规则：
       - 若 content 是 `[.text(str)]` 单元素 → `str`
       - 若 content 是多个 `.text` → `content.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined(separator: "\n")`
       - 若 content 含 `.image` → Phase 1 fallback：image 不进 output 字符串，只保留 text（Phase 3a scope 才真实 forward image）
       - 若 content 为空 → `""`
     - 非 `.toolResult` 跳过

   - `decodeOutputItem(_ item: JSONObject) -> IRBlock?`：识别 `item.type ∈ {message, function_call, reasoning}`；未识别返回 `nil`。具体：
     - `message`：找 `content[*]` 中 `type ∈ {output_text, text}` 的第一个 → `.text(part.string("text") ?? "")`；若有多个 text part 则 join；若 content 为空返回 `.text("")`
     - `function_call` → `.toolUse(id: item.string("call_id")!, name: item.string("name")!, input: decodeArgumentsJSON(item.string("arguments") ?? "{}"))`
       - `decodeArgumentsJSON(_ str: String) -> JSONObject` 内部：`str` 为 empty / 非法 JSON → 返回 `JSONObject()`；合法 JSON object → 解码；合法但非 object (数组/原子) → 返回 `JSONObject()`
     - `reasoning` → `.thinking(encryptedContent: Data(base64Encoded: item.string("encrypted_content") ?? ""), summary: item.string("summary"))`（base64 decode 失败返回 nil data）

5. 所有四个新文件的 public 类型加 `public`；internal 辅助加 `internal` 默认可见度。decoder 不 throw（返回 optional 或丢空数组），encoder 确定性生成固定字段集合。

**Design ref:** dev-guide Phase 1 §Scope 第 4 条；DP-004 chosen=A
**Data flow:** Anthropic JSON ↔ IR ↔ /responses JSON
**Quality markers:** `IRBlock` 是纯 enum（无引用类型内部状态）；codec 文件不出现 `AnthropicBridge.` / `GatewayDaemon.` 等具体 actor 引用（避免循环），只依赖 `JSONObject` / `JSONValue` / Foundation

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild --target CCRouterCore`
Expected: `Build complete!`（无 compile error；IR 是新文件，不会触及既有 AnthropicBridge 代码路径）

Run: `grep -RE '^public (enum|struct|func) ' Sources/CCRouterCore/IR/ | wc -l`
Expected: ≥ 10（IRBlock enum + IRMessage struct + 至少 6 个 public func: decodeRequestBlocks / encodeResponseBlock / encodeInputItems / encodeReplayBlocks / encodeToolResultOutputs / decodeOutputItem）
<!-- /section -->

<!-- section: task-2 keywords: ir, round-trip, testing, codec -->
### Task 2: IR 双向 round-trip 测试

**Files:**
- Create: `Tests/CCRouterCoreTests/IRBlockConversionTests.swift`

**Steps:**

1. `import Testing` + `@testable import CCRouterCore` + `import Foundation`

2. 至少覆盖 dev-guide acceptance criteria 列出的三方向：

   **方向 A — Anthropic request blocks → IR：**
   - `@Test func anthropicTextBlockDecodesToIRText()`：给 `[{type:"text", text:"hello"}]`，`decodeRequestBlocks` 返回 `[.text("hello")]`
   - `@Test func anthropicImageBase64DecodesToIRImage()`：给 `{type:"image", source:{type:"base64", media_type:"image/png", data:<base64 of 4 bytes>}}`，decode 后 `.image(data, mediaType)` 的 `data.count == 4`，`mediaType == "image/png"`
   - `@Test func anthropicToolUseDecodesToIRToolUse()`：给 `{type:"tool_use", id:"toolu_1", name:"Bash", input:{command:"true"}}`，decode 返回 `.toolUse(id:"toolu_1", name:"Bash", input:{command:"true"})`
   - `@Test func anthropicToolResultWithArrayContentDecodesToIRToolResult()`：给 `{type:"tool_result", tool_use_id:"toolu_1", content:[{type:"text", text:"ok"}]}`，decode 返回 `.toolResult(toolUseID:"toolu_1", content:[.text("ok")])`
   - **`@Test func anthropicToolResultWithStringContentDecodesToIRToolResultWithSingleText()`**（新增）：给 `{type:"tool_result", tool_use_id:"toolu_1", content:"plain string"}`，decode 返回 `.toolResult(toolUseID:"toolu_1", content:[.text("plain string")])`
   - `@Test func anthropicThinkingBlockDecodesToIRThinking()`：给 `{type:"thinking", thinking:"reasoning text"}`，decode 返回 `.thinking(encryptedContent: nil, summary: "reasoning text")`
   - `@Test func unknownBlockTypeIsDropped()`：给 `{type:"custom_foo"}`，decode 返回 empty array

   **方向 B — IR → /responses input items：**
   - `@Test func irUserTextBecomesInputTextItem()`：给 `IRMessage(role:"user", content:[.text("hi")])`，encode 后第 0 项 JSON 是 `{type:"message", role:"user", content:[{type:"input_text", text:"hi"}]}`
   - **`@Test func irImageInMessageContentFallsBackToPlaceholderText()`**（替换原 `irImageBecomesInputImageItem`）：给 `IRMessage(role:"user", content:[.image(data: bytes4, mediaType: "image/png")])`，`encodeInputItems` 产出 message 的 content 数组里含 `{type:"input_text", text: <包含 "image" 和 "image/png" 的占位字符串>}`。**断言 wire 里不出现 `input_image` / `image_url` 字段**（Phase 3a 才 pin 真实 wire）。
   - **`@Test func irToolUseEncodedViaEncodeReplayBlocks()`**（用新增 `encodeReplayBlocks`）：给 `[IRBlock.toolUse(id:"toolu_1", name:"Bash", input:JSONObject(["command":.string("true")]))]`，encode 产出 **独立** `{type:"function_call", call_id:"toolu_1", name:"Bash", arguments:"{\"command\":\"true\"}"}` item
   - **`@Test func irThinkingEncodedViaEncodeReplayBlocks()`**（新增）：给 `[IRBlock.thinking(encryptedContent: Data([0x01,0x02]), summary: "thought")]`，encode 产出 `{type:"reasoning", encrypted_content: "<base64 of 0x0102>", summary: "thought"}` item
   - **`@Test func irToolResultEncodedViaEncodeToolResultOutputs()`**（用新增 `encodeToolResultOutputs`）：给 `[IRBlock.toolResult(toolUseID:"toolu_1", content:[.text("ok")])]`，encode 产出 `{type:"function_call_output", call_id:"toolu_1", output:"ok"}` item

   **方向 C — /responses output item → IR → Anthropic wire shape：**
   - `@Test func responsesMessageItemDecodesToIRText()`：给 `{type:"message", content:[{type:"output_text", text:"reply"}]}`，`decodeOutputItem` 返回 `.text("reply")`
   - `@Test func responsesFunctionCallDecodesToIRToolUse()`：给 `{type:"function_call", call_id:"call_1", name:"Bash", arguments:"{}"}`，decode 返回 `.toolUse(id:"call_1", name:"Bash", input: JSONObject())`
   - **`@Test func responsesFunctionCallWithEmptyArgumentsStringDecodes()`**（新增，S1 #12）：给 arguments=`""` / arguments=`"not valid json"` / arguments=`"[1,2]"` (array 而非 object) 三种形态，decode 后 `input` 都为 `JSONObject()`（空 object 兜底）
   - `@Test func responsesReasoningItemDecodesToIRThinking()`：给 `{type:"reasoning", encrypted_content:"<b64 of 0x0102>", summary:"summary text"}`，decode 返回 `.thinking(encryptedContent: Data([0x01,0x02]), summary: "summary text")`
   - **`@Test func responsesReasoningDecodesAndEncodesBackToAnthropicThinking()`**（新增，S1 #3）：上游 reasoning item decode → IR `.thinking` → `encodeResponseBlock` → Anthropic wire `{type:"thinking", thinking: "summary text"}`（不包含 `signature` 字段，因为 Phase 1 scope 明确排除）。断言 `result.string("type") == "thinking"` 且 `result.string("thinking") == "summary text"` 且 `result.values["signature"] == nil`
   - `@Test func irTextEncodesToAnthropicContentBlock()`：给 `.text("hi")`，`encodeResponseBlock` 产出 `{type:"text", text:"hi"}`
   - `@Test func irToolUseEncodesToAnthropicContentBlock()`：给 `.toolUse(id:"toolu_1", name:"Bash", input:JSONObject(["command":.string("true")]))`，encode 产出 `{type:"tool_use", id:"toolu_1", name:"Bash", input:{command:"true"}}`

3. 对 image block 的 base64 测试用例：构造 4 字节原始数据 `Data([0x89, 0x50, 0x4e, 0x47])`（PNG magic 头片段），base64 encode 验证 decode 后 byte-for-byte 相等。

**Design ref:** dev-guide Phase 1 Acceptance §2（`IRBlockConversionTests.swift` 覆盖三方向 round-trip）
**Quality markers:** 每个 `@Test` 函数名直接表达被测断言；所有 `#expect` 都针对具体字段值而不是 "non-nil"；unknown type / 空字符串 arguments / string-form tool_result content 三条边界显式覆盖

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter IRBlockConversionTests`
Expected: 所有 @Test 通过（至少 15 条）
<!-- /section -->

<!-- section: task-3 keywords: responses-client, urlsession-bytes, async-stream, sse -->
### Task 3: ResponsesClient 新增 AsyncThrowingStream streaming API

**Files:**
- Modify: `Sources/CCRouterCore/ResponsesClient.swift`

**Steps:**

1. 保留既有 `perform(request:credentials:) async throws -> [JSONObject]`，但**改语义为 API 兼容 shim**（而非 "退化分支"）：`perform` 内部调 `streamEvents` 再 `reduce` 成数组。这样两条 API 共用同一 HTTP 请求构造 + 流式解析路径，不会出现并行 HTTP fetch 代码。

2. 新增 streaming 函数：

```swift
public func streamEvents(
    request payload: JSONObject,
    credentials: SubscriptionCredentials
) async throws -> AsyncThrowingStream<JSONObject, Error>
```

实现要点：
- 构造 `URLRequest` 的逻辑与现有 `perform` 完全一致（zstd 压缩 payload、Authorization / chatgpt-account-id / accept / content-type / content-encoding / user-agent 头），提取为私有 `makeRequest(payload:credentials:)` helper 以避免重复。
- 用 `let (bytes, response) = try await session.bytes(for: request)` 取 `URLSession.AsyncBytes`。
- HTTPURLResponse 检查：
  - `response as? HTTPURLResponse` 失败 → throw `ResponsesHTTPError(statusCode: -1, body: "Missing HTTPURLResponse")`
  - `(200..<300).contains(statusCode)` 失败 → **用 raw byte 迭代读 error body**（不用 `bytes.lines`，因为 error body 可能是 zstd / 非 UTF-8；S1 #5 gap 修订）：
    ```swift
    var errorBody = Data()
    do {
        for try await byte in bytes {
            errorBody.append(byte)
            if errorBody.count >= 64_000 { break }  // cap 避免大 error body 吞内存
        }
    } catch {
        // drain 失败忽略 — error body best-effort
    }
    let bodyString = String(data: errorBody, encoding: .utf8) ?? "<non-utf8 body, \(errorBody.count) bytes>"
    throw ResponsesHTTPError(statusCode: httpResponse.statusCode, body: bodyString)
    ```
- 200 路径下：用 `AsyncThrowingStream` 构造，**必须 wire `onTermination` 把 consumer cancellation 传回 upstream task**（S3 Gap #1 修订）：

```swift
return AsyncThrowingStream { continuation in
    let task = Task {
        do {
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data: ") else { continue }
                let payloadStr = String(line.dropFirst(6))
                if payloadStr == "[DONE]" { continue }
                if payloadStr.isEmpty { continue }
                do {
                    let event = try JSONDecoder().decode(JSONObject.self, from: Data(payloadStr.utf8))
                    continuation.yield(event)
                } catch {
                    // 单条 malformed event — 跳过并 log，避免整个 stream 死
                    fputs("streamEvents: skipping malformed event line: \(payloadStr.prefix(120))\n", stderr)
                    continue
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    continuation.onTermination = { _ in
        task.cancel()   // consumer 取消 → 下游 task 取消 → URLSession.bytes 自动断连（AsyncBytes 响应 task cancellation）
    }
}
```

- actor 隔离：`streamEvents` 是 actor method；内部 `Task { ... }` 生产事件，由 `AsyncThrowingStream` continuation 缓冲。事件顺序由 `URLSession.bytes` 保证。

**Design ref:** dev-guide Phase 1 §Scope 第 1 条
**Replaces:** `ResponsesClient.perform` (ResponsesClient.swift:38) 的整包下载路径 — 现在 `perform` 变成 `streamEvents` 的 reduce shim，但仍保留为 public API 以免所有 test 重写
**Data flow:** `URLSession.bytes` → line parse → JSONObject → AsyncThrowingStream consumer

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild --target CCRouterCore`
Expected: 编译通过，`ResponsesClient.streamEvents` 是 public actor method

Run: `grep -E 'URLSession.*\.bytes\(for:' Sources/CCRouterCore/ResponsesClient.swift`
Expected: 至少一处（streamEvents 内部调用）

Run: `grep -E 'AsyncThrowingStream<JSONObject' Sources/CCRouterCore/ResponsesClient.swift`
Expected: 至少一处（返回类型声明）

Run: `grep -E 'continuation\.onTermination' Sources/CCRouterCore/ResponsesClient.swift`
Expected: 至少一处（cancellation wire up）

Run: `grep -E 'for try await byte in bytes' Sources/CCRouterCore/ResponsesClient.swift`
Expected: 至少一处（error body raw byte drain）
<!-- /section -->

<!-- section: task-4 keywords: local-http-server, chunked-transfer, streaming-response, body-writer -->
### Task 4: LocalHTTPServer 支持 chunked transfer encoding + 流式 body writer

**Files:**
- Modify: `Sources/CCRouterCore/LocalHTTPServer.swift`

**Steps:**

1. 扩展 `HTTPResponse` 的 body 形态，提供 **enum + backward-compat accessors**（S1 #16 gap 修订 — 原 `body: Data` 读 site 不需全部改）：

```swift
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let reasonPhrase: String
    public let headers: [String: String]
    public let body: Body

    public enum Body: Sendable {
        case data(Data)
        case stream(@Sendable (HTTPBodyWriter) async throws -> Void)
    }

    /// Backward-compat accessor — returns Data for `.data` case, nil for `.stream`
    public var bodyData: Data? {
        if case .data(let d) = body { return d }
        return nil
    }

    // Backward-compat init — 既有 Data-body 构造器全部走 .data 分支
    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = .data(body)
    }

    // 新增 stream 构造器
    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        stream producer: @Sendable @escaping (HTTPBodyWriter) async throws -> Void
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = .stream(producer)
    }

    public static func json<T: Encodable>(
        statusCode: Int = 200,
        reasonPhrase: String = "OK",
        value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> HTTPResponse {
        let body = try encoder.encode(value)
        return HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }
}

public protocol HTTPBodyWriter: Sendable {
    func write(_ chunk: Data) async throws
    func finish() async throws
}
```

对既有 `response.body` 读 site（grep 扫：`LocalHTTPServer.send` 第 214 行 `serialized.append(response.body)`；`LocalGatewayAuthorization.unauthorizedResponse()` 若读 body；测试文件）：
- `LocalHTTPServer.send` 内必须改为 switch — 见 Step 2
- `LocalGatewayAuthorization.unauthorizedResponse()` 返回 `HTTPResponse(statusCode: 401, reasonPhrase: "Unauthorized", headers: ..., body: Data(...))` — 用 Data init 自动 wrap 到 `.data`，不需改
- 测试里读 `response.body` 的 callsite：改用 `response.bodyData` 或 `switch response.body { case .data(let d): ... }`

2. `send(response:on connection:)` 按 body 形态分流：

   ```swift
   private static func send(response: HTTPResponse, on connection: NWConnection) async throws {
       switch response.body {
       case .data(let data):
           try await sendDataBody(response: response, body: data, connection: connection)
       case .stream(let producer):
           try await sendStreamBody(response: response, producer: producer, connection: connection)
       }
   }
   ```

   **`.data` 分支**（sendDataBody，既有逻辑微调，确保 Content-Length 仍写）：写 `HTTP/1.1 <code> <reason>\r\n{user headers}\r\nContent-Length: <n>\r\nConnection: close\r\n\r\n<body>`。

   **`.stream` 分支**（sendStreamBody，新增）：
   - 构造 headers：`HTTP/1.1 200 OK\r\n`
   - 合并 user headers；**显式过滤 `Content-Length`**（若上层误设则丢弃）
   - 追加 `Transfer-Encoding: chunked\r\n` 和 `Connection: close\r\n\r\n`
   - 先 `connection.send` 这段 header 数据
   - 创建 `NWConnectionBodyWriter` 实例包装 connection：
     - `write(chunk)`：格式化为 `<hex-size>\r\n<chunk-bytes>\r\n`（size 用小写 hex，no `0x` 前缀；RFC 9112 §7.1），`connection.send` 并 await 完成
     - `finish()`：发送终结 chunk `"0\r\n\r\n"`
   - 调 `try await producer(writer)`；producer throw 时兜底 writer.finish 仍尝试调用（`try?`）以让 client 看到 chunked terminator

   **Nagle 禁用**（S2 运行时 #3 + advisory #1 合并修订 — 50ms 首字节阈值关键）：listener 的 NWParameters 或 connection 的 parameters 里加 `parameters.defaultProtocolStack.transportProtocol?.noDelay = true`（若 `NWProtocolTCP.Options` 可取）。`LocalHTTPServer.start` 第 61-66 行构造 `let parameters = NWParameters.tcp`：
   ```swift
   let parameters = NWParameters.tcp
   parameters.allowLocalEndpointReuse = true
   if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
       tcpOptions.noDelay = true
   }
   ```

3. 现有 `GatewayDaemon.route` 的所有 return 路径自动通过 `HTTPResponse(body: Data)` init 走 `.data` 分支；health / count_tokens / 404 / error 不需改 callsite。只有 `bridge.handleMessages` 200 成功路径在 Task 5 改造后返回 `.stream` body。

4. **RFC 9112 §6.2 合规检查**（S1 #6 + DF-3 修订）：`.stream` 分支 headers **不得**同时出现 `Transfer-Encoding: chunked` 与 `Content-Length`。代码层面由 `sendStreamBody` 的显式过滤保证；测试层面由 Task 6 `chunkedTransferHeadersExcludeContentLength` 断言。

5. `HTTPBodyWriter.write` 的 error 处理：`NWConnection.send` 失败（socket 被 client 关闭、写超时）→ writer 直接 throw 给 producer；producer (即 `runStreamingTurn`) 的 try/catch 见 Task 5 Step 9。

**Design ref:** dev-guide Phase 1 §Scope 第 2 条；DP-003 chosen=A；RFC 9112 §7.1 (chunked) + §6.2 (Transfer-Encoding precedence)
**Expected values:** `Transfer-Encoding: chunked` header string 必须出现；chunk 格式严格按 RFC 9112 §7.1 `<hex>\r\n<data>\r\n` / 终止 `0\r\n\r\n`；`.stream` 分支 headers 不含 `Content-Length`
**Replaces:** `HTTPResponse.body: Data` 被 `HTTPResponse.body: Body` enum 替换；backward-compat 通过 convenience init + `bodyData` accessor 维持；`serialized.append(response.body)` 被 `switch response.body` 替换

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild --target CCRouterCore`
Expected: 编译通过；`HTTPResponse.Body` public enum 存在；`HTTPBodyWriter` public protocol 存在

Run: `grep -E 'Transfer-Encoding.*chunked' Sources/CCRouterCore/LocalHTTPServer.swift`
Expected: 至少一处

Run: `grep -E 'HTTPResponse\.Body\.stream|case \.stream|case stream' Sources/CCRouterCore/LocalHTTPServer.swift`
Expected: 至少三处（enum 定义 + send switch 匹配）

Run: `grep -E 'noDelay' Sources/CCRouterCore/LocalHTTPServer.swift`
Expected: 至少一处（TCP noDelay 配置）

Run: `grep -rE '\bresponse\.body\b' Sources/CCRouterCore/ Sources/CCRouterApp/ Sources/CCRouterDaemon/ Tests/CCRouterCoreTests/`
Expected: 所有 hit 都在 switch match / bodyData accessor / enum 构造上下文里（不存在 `serialized.append(response.body)` 这种对 enum 直接当 Data 用的代码）
<!-- /section -->

<!-- section: task-5 keywords: anthropic-bridge, streaming, ir, pending-tool-turn, advisor -->
### Task 5: AnthropicBridge 改 streaming + IR-native（handleMessages + SSE emitter + PendingToolTurn）

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift`
- Create: `Sources/CCRouterCore/AnthropicSSEEncoder.swift`

**Steps:**

1. 新建 `AnthropicSSEEncoder`（stateful non-actor class，由单一任务在 bridge 的串行上下文内使用）。**所有 emit 方法末尾必须 reset `currentBlockKind = nil`**（S1 #9 修订）；`finish` 内部必须先 `closeOpenBlock`（S2 运行时 #1 修订）：

```swift
final class AnthropicSSEEncoder: @unchecked Sendable {
    // @unchecked Sendable 因为 class 不是 actor；调用方保证串行使用 (只在 runStreamingTurn 的单 task 里用，不跨 actor)
    private let anthropicModel: String
    private let writer: HTTPBodyWriter
    private let encoder: JSONEncoder
    private var messageStarted = false
    private var currentBlockIndex: Int = -1
    private var currentBlockKind: BlockKind? = nil
    private var finalOutputTokens: Int = 0

    enum BlockKind: Equatable { case text, toolUse, serverToolUse, advisorToolResult, thinking }
    enum StopReasonHint { case endTurn, toolUse, advisor }

    init(anthropicModel: String, writer: HTTPBodyWriter, encoder: JSONEncoder = JSONEncoder())

    // 必须第一个调用；写 event: message_start + data
    func startMessage(initialInputTokens: Int = 1) async throws

    // lazy-open 一个 text block；若当前已有 text block 打开则继续 delta；若当前是其他 kind 则先 close 再开新 text block
    func emitTextDelta(_ delta: String) async throws

    // 整块 emit：关闭任何打开 block → content_block_start → content_block_delta(input_json_delta) → content_block_stop → currentBlockKind = nil
    func emitToolUseBlock(id: String, name: String, argumentsJSON: String) async throws

    // 整块 emit → currentBlockKind = nil
    func emitServerToolUseBlock(id: String, name: String, input: JSONObject) async throws

    // 整块 emit → currentBlockKind = nil
    func emitAdvisorToolResultBlock(toolUseID: String, text: String) async throws

    // 整块 emit → currentBlockKind = nil
    func emitThinkingBlock(encryptedContent: Data?, summary: String?) async throws

    // 若 currentBlockKind != nil 写 content_block_stop；currentBlockKind = nil；不影响已 emit 过的 block_start
    func closeOpenBlock() async throws

    // 内部 record final usage，不立刻 emit；由 finish 写入
    func updateFinalOutputTokens(_ value: Int)

    // 必须最后调用：先 closeOpenBlock → message_delta (stop_reason) → message_stop
    func finish(stopReasonHint: StopReasonHint) async throws
}
```

内部实现要点：
- `startMessage`：若 `messageStarted` 已为 true 则 return（幂等）；否则写 `event: message_start\ndata: {...}\n\n`（`message.content: []`，`usage.input_tokens = max(1, initialInputTokens)`，`usage.output_tokens = 1`），`messageStarted = true`
- `emitTextDelta`：
  - 若 `currentBlockKind != .text`：先 `try await closeOpenBlock()` → `currentBlockIndex += 1` → 写 `content_block_start`（`content_block: {type:"text", text:""}`）→ `currentBlockKind = .text`
  - 写 `content_block_delta`（`delta: {type:"text_delta", text: delta}`）
- `emitToolUseBlock`：`try await closeOpenBlock()` → `currentBlockIndex += 1` → `content_block_start`（`{type:"tool_use", id, name, input:{}}`）→ `content_block_delta`（`{type:"input_json_delta", partial_json: argumentsJSON}`）→ `content_block_stop` → `currentBlockKind = nil`
- `emitServerToolUseBlock / emitAdvisorToolResultBlock / emitThinkingBlock`：`try await closeOpenBlock()` → `currentBlockIndex += 1` → `content_block_start`（with `content_block:` 用 `IRAnthropicCodec.encodeResponseBlock` 从 IR 生成 wire shape）→ `content_block_stop` → `currentBlockKind = nil`
- `closeOpenBlock`：若 `currentBlockKind != nil` 写 `content_block_stop` 且置 `currentBlockKind = nil`；幂等
- `finish`：
  - `try await closeOpenBlock()`（兜底：`response.output_item.done` 缺席也能关闭未 close 的 text block，S2 运行时 #1 修订）
  - 写 `message_delta`（`stop_reason: {endTurn→"end_turn", toolUse→"tool_use", advisor→"end_turn"}`，`usage.output_tokens`）
  - 写 `message_stop`

2. `AnthropicBridge.swift` 改造 `handleMessages` 返回 streaming response：

```swift
return HTTPResponse(
    statusCode: 200,
    reasonPhrase: "OK",
    headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
    stream: { [self, anthropicRequest, sessionID, credentials] writer in
        try await self.runStreamingTurn(
            writer: writer,
            request: anthropicRequest,
            sessionID: sessionID,
            credentials: credentials,
            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds
        )
    }
)
```

3. 新增 `runStreamingTurn(writer:request:sessionID:credentials:startedAtUptimeNanoseconds:)` actor-isolated method：

   **分支 A — pendingToolTurn 续轮**：
   - 先解码 Anthropic 续轮 request：`let requestIR = anthropicRequest.messages.map { IRMessage(role: $0.role, content: IRAnthropicCodec.decodeRequestBlocks($0.content)) }`
   - 从 pending.replayIR 生成 top-level items：`let replayInput = IRResponsesCodec.encodeReplayBlocks(pending.replayIR)`
   - 从 requestIR 的 user message content 提取 tool_result：`let toolResultInput = IRResponsesCodec.encodeToolResultOutputs(requestIR.flatMap(\.content))`
   - 若 `toolResultInput.isEmpty`（当前 request 无匹配 tool_result），**fallback 到 initial 分支的逻辑**：跳出分支 A，转而执行下面分支 B 的流水（保持既有 `AnthropicBridge.swift:312-329` `buildContinuationPayload` return nil 的语义等价 — `pendingToolTurns` 条目保留，但当前 request 当成新 turn 处理）。实现上：从 runStreamingTurn 入口起做一次 `if let pending = pendingToolTurns[sessionID], let toolResultInput = try encodeToolResultOutputsFromRequest(requestIR), !toolResultInput.isEmpty { /* 分支 A */ } else { /* 分支 B */ }` 的二选一判断，不再有"先尝试续轮再回落"的嵌套控制流。
   - `let continuationPayload = makeResponsesPayload(model: configuration.executorModel, instructions: "", input: replayInput + toolResultInput, tools: pending.convertedTools, toolChoice: .string("auto"))`
   - 初始化 encoder（**不**调 `startMessage`，因为续轮是 assistant 对同一个会话的下一轮；但对 Anthropic CLI 来说续轮也是新 message_start — 所以调 `startMessage(initialInputTokens: 1)`）
   - `let stream = try await responsesClient.streamEvents(request: continuationPayload, credentials: credentials)`
   - 调 `processUpstreamStream(stream:encoder:)`
   - 根据新一轮事件决定 `pendingToolTurns[sessionID]` 更新或删除（见 step 6/7）

   **分支 B — initial turn**：
   - `let requestIR = anthropicRequest.messages.map { IRMessage(role: $0.role, content: IRAnthropicCodec.decodeRequestBlocks($0.content)) }`
   - 系统指令：`let instructions = joinedSystemText(from: request.system ?? [])`（保留既有 helper）
   - `let input = IRResponsesCodec.encodeInputItems(requestIR)`
   - Tools（保留现有 `convertTools`；Phase 2 才改）：`let tools = try convertTools(request.tools ?? [])`
   - `let initialPayload = makeResponsesPayload(model: configuration.executorModel, instructions: instructions, input: input, tools: tools.convertedTools, toolChoice: .string("auto"))`
   - `let encoder = AnthropicSSEEncoder(anthropicModel: request.model, writer: writer)`
   - `try await encoder.startMessage(initialInputTokens: 1)`
   - `let stream = try await responsesClient.streamEvents(request: initialPayload, credentials: credentials)`
   - 调 `processUpstreamStream(stream:encoder:)`
   - 根据 step 5/6/7 决定终态

4. `processUpstreamStream(stream:encoder:) -> (sawAdvisorCall: (id:String, args:String)?, outputIRBlocks:[IRBlock], finalUsage:(input:Int,output:Int))`：

```swift
var sawAdvisorCall: (id: String, argumentsJSON: String)? = nil
var outputIRBlocks: [IRBlock] = []
var finalUsage: (input: Int, output: Int) = (0, 0)

for try await event in stream {
    guard let eventType = event.string("type") else { continue }
    // Optional trace：event 级 log 让 acceptance §3（trace 出现 responses_in_event 级记录）可见
    await TraceLogger.shared.log(
        JSONObject.from([
            "stage": .string("responses_in_event"),
            "event_type": .string(eventType),
        ])
    )
    switch eventType {
    case "response.output_text.delta":
        if let delta = event.string("delta") {
            try await encoder.emitTextDelta(delta)
        }
    case "response.output_item.done":
        guard let item = event.object("item") else { break }
        guard let ir = IRResponsesCodec.decodeOutputItem(item) else { break }
        outputIRBlocks.append(ir)
        switch ir {
        case .text:
            // text delta 已通过 output_text.delta emit；此处关闭 text block
            try await encoder.closeOpenBlock()
        case .toolUse(let id, let name, _):
            if name == "advisor" && advisorEnabled {
                // 暂缓 advisor — 外层 runStreamingTurn 处理
                sawAdvisorCall = (id, item.string("arguments") ?? "{}")
            } else {
                try await encoder.emitToolUseBlock(id: id, name: name, argumentsJSON: item.string("arguments") ?? "{}")
            }
        case .thinking(let enc, let sum):
            try await encoder.emitThinkingBlock(encryptedContent: enc, summary: sum)
        default:
            break
        }
    case "response.completed":
        if let usage = event.object("response")?.object("usage") {
            finalUsage.input = usage["input_tokens"]?.intValue ?? 0
            finalUsage.output = usage["output_tokens"]?.intValue ?? 0
        }
    default:
        continue
    }
}
// 兜底（S2 运行时 #1 修订）：stream 结束时若最后一个 block 未关闭（例如 response.output_item.done 缺席），显式 close
try await encoder.closeOpenBlock()
encoder.updateFinalOutputTokens(finalUsage.output)
return (sawAdvisorCall, outputIRBlocks, finalUsage)
```

**注**：advisorEnabled 需要从外层传入（initial vs continuation 两条路径都知道）。签名改为 `processUpstreamStream(stream:encoder:advisorEnabled:)`。

5. **Advisor 分支处理**：`processUpstreamStream` 返回 `(sawAdvisorCall, outputIRBlocks, finalUsage)`。若 `sawAdvisorCall != nil`：
   - 不 finish encoder（保留已 emit 的 text blocks）
   - 写 synthetic `server_tool_use`：`try await encoder.emitServerToolUseBlock(id: sawAdvisorCall.id, name: "advisor", input: JSONObject())`
   - `let advisorText: String; do { advisorText = try await runAdvisorSubcall(credentials: credentials) } catch { advisorText = "[advisor unavailable: \(error.localizedDescription)]"; /* S3 advisory 修订：子 call 失败不中断主 turn */ }`
   - 写 synthetic `advisor_tool_result`：`try await encoder.emitAdvisorToolResultBlock(toolUseID: sawAdvisorCall.id, text: advisorText)`
   - 构造第二段 `/responses` payload：`let replayInput = IRResponsesCodec.encodeReplayBlocks(outputIRBlocks.filter { if case .thinking = $0 { return true } else if case .toolUse = $0 { return true } else { return false } })`；拼 `function_call_output` for advisor：`+ [.object(JSONObject.from(["type": .string("function_call_output"), "call_id": .string(sawAdvisorCall.id), "output": .string(advisorText)]))]`
   - `let secondPayload = makeResponsesPayload(model: configuration.executorModel, instructions: "", input: replayInput + advisorOutputItem, tools: convertedTools, toolChoice: .string("auto"))`
   - `let secondStream = try await responsesClient.streamEvents(request: secondPayload, credentials: credentials)`
   - 复用同一 encoder（不重调 startMessage）：`let (secondAdvisorCall, secondOutputIRBlocks, secondUsage) = try await processUpstreamStream(stream: secondStream, encoder: encoder, advisorEnabled: false)`（第二段禁用 advisor 检测，避免死循环）
   - 若第二段 `secondOutputIRBlocks` 里又有非 advisor 的 `.toolUse` → 设置 `pendingToolTurns[sessionID] = PendingToolTurn(..., replayIR: filterReplayIR(secondOutputIRBlocks), ...)`（filter 规则见 step 6）；`try await encoder.finish(stopReasonHint: .toolUse)`
   - 否则（第二段纯文本）：`pendingToolTurns.removeValue(forKey: sessionID)`；`try await encoder.finish(stopReasonHint: .endTurn)`

6. **Tool-use 分支处理**（advisorEnabled=false 或 sawAdvisorCall=nil 且 outputIRBlocks 有非 advisor `.toolUse`）：
   - `let replayIR = outputIRBlocks.filter { ir in if case .thinking = ir { return true } else if case .toolUse = ir { return true } else { return false } }`（S1 #4 修订：显式 filter 规则 — 只回放 reasoning + function_call；text / image / toolResult / serverToolUse / advisorToolResult 不进 replay；这对应 `docs/scheme3/09 §4.4` 续轮 input 只含 reasoning + function_call + function_call_output 的观测）
   - `pendingToolTurns[sessionID] = PendingToolTurn(anthropicModel: request.model, convertedTools: convertedTools, replayIR: replayIR, advisorEnabled: advisorEnabled)`
   - `try await encoder.finish(stopReasonHint: .toolUse)`

7. **纯文本分支**（outputIRBlocks 里无 toolUse、无 advisor）：
   - `pendingToolTurns.removeValue(forKey: sessionID)`
   - `try await encoder.finish(stopReasonHint: .endTurn)`

8. `PendingToolTurn` 重构：

```swift
private struct PendingToolTurn: Sendable {
    let anthropicModel: String
    let convertedTools: [JSONObject]
    let replayIR: [IRBlock]  // 之前是 [JSONValue]；现在存 IR；只含 .thinking / .toolUse（filter 见 step 6）
    let advisorEnabled: Bool
}
```

trace log 字段 `replay_item_types` （原 AnthropicBridge.swift:265-268 的 `replayItemsForContinuation(from:).map(...).string("type")`）改为 IR case 名字符串：`replayIR.map { ir -> String in switch ir { case .text: return "text"; case .image: return "image"; case .toolUse: return "tool_use"; case .toolResult: return "tool_result"; case .thinking: return "thinking"; case .serverToolUse: return "server_tool_use"; case .advisorToolResult: return "advisor_tool_result" } }`（保持 trace 字段语义 — Phase 1 前的 `["reasoning", "function_call"]` 对应 Phase 1 后的 `["thinking", "tool_use"]`；trace 字段 key 不变，值命名迁移到 IR 语义）

9. **错误处理**（S3 Gap #2 修订 — 错误路径必须清 `pendingToolTurns`）：

```swift
do {
    // runStreamingTurn body: stream + encoder emit
    ...
} catch {
    // stream 中断：清理 session state，避免下次请求误走续轮分支
    pendingToolTurns.removeValue(forKey: sessionID)
    // best-effort：在已 open 的 body stream 上 emit 一条 error 信号，然后 finish
    try? await encoder.emitTextDelta("\n[upstream error: \(error.localizedDescription)]")
    try? await encoder.finish(stopReasonHint: .endTurn)  // Anthropic wire stop_reason 不支持 "error"；用 end_turn + text delta 是 best-effort（S3 advisory）
    // 向上 rethrow 让 producer 看到；LocalHTTPServer 的 sendStreamBody 会 swallow 并让 NWConnection.cancel 清 socket
    // trace log：stream_aborted
    await TraceLogger.shared.log(
        JSONObject.from([
            "stage": .string("anthropic_out"),
            "session_id": .string(sessionID),
            "status_code": .number(200),  // headers 已 flush，无法改 status
            "result": .string("stream_aborted"),
            "error_type": .string("stream_aborted"),
            "error_message": .string(error.localizedDescription),
        ])
    )
    throw error
}
```

10. **保留/删除清单**（S1 #17 + S2 编译 #2 + AR.2 修订）：

   **保留（签名与行为不变）：**
   - `joinedSystemText(from:)` (line 357-363) — 仍用于 initial payload 构造
   - `convertTools(_:)` (line 365-411) — Phase 2 才改
   - `runAdvisorSubcall(credentials:)` (line 715-735) — 内部仍用 `responsesClient.perform` (collect-all shim)；advisor subcall 是短响应不需 streaming
   - `joinedMessageText(from:)` (line 737-748) — 仍被 runAdvisorSubcall 调用
   - `encodeJSON(_:)` (line 750-754) — 保留
   - `makeResponsesPayload(...)` (line 756-783) — 签名不变；Phase 2 才改签名
   - `logRequestOutcome(...)` (line 785-806) — 保留；streaming 路径的 status_code 改为 200 + result=stream_aborted/success
   - `anthropicError(...)` (line 808-815) — 保留；但只有非 200 错误路径（auth 失败、decode 失败）用，streaming 路径不经过
   - `ConvertedTools` / `InitialPayload` private struct (line 848-857) — 保留

   **删除：**
   - `finalizeResponse(...)` (line 162-293) — 整块聚合流水废弃
   - `makeTextSSE / makeToolUseSSE / makeAdvisorSSE` (line 440-501) — 被 `AnthropicSSEEncoder` 取代
   - `buildAnthropicSSE(...)` (line 503-663) — 被 `AnthropicSSEEncoder.emit*` 取代
   - `sse(event:data:)` helper (line 817-824) — 内部版本移到 `AnthropicSSEEncoder`
   - `outputItemsInOrder(from:)` (line 422-427) — streaming 路径 inline 处理
   - `replayItemsForContinuation(from:)` (line 413-420) — 被 IR-native filter + `encodeReplayBlocks` 取代
   - `finalUsage(from:)` (line 429-438) — usage 在 stream loop 的 `response.completed` 分支 inline 读取
   - `convertMessages(_:)` (line 331-343) — 被 `IRResponsesCodec.encodeInputItems` 取代
   - `convertContentBlocks(_:)` (line 345-355) — 被 `IRAnthropicCodec.decodeRequestBlocks` 取代
   - `stringifyToolResultContent(_:)` (line 690-713) — 被 `IRResponsesCodec.encodeToolResultOutputs` 的内部 stringify 逻辑取代（dev-guide L73 要求 IR 化，AR.2 替代 #3 修订）
   - `functionCallOutputs(...)` (line 665-688) — 被 `IRResponsesCodec.encodeToolResultOutputs` 取代（输入改为 IR 而非 AnthropicMessagesRequest）
   - `buildInitialPayload(...)` (line 295-310) — inline 到 runStreamingTurn 分支 B
   - `buildContinuationPayload(...)` (line 312-329) — inline 到 runStreamingTurn 分支 A
   - `ResponsesContentPart` private struct (line 834-846) — 不再需要（IR 驱动）

   **重构（签名不变但行为改）：**
   - `handleMessages(_:)` — 见 step 2
   - `PendingToolTurn` (line 859-864) — 见 step 8

**Design ref:** dev-guide Phase 1 §Scope 第 3 / 5 / 6 条；DP-004 chosen=A（IR 全面化）
**Replaces:** 见上面删除清单；`PendingToolTurn.replayItems: [JSONValue]` → `replayIR: [IRBlock]`
**Data flow:** Anthropic request → IR messages → /responses payload → `streamEvents` → per-event IR decode → `AnthropicSSEEncoder` → `HTTPBodyWriter` → Claude CLI
**Quality markers:** 翻译主路径（`runStreamingTurn`）不出现 `JSONObject.from([` 直接构造 wire-level 字段的代码；所有 wire-level 构造都在 `AnthropicSSEEncoder` 或 `IRResponsesCodec` / `IRAnthropicCodec` 内

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild --target CCRouterCore`
Expected: 编译通过

Run: `grep -cE 'JSONObject\.from\(\[' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: ≤ 10（既有 25+ 处；重构后 JSONObject ad-hoc 构造只剩 `makeResponsesPayload` + trace log + anthropicError 相关；DP-004 "JSONObject 只在协议解析/合成的边缘" 的量化指标）

Run: `grep -E 'finalizeResponse|buildAnthropicSSE|makeTextSSE|makeToolUseSSE|makeAdvisorSSE|convertContentBlocks|convertMessages|stringifyToolResultContent|outputItemsInOrder|replayItemsForContinuation|finalUsage|buildInitialPayload|buildContinuationPayload|functionCallOutputs' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: 无匹配（上述 helper 全部删除）

Run: `grep -E 'streamEvents|AnthropicSSEEncoder' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: 至少 3 处（initial stream 调用 + continuation stream 调用 + encoder 实例化）

Run: `grep -E 'replayIR:|\.replayIR' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: 至少 3 处（PendingToolTurn struct 定义 + 构造 + 读取）

Run: `grep -E 'encodeReplayBlocks|encodeToolResultOutputs' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: 至少 2 处
<!-- /section -->

<!-- section: task-6 keywords: streaming, integration-test, first-delta, mock-upstream, sse-latency -->
### Task 6: Streaming 集成测试（首字节延迟 + chunked transfer 接受性）

**Files:**
- Create: `Tests/CCRouterCoreTests/StreamingBridgeIntegrationTests.swift`
- Create: `Tests/CCRouterCoreTests/MockResponsesEventStream.swift`（test helper）

**Steps:**

1. **依赖注入：** 新增 `ResponsesStreamingClient` protocol 作 `AnthropicBridge` 注入点（S1 #10 修订 — 保留 default nil，GatewayDaemon callsite 不需改）：

```swift
// in Sources/CCRouterCore/ResponsesClient.swift (public)
public protocol ResponsesStreamingClient: Sendable {
    func streamEvents(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> AsyncThrowingStream<JSONObject, Error>

    func perform(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> [JSONObject]
}

extension ResponsesClient: ResponsesStreamingClient {}
```

`AnthropicBridge.init` 签名改为：

```swift
public init(
    configuration: RouterConfiguration,
    responsesClient: (any ResponsesStreamingClient)? = nil,  // <- default nil 保留 back-compat
    sessionLoader: SubscriptionSessionLoader = SubscriptionSessionLoader()
) {
    self.configuration = configuration
    self.responsesClient = responsesClient ?? ResponsesClient(endpoint: URL(string: configuration.responsesURL)!)
    self.sessionLoader = sessionLoader
    self.installationID = UUID().uuidString.lowercased()
}
```

`AnthropicBridge` 的 `responsesClient` 成员类型也改为 `any ResponsesStreamingClient`。`GatewayDaemon.swift` line 11-17 的 callsite 不需改（default nil 触发 fallback）。

2. `MockResponsesEventStream.swift`（test helper）：

```swift
import Foundation
@testable import CCRouterCore

struct MockResponsesEventStream {
    // 按已验证 SSE 事件顺序（docs/scheme3/08 §4.2）产生 events；支持在指定 event 前注入延迟
    static func textOnlyTurn(
        text: String,
        deltaDelays: [Duration] = [],  // 每个 delta 前的等待
        totalInputTokens: Int = 10,
        totalOutputTokens: Int = 5
    ) -> AsyncThrowingStream<JSONObject, Error>

    // 文本 delta + function_call (非 advisor)
    static func toolUseTurn(
        textBefore: String?,
        toolName: String,
        callID: String,
        argumentsJSON: String
    ) -> AsyncThrowingStream<JSONObject, Error>

    // 首段 function_call=advisor + 第二段纯文本
    static func advisorTurn(
        firstPassText: String?,
        advisorCallID: String,
        finalPassText: String
    ) -> (first: AsyncThrowingStream<JSONObject, Error>, second: AsyncThrowingStream<JSONObject, Error>)

    // 文本 delta + error (mid-stream throw)
    static func textThenError(
        partialText: String,
        error: Error
    ) -> AsyncThrowingStream<JSONObject, Error>
}

actor MockResponsesClient: ResponsesStreamingClient {
    private var queuedStreams: [AsyncThrowingStream<JSONObject, Error>]
    private var performResults: [[JSONObject]]  // 为 perform shim 服务（advisor subcall 用）

    init(streams: [AsyncThrowingStream<JSONObject, Error>], performResults: [[JSONObject]] = [])

    func streamEvents(request: JSONObject, credentials: SubscriptionCredentials) async throws -> AsyncThrowingStream<JSONObject, Error> {
        // FIFO dequeue
    }
    func perform(request: JSONObject, credentials: SubscriptionCredentials) async throws -> [JSONObject] {
        // FIFO dequeue from performResults
    }
}

actor InMemoryBodyWriter: HTTPBodyWriter {
    private(set) var chunks: [(timestamp: ContinuousClock.Instant, data: Data)] = []
    private(set) var finished = false
    func write(_ chunk: Data) async throws {
        chunks.append((.now, chunk))
    }
    func finish() async throws { finished = true }
    var concatenated: Data { chunks.reduce(Data(), { $0 + $1.data }) }
    var concatenatedString: String { String(data: concatenated, encoding: .utf8) ?? "<non-utf8>" }
}
```

注：`SubscriptionCredentials` 需要 mock 实例 — 测试里构造任意 `SubscriptionCredentials(accessToken: "test", accountID: "test")`（现有 public init）。

3. `StreamingBridgeIntegrationTests.swift` 至少覆盖以下 @Test：

   - `@Test func firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta()`：mock 提供 3 个 delta，无 deltaDelays；记录第一个 `response.output_text.delta` 的时刻与 writer 第一次写入含 `content_block_delta` 帧的时刻；`#expect(firstDeltaToFirstWrite < .milliseconds(50))`
   - `@Test func responseBodyIsStreamFormAndNotDataFallback()`：bridge 返回 HTTPResponse；`#expect(response.bodyData == nil)` (即 .stream case)
   - `@Test func textDeltasAreEmittedIncrementallyNotAggregated()`：mock 3 次 delta；count `content_block_delta` 帧数；`#expect(count == 3)`；额外断言没有单条 delta 含全部 3 段文本拼接
   - `@Test func toolUseTurnStopsWithToolUseReason()`：mock 返回 function_call；断言 recorded body 末尾 message_delta 的 `stop_reason == "tool_use"`；断言 `pendingToolTurns` 已存（用 @testable internal access）
   - `@Test func advisorTurnStreamsThroughTwoPasses()`：mock 首段返回 function_call(advisor) + second 段返回文本；expect wire 帧序列里依次出现 text_delta (optional)、server_tool_use、advisor_tool_result、text_delta (second pass)、message_delta(end_turn)
   - **`@Test func toolUseBlockFollowedByMoreTextOpensNewBlockIndex()`**（S1 #9 修订）：mock 事件顺序 — text delta x2 → function_call item done → text delta x1（单 turn 内 tool_use 后再 text，虽然上游不太会这样，但是 encoder 状态机健壮性检查）；断言 writer 记录里 `content_block_start` 出现至少 3 次（text0, tool_use, text2），且三次的 `index` 是 0/1/2（不重复 index）
   - **`@Test func streamErrorPathClearsPendingToolTurn()`**（S3 Gap #2 修订）：mock 第一段返回 function_call → 进入 pending；第二段（续轮 request）mock stream throw mid-flight；bridge catch 后 `pendingToolTurns[sessionID] == nil`
   - `@Test func streamAbortedUpstreamEmitsErrorMarkerAndStopsClean()`：mock textThenError；expect recorded body 含 `[upstream error: ...]` text_delta + message_delta(end_turn) + message_stop
   - **`@Test func chunkedTransferHeadersExcludeContentLength()`**（S1 #6 修订）：通过单独 unit test，构造 `HTTPResponse` with `.stream` body，直接调用 `LocalHTTPServer`（或其 `sendStreamBody` 暴露 test-only entry）写入一个 mock `NWConnection` replacement（或更简单：写到 Data accumulator，然后 check 原始字节含 `Transfer-Encoding: chunked` 但不含 `Content-Length:`）
   - **`@Test func closeOpenBlockIsIdempotentAndCalledByFinish()`**（S2 运行时 #1 修订）：mock stream yield text_delta × 2 但**不**发 response.output_item.done（模拟 upstream 跳过 output_item.done）；expect recorded body 仍含 `content_block_stop` 帧（由 stream 结束后或 finish 内部的兜底 closeOpenBlock 触发）

4. `toolUseBlockFollowedByMoreTextOpensNewBlockIndex` 的 index 断言：解析 `content_block_start` 帧的 `data: {...}` 里的 `index` 字段。由于 recorded body 是 bytes，测试里要 `split("event:")` 后提取每个 `data: ...\n` 行的 JSON，用 `JSONDecoder` 解析。helper：

```swift
func parseSSEFrames(_ body: Data) -> [(event: String, data: JSONObject)] {
    // 按 \n\n 分段；每段第一行 event: xxx，第二行 data: {json}
}
```

**Design ref:** dev-guide Phase 1 Acceptance §3（streaming 集成测试：第一个 delta 到达后 50ms 内读到第一个 content_block_delta）
**Quality markers:** 至少 10 个 @Test；每个 @Test 直接用 `#expect` 断言具体 wire byte 内容或时间差（不允许只 `#expect(chunks.count > 0)` 这种弱断言）；mock helper 使用与 `docs/scheme3/08 §4.2` 完全一致的 9-event 序列

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter StreamingBridgeIntegrationTests`
Expected: 全部 @Test 通过（至少 10 个）

Run: `grep -E 'content_block_delta|message_delta|message_start|message_stop|content_block_start|content_block_stop' Tests/CCRouterCoreTests/StreamingBridgeIntegrationTests.swift | wc -l`
Expected: ≥ 15（多处断言 wire-level 帧名称）
<!-- /section -->

<!-- section: task-7 keywords: regression, tool-turn, advisor-bridge, smoke -->
### Task 7: 回归：Bash tool turn + advisor bridge（保留 §3.13-3.14 已闭环样本）

**Files:**
- Create: `Tests/CCRouterCoreTests/BridgeRegressionTests.swift`

**Steps:**

1. `BridgeRegressionTests.swift` 覆盖 `docs/scheme3/01-validated-baseline.md §3.13 + §3.14` 的两条已闭环路径：

   **§3.13 Bash tool turn（两段）：**

```swift
@Test
func bashToolTurnTwoRoundsStillClosesViaStreaming() async throws {
    // 第 1 段 mock：upstream 返回 function_call(name="Bash", arguments={"command":"true"})
    // 第 2 段 mock：upstream 返回 message(text="Ran a minimal Bash command successfully.")
    let mock = MockResponsesClient(streams: [
        MockResponsesEventStream.toolUseTurn(textBefore: nil, toolName: "Bash", callID: "toolu_bash_1", argumentsJSON: "{\"command\":\"true\"}"),
        MockResponsesEventStream.textOnlyTurn(text: "Ran a minimal Bash command successfully."),
    ])
    let bridge = AnthropicBridge(configuration: testConfig, responsesClient: mock, sessionLoader: mockSessionLoader)

    // 第 1 条 /v1/messages（无 tool_result）
    let firstRequest = HTTPRequest(...)
    let firstResponse = await bridge.handleMessages(firstRequest)
    let firstWriter = InMemoryBodyWriter()
    if case .stream(let producer) = firstResponse.body { try await producer(firstWriter) }
    // 断言 recorded body 含 tool_use block + stop_reason=tool_use
    // 断言 await bridge.pendingToolTurns[sessionID] 已存（@testable internal access）

    // 第 2 条 /v1/messages（role:"user", content:[{type:"tool_result", tool_use_id:"toolu_bash_1", content:"success"}]）
    let secondRequest = HTTPRequest(...)
    let secondResponse = await bridge.handleMessages(secondRequest)
    let secondWriter = InMemoryBodyWriter()
    if case .stream(let producer) = secondResponse.body { try await producer(secondWriter) }
    // 断言 recorded body 含 text_delta "Ran a minimal..." + stop_reason=end_turn
    // 断言 pendingToolTurns[sessionID] == nil

    // **关键断言**（S1 #4 修订）：续轮发给上游的 /responses input 不含 text-based 历史
    // 通过 MockResponsesClient 捕获第 2 次 streamEvents 调用的 payload；解包 input 数组；断言每个 item.type ∈ {reasoning, function_call, function_call_output}，不含 {message} 类 item（因为 replayIR 只过滤 reasoning + function_call）
    let capturedSecondPayload = await mock.capturedRequests[1]
    let inputItems = capturedSecondPayload.array("input")?.compactMap(\.objectValue) ?? []
    for item in inputItems {
        let itemType = item.string("type") ?? ""
        #expect(["reasoning", "function_call", "function_call_output"].contains(itemType))
    }
}
```

   **§3.14 advisor bridge：**

```swift
@Test
func advisorBridgeStillSynthesizesServerToolUseAndAdvisorToolResult() async throws {
    // Mock 首段：upstream 返回 function_call(name="advisor")
    // Mock advisor 子 call (通过 MockResponsesClient.perform)：返回 message(text="Suggested approach: X")
    // Mock 最终段：upstream 返回 message(text="Final reply")
    let advisorCallID = "toolu_advisor_1"
    let mock = MockResponsesClient(streams: [
        MockResponsesEventStream.toolUseTurn(textBefore: nil, toolName: "advisor", callID: advisorCallID, argumentsJSON: "{}"),
        MockResponsesEventStream.textOnlyTurn(text: "Final reply"),
    ], performResults: [
        [JSONObject.from([
            "type": .string("response.output_item.done"),
            "item": .object(JSONObject.from([
                "type": .string("message"),
                "content": .array([
                    .object(JSONObject.from([
                        "type": .string("output_text"),
                        "text": .string("Suggested approach: X"),
                    ])),
                ]),
            ])),
        ])],
    ])
    let bridge = AnthropicBridge(configuration: testConfig, responsesClient: mock, sessionLoader: mockSessionLoader)

    // 构造含 advisor_20260301 tool 的 /v1/messages
    let request = HTTPRequest(...)  // tools: [{type: "advisor_20260301"}]
    let response = await bridge.handleMessages(request)
    let writer = InMemoryBodyWriter()
    if case .stream(let producer) = response.body { try await producer(writer) }

    // 解析 recorded body 的 SSE 帧序列
    let frames = parseSSEFrames(writer.concatenated)
    let frameTypes = frames.compactMap { $0.data.string("type") }

    // 断言帧出现顺序（不要求相邻，只要求相对顺序）
    let serverToolUseIdx = frameTypes.firstIndex(of: "content_block_start")  // 找 server_tool_use block
    // 更严格：查找 content_block 里 type=server_tool_use
    var sawServerToolUse = false
    var sawAdvisorToolResult = false
    var sawFinalMessageDelta = false
    for frame in frames {
        if let cb = frame.data.object("content_block"),
           cb.string("type") == "server_tool_use",
           cb.string("name") == "advisor" {
            sawServerToolUse = true
        }
        if let cb = frame.data.object("content_block"),
           cb.string("type") == "advisor_tool_result",
           cb.string("tool_use_id") == advisorCallID {
            sawAdvisorToolResult = true
        }
        if frame.event == "message_delta",
           frame.data.object("delta")?.string("stop_reason") == "end_turn" {
            sawFinalMessageDelta = true
        }
    }
    #expect(sawServerToolUse)
    #expect(sawAdvisorToolResult)
    #expect(sawFinalMessageDelta)
}
```

2. 回归两个独立测试断言 pendingToolTurns 与 advisor bridge 的 wire 形状与 Phase 0 基线一致。

3. 注意：这两条回归用 mock stream，**不**触达真实上游。真实上游验证在 dev-guide acceptance §4 的真机 smoke 里（由 phase 6-7 的 run 阶段手动触发）。

**Design ref:** dev-guide Phase 1 Review checklist §3（回归检查：§3.13-3.14 已闭环工具回合样本仍闭环）
**Quality markers:** 两条回归测试各自覆盖一条已验证样本；断言必须到 wire-level 帧类型而不是只断言 "finish without throw"；续轮 input 类型断言用于验证 replayIR filter 规则

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests`
Expected: 两个 @Test 都通过
<!-- /section -->

<!-- section: task-8 keywords: responses-client, sse-parse, url-protocol, unit-test -->
### Task 8: ResponsesClient.streamEvents 独立 unit 测试（URLProtocol stub）

**Files:**
- Create: `Tests/CCRouterCoreTests/ResponsesClientStreamingTests.swift`

**Steps:**

1. 用 `URLProtocol` subclass stub 构造 mock HTTP 响应，绕过真实网络；`URLSessionConfiguration.protocolClasses = [MockSSEProtocol.self]` 注入到 `ResponsesClient` (需要 `ResponsesClient.init(session:)` 扩展新 init 接受自定义 session；或者通过 dependency injection test hook 改成内部 test-only init)

```swift
final class MockSSEProtocol: URLProtocol {
    static var mockStatusCode: Int = 200
    static var mockHeaders: [String: String] = ["content-type": "text/event-stream"]
    static var mockBodyChunks: [Data] = []  // per-chunk data; client protocol will receive them with delays
    static var mockError: Error? = nil

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // send response, then chunks, then finish
    }
    override func stopLoading() {}
}
```

2. 至少以下 @Test 覆盖：

   - `@Test func yieldsEventPerDataLine()`：mock body 3 条 `data: {...}` 行；`streamEvents` 应 yield 3 个 JSONObject
   - `@Test func ignoresDoneSentinel()`：mock 含 `data: [DONE]`；yield 数不包含它
   - `@Test func ignoresBlankAndCommentLines()`：mock 含 空行、`: comment` 行；跳过不 yield
   - `@Test func malformedEventIsSkippedNotFatal()`：mock 3 条，中间一条是 `data: not valid json`；stream 只 yield 2 个（跳过坏行），不 throw
   - `@Test func non200StatusThrowsResponsesHTTPError()`：mock statusCode=401 + body `{"error":"unauthorized"}`；`streamEvents` 应 throw `ResponsesHTTPError` 且 `statusCode == 401`
   - `@Test func errorBodyReadWithoutAssumingUTF8Lines()`（S1 #5 修订）：mock statusCode=500 + body 是非 UTF-8 bytes（例如随机 128-255 字节）；`streamEvents` 应 throw `ResponsesHTTPError` 且 error body 字符串含 `<non-utf8 body, N bytes>` 或 UTF-8 replacement characters（不应 throw decoding error 掩盖 HTTP status）
   - `@Test func cancellationPropagatesToUpstreamTask()`（S3 Gap #1 修订）：构造 streamEvents，consume 第一个 event 后 `continuation.cancel()` 或外层 Task cancel；mock 可以暴露一个 "stopLoading called" flag 断言 URLProtocol.stopLoading() 被触发（间接证明 task 被 cancel）

**Design ref:** S1 #5 + S3 Gap #1 + T1 Gap
**Quality markers:** 7 @Test 覆盖 Task 3 的所有分支（成功 / [DONE] / 注释 / malformed / 非 200 / 非 UTF-8 body / cancel）

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ResponsesClientStreamingTests`
Expected: 全部 @Test 通过（至少 7 个）
<!-- /section -->

---

## Decisions

None.

（DP-003 / DP-004 已在 dev-guide 的 `## Decisions` 段 auto-resolved；本 plan 在 Task 4/5 scope 内直接按 chosen 值实现；若 Task 6 的 chunked transfer 接受性测试失败，会触发 fix 阶段回退到 DP-003 B 选项，不在 plan 阶段额外增加 DP。）

---

## Task Dependency Graph

```
Task 1 (IR Foundation)
   ├─→ Task 2 (IR round-trip tests)
   └─→ Task 5 (Bridge refactor)

Task 3 (Streaming ResponsesClient) ──┬─→ Task 5
                                     └─→ Task 8 (streamEvents unit tests)

Task 4 (Chunked LocalHTTPServer) ─→ Task 5

Task 5 (Bridge refactor)
   ├─→ Task 6 (Streaming integration tests)
   └─→ Task 7 (Regression tests)
```

Task 1、3、4 可并行起手；Task 2 在 Task 1 完成后即可写；Task 8 在 Task 3 完成后即可写（与 Task 4/5 并行）；Task 5 需要 1+3+4 全部就绪；Task 6、7 需要 Task 5 完成。

---

## Scope Compliance Self-Check

- S1 ↔ Task 3：✔ `URLSession.bytes` 替换整包下载（perform 重构为 streamEvents 的 shim）
- S2 ↔ Task 4：✔ chunked transfer 写出 + `.data` 分支保留非 streaming callsite
- S3 ↔ Task 5：✔ `handleMessages` 改 streaming handler；`AnthropicSSEEncoder` per-event emit
- S4 ↔ Task 1：✔ `Sources/CCRouterCore/IR/` 新目录；IRBlock 七 case 全列
- S5 ↔ Task 1 + Task 5：✔ `convertContentBlocks` / `stringifyToolResultContent` 全部替换为 IR codec 函数（文本 only 行为通过 IR `.text` 保留）
- S6 ↔ Task 5：✔ `PendingToolTurn.replayIR: [IRBlock]`

无 scope inference（没有新增 UI 任务、没有改 ModelRouting、没有改 count_tokens、没有动 SubscriptionSession）。

---

## Test Coverage Matrix

| Code Type | Task | Test Location |
|-----------|------|---------------|
| Business logic — IR codec | Task 1 | Task 2 (IRBlockConversionTests) |
| Business logic — streaming dispatch | Task 5 | Task 6 (StreamingBridgeIntegrationTests) |
| Business logic — SSE line parse / error drain / cancellation | Task 3 | Task 8 (ResponsesClientStreamingTests) |
| User journey — text turn | Task 5 | Task 6 (firstContentBlockDeltaArrivesWithin50Ms, textDeltasAreEmittedIncrementally) |
| User journey — tool turn | Task 5 | Task 6 (toolUseTurnStopsWithToolUseReason) + Task 7 (bashToolTurnTwoRoundsStillClosesViaStreaming) |
| User journey — advisor bridge | Task 5 | Task 6 (advisorTurnStreamsThroughTwoPasses) + Task 7 (advisorBridgeStillSynthesizesServerToolUseAndAdvisorToolResult) |
| Infrastructure — chunked transfer headers | Task 4 | Task 6 (chunkedTransferHeadersExcludeContentLength) |
| Infrastructure — encoder state machine | Task 5 | Task 6 (toolUseBlockFollowedByMoreTextOpensNewBlockIndex, closeOpenBlockIsIdempotentAndCalledByFinish) |
| Infrastructure — error path cleanup | Task 5 | Task 6 (streamErrorPathClearsPendingToolTurn) |

无 `⚠️ No test` 跳过项。

**Note on chunked transfer real wire test:** Task 6 的 `chunkedTransferHeadersExcludeContentLength` 用单元测试断言 header 字节内容；真实 NWConnection + loopback socket + chunk 解析的端到端验证留在 **dev-guide Phase 1 Acceptance §4** 的真机 交互式 `claude` TUI（输入 prompt: `...200 words`） smoke 里（已 wire 到 dev-guide acceptance criteria，不重复写集成测试）。

---

## Verification

- **Verdict:** Approved
- **Date:** 2026-04-22
- **Cycle 1:** plan-verifier-2026-04-22-094426.md → must-revise (15 items)
- **Cycle 2:** plan-verifier-2026-04-22-100323.md → approved (all 15 resolved; 5 advisory absorbed; 1 residual doc fix applied in-place for `buildContinuationPayload` reference on former line 541)
