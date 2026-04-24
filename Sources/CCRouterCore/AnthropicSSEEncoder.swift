import Foundation

/// Encodes a stream of IR blocks as Anthropic SSE frames.
///
/// `AnthropicSSEEncoder` is stateful: it tracks which content block is open so
/// that `emitTextDelta` can append to an existing block or open a new one, and
/// so that `finish` can emit `content_block_stop` for any block left open by a
/// stream that ended without sending `response.output_item.done`.
///
/// All methods are `async throws` because they may write to the `HTTPBodyWriter`.
/// The class is marked `@unchecked Sendable`; the caller guarantees it is
/// used serially within a single task (enforced by the design: each streaming
/// turn uses one encoder instance in one Task).
final class AnthropicSSEEncoder: @unchecked Sendable {
    private let anthropicModel: String
    private let writer: HTTPBodyWriter
    private let encoder = JSONEncoder()
    private var messageStarted = false
    private var currentBlockIndex = -1
    private var currentBlockKind: BlockKind? = nil
    private var finalOutputTokens = 0

    enum BlockKind: Equatable { case text, toolUse, serverToolUse, advisorToolResult, webSearchToolResult, thinking }
    enum StopReasonHint { case endTurn, toolUse, advisor }

    init(anthropicModel: String, writer: HTTPBodyWriter, encoder: JSONEncoder = JSONEncoder()) {
        self.anthropicModel = anthropicModel
        self.writer = writer
    }

    // MARK: - Public API

    /// Emits `message_start`. Idempotent if called twice.
    func startMessage(initialInputTokens: Int) async throws {
        guard !messageStarted else { return }
        try await send(event: "message_start", data: JSONObject.from([
            "type": .string("message_start"),
            "message": .object(JSONObject.from([
                "id": .string("msg_\(UUID().uuidString.lowercased())"),
                "type": .string("message"),
                "role": .string("assistant"),
                "model": .string(anthropicModel),
                "content": .array([]),
                "stop_reason": .null,
                "stop_sequence": .null,
                "usage": .object(JSONObject.from([
                    "input_tokens": .number(Double(max(1, initialInputTokens))),
                    "output_tokens": .number(1),
                ])),
            ])),
        ]))
        messageStarted = true
    }

    /// Appends text to the current or a new text block.
    func emitTextDelta(_ delta: String) async throws {
        if currentBlockKind != .text {
            try await closeOpenBlock()
            currentBlockIndex += 1
            try await send(event: "content_block_start", data: JSONObject.from([
                "type": .string("content_block_start"),
                "index": .number(Double(currentBlockIndex)),
                "content_block": .object(JSONObject.from([
                    "type": .string("text"),
                    "text": .string(""),
                ])),
            ]))
            currentBlockKind = .text
        }
        try await send(event: "content_block_delta", data: JSONObject.from([
            "type": .string("content_block_delta"),
            "index": .number(Double(currentBlockIndex)),
            "delta": .object(JSONObject.from([
                "type": .string("text_delta"),
                "text": .string(delta),
            ])),
        ]))
    }

    /// Emits a complete tool-use content block as three frames:
    /// content_block_start → content_block_delta(input_json_delta) → content_block_stop.
    func emitToolUseBlock(id: String, name: String, argumentsJSON: String) async throws {
        try await closeOpenBlock()
        currentBlockIndex += 1
        try await send(event: "content_block_start", data: JSONObject.from([
            "type": .string("content_block_start"),
            "index": .number(Double(currentBlockIndex)),
            "content_block": .object(JSONObject.from([
                "type": .string("tool_use"),
                "id": .string(id),
                "name": .string(name),
                "input": .object(JSONObject()),
            ])),
        ]))
        try await send(event: "content_block_delta", data: JSONObject.from([
            "type": .string("content_block_delta"),
            "index": .number(Double(currentBlockIndex)),
            "delta": .object(JSONObject.from([
                "type": .string("input_json_delta"),
                "partial_json": .string(argumentsJSON),
            ])),
        ]))
        try await send(event: "content_block_stop", data: JSONObject.from([
            "type": .string("content_block_stop"),
            "index": .number(Double(currentBlockIndex)),
        ]))
        currentBlockKind = nil
    }

    /// Emits a complete server-tool-use block (used for advisor bridge).
    func emitServerToolUseBlock(id: String, name: String, input: JSONObject) async throws {
        try await closeOpenBlock()
        currentBlockIndex += 1
        guard let contentBlock = IRAnthropicCodec.encodeResponseBlock(.serverToolUse(id: id, name: name, input: input)) else {
            return
        }
        try await send(event: "content_block_start", data: JSONObject.from([
            "type": .string("content_block_start"),
            "index": .number(Double(currentBlockIndex)),
            "content_block": .object(contentBlock),
        ]))
        try await send(event: "content_block_stop", data: JSONObject.from([
            "type": .string("content_block_stop"),
            "index": .number(Double(currentBlockIndex)),
        ]))
        currentBlockKind = nil
    }

    /// Emits a complete advisor-tool-result block.
    func emitAdvisorToolResultBlock(toolUseID: String, text: String) async throws {
        try await closeOpenBlock()
        currentBlockIndex += 1
        guard let contentBlock = IRAnthropicCodec.encodeResponseBlock(.advisorToolResult(toolUseID: toolUseID, text: text)) else {
            return
        }
        try await send(event: "content_block_start", data: JSONObject.from([
            "type": .string("content_block_start"),
            "index": .number(Double(currentBlockIndex)),
            "content_block": .object(contentBlock),
        ]))
        try await send(event: "content_block_stop", data: JSONObject.from([
            "type": .string("content_block_stop"),
            "index": .number(Double(currentBlockIndex)),
        ]))
        currentBlockKind = nil
    }

    /// Emits a complete web-search-tool-result block.
    func emitWebSearchToolResultBlock(toolUseID: String, content: [JSONObject]) async throws {
        try await closeOpenBlock()
        currentBlockIndex += 1
        guard let contentBlock = IRAnthropicCodec.encodeResponseBlock(.webSearchToolResult(toolUseID: toolUseID, content: content)) else {
            return
        }
        try await send(event: "content_block_start", data: JSONObject.from([
            "type": .string("content_block_start"),
            "index": .number(Double(currentBlockIndex)),
            "content_block": .object(contentBlock),
        ]))
        try await send(event: "content_block_stop", data: JSONObject.from([
            "type": .string("content_block_stop"),
            "index": .number(Double(currentBlockIndex)),
        ]))
        currentBlockKind = nil
    }

    /// Emits a complete thinking block (Phase 1: summary text only, no signature).
    func emitThinkingBlock(encryptedContent: Data?, summary: String?) async throws {
        try await closeOpenBlock()
        currentBlockIndex += 1
        guard let contentBlock = IRAnthropicCodec.encodeResponseBlock(.thinking(encryptedContent: encryptedContent, summary: summary)) else {
            return
        }
        try await send(event: "content_block_start", data: JSONObject.from([
            "type": .string("content_block_start"),
            "index": .number(Double(currentBlockIndex)),
            "content_block": .object(contentBlock),
        ]))
        try await send(event: "content_block_stop", data: JSONObject.from([
            "type": .string("content_block_stop"),
            "index": .number(Double(currentBlockIndex)),
        ]))
        currentBlockKind = nil
    }

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

    /// Closes any open content block (idempotent).
    func closeOpenBlock() async throws {
        guard currentBlockKind != nil else { return }
        try await send(event: "content_block_stop", data: JSONObject.from([
            "type": .string("content_block_stop"),
            "index": .number(Double(currentBlockIndex)),
        ]))
        currentBlockKind = nil
    }

    /// Records the final output token count; emitted inside `finish`.
    func updateFinalOutputTokens(_ value: Int) {
        finalOutputTokens = value
    }

    /// Must be called last. Closes any open block, then emits message_delta and
    /// message_stop. Calls closeOpenBlock first so missing upstream output_item.done
    /// does not leave an unterminated block.
    func finish(stopReasonHint: StopReasonHint) async throws {
        try await closeOpenBlock()

        let stopReason: String
        switch stopReasonHint {
        case .endTurn:  stopReason = "end_turn"
        case .toolUse:  stopReason = "tool_use"
        case .advisor:  stopReason = "end_turn"
        }

        try await send(event: "message_delta", data: JSONObject.from([
            "type": .string("message_delta"),
            "delta": .object(JSONObject.from([
                "stop_reason": .string(stopReason),
                "stop_sequence": .null,
            ])),
            "usage": .object(JSONObject.from([
                "output_tokens": .number(Double(max(1, finalOutputTokens))),
            ])),
        ]))
        try await send(event: "message_stop", data: JSONObject.from(["type": .string("message_stop")]))
    }

    // MARK: - Private helpers

    private func send(event: String, data: JSONObject) async throws {
        let json = try encoder.encode(data)
        var payload = Data("event: \(event)\n".utf8)
        payload.append(Data("data: ".utf8))
        payload.append(json)
        payload.append(Data("\n\n".utf8))
        try await writer.write(payload)
    }
}
