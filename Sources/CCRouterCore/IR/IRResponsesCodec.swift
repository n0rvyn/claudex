import Foundation

/// Codec between typed IR and the /responses API wire format.
///
/// Handles three encoding paths (messages, top-level replay items,
/// tool-call outputs) and one decoding path (output items from
/// /responses SSE events).
public enum IRResponsesCodec {

    // MARK: - Encoding: IRMessage → /responses input

    /// Converts IR messages into /responses `input` array items.
    ///
    /// Only message-nested content (text / image) is encoded here.
    /// Tool-use / tool-result / server_tool_use / advisor_tool_result /
    /// web_search_tool_result are
    /// top-level items and must use `encodeReplayBlocks` instead.
    /// Thinking blocks at message level are skipped (reasoning items are
    /// handled by `encodeReplayBlocks`).
    public static func encodeInputItems(_ messages: [IRMessage]) -> [JSONValue] {
        messages.compactMap { message -> JSONValue? in
            // Upstream requires assistant-role message content parts to use
            // `output_text` (or `refusal`); user/system roles use `input_text`.
            // Mismatched values produce 400 "Invalid value: 'input_text'..." errors.
            let textType = message.role == "assistant" ? "output_text" : "input_text"
            let content: [JSONValue] = message.content.compactMap { block -> JSONValue? in
                switch block {
                case .text(let text):
                    return JSONObject.from([
                        "type": .string(textType),
                        "text": .string(text),
                    ]).asJSONValue

                case .image(let data, let mediaType):
                    // wire shape verified: docs/research/2026-04-22-image-wire-probe.md Row A
                    let whitelist = ["image/png", "image/jpeg", "image/webp", "image/gif"]
                    guard whitelist.contains(mediaType) else {
                        fputs("IRResponsesCodec.encodeInputItems: unsupported image media_type \(mediaType) dropped (supported: \(whitelist.joined(separator: ", ")))\n", stderr)
                        return nil
                    }
                    let base64 = data.base64EncodedString()
                    return JSONObject.from([
                        "type": .string("input_image"),
                        "image_url": .string("data:\(mediaType);base64,\(base64)"),
                    ]).asJSONValue

                case .thinking:
                    // Message-level thinking appears on the Anthropic request side
                    // only; /responses uses top-level reasoning items.
                    return nil

                case .toolUse, .toolResult, .serverToolUse, .advisorToolResult, .webSearchToolResult:
                    // These are top-level items, not message content.
                    // Caller must use encodeReplayBlocks.
                    return nil
                }
            }
            guard !content.isEmpty else { return nil }
            return JSONObject.from([
                "type": .string("message"),
                "role": .string(message.role),
                "content": .array(content),
            ]).asJSONValue
        }
    }

    // MARK: - Encoding: top-level IR blocks → /responses replay items

    /// Encodes reasoning / function_call IR blocks into /responses top-level
    /// input items (not wrapped in a message object).
    ///
    /// Filter rules:
    /// - `.thinking` → `{type:"reasoning", ...}`
    /// - `.toolUse`  → `{type:"function_call", ...}`
    /// - all other cases → skipped
    public static func encodeReplayBlocks(_ blocks: [IRBlock]) -> [JSONValue] {
        blocks.compactMap { block -> JSONValue? in
            switch block {
            case .thinking(let encryptedContent, let summary):
                let encBase64 = encryptedContent?.base64EncodedString() ?? ""
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
                return JSONObject.from([
                    "type": .string("reasoning"),
                    "encrypted_content": .string(encBase64),
                    "summary": .array(summaryList),
                ]).asJSONValue

            case .toolUse(let id, let name, let input):
                let argsString = encodeJSONObjectToString(input)
                return JSONObject.from([
                    "type": .string("function_call"),
                    "call_id": .string(id),
                    "name": .string(name),
                    "arguments": .string(argsString),
                ]).asJSONValue

            case .text, .image, .toolResult, .serverToolUse, .advisorToolResult, .webSearchToolResult:
                return nil
            }
        }
    }

    // MARK: - Encoding: IR tool results → /responses function_call_output items

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

    /// Encodes IR tool-result blocks from a continuation request into
    /// /responses `function_call_output` top-level items.
    public static func encodeToolResultOutputs(_ blocks: [IRBlock]) -> [JSONValue] {
        blocks.flatMap { block -> [JSONValue] in
            guard case .toolResult(let toolUseID, let content) = block else {
                return []
            }
            return splitToolResult(toolUseID: toolUseID, content: content)
        }
    }

    // MARK: - Decoding: /responses output item → IR

    /// Converts a /responses output item to an IR block.
    /// Recognises item.type ∈ {message, function_call, reasoning}.
    /// Returns nil for unrecognised types.
    public static func decodeOutputItem(_ item: JSONObject) -> IRBlock? {
        switch item.string("type") {
        case "message":
            let parts = item.array("content")?.compactMap(\.objectValue) ?? []
            let texts = parts.compactMap { part -> String? in
                guard part.string("type") == "output_text" || part.string("type") == "text" else {
                    return nil
                }
                return part.string("text")
            }
            let text = texts.joined(separator: "")
            return .text(text)

        case "function_call":
            guard let callID = item.string("call_id") else { return nil }
            let name = item.string("name") ?? "tool"
            let argumentsString = item.string("arguments") ?? "{}"
            let input = decodeArgumentsJSON(argumentsString)
            return .toolUse(id: callID, name: name, input: input)

        case "reasoning":
            let encBase64 = item.string("encrypted_content") ?? ""
            // Upstream emits encrypted_content as URL-safe base64 (`-`/`_` instead of
            // `+`/`/`). Swift's Data(base64Encoded:) only accepts standard base64 —
            // even with .ignoreUnknownCharacters, URL-safe chars are skipped, producing
            // a corrupt-length string and a nil result. Translate before decoding.
            let encryptedContent = Self.decodeTolerantBase64(encBase64)
            let summary = Self.flattenReasoningSummary(item["summary"])
            return .thinking(encryptedContent: encryptedContent, summary: summary)

        default:
            return nil
        }
    }

    // MARK: - Encoding: full history → /responses input (temporal interleaving)

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

            // Role-aware text type: assistant → output_text, others → input_text.
            // See encodeInputItems for rationale.
            let textType = message.role == "assistant" ? "output_text" : "input_text"
            for block in message.content {
                switch block {
                case .text(let text):
                    pendingContent.append(JSONObject.from([
                        "type": .string(textType),
                        "text": .string(text),
                    ]).asJSONValue)
                case .image:
                    // Single-block image encoding is delegated to encodeInputItems to keep
                    // wire shape defined in one place (Task 8). Changes to image shape must
                    // update only encodeInputItems.
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
                case .serverToolUse, .advisorToolResult, .webSearchToolResult:
                    // Bridge-synthesized only; should not appear in client request history.
                    break
                }
            }
            flushPending()
        }
        return result
    }

    // MARK: - Private helpers

    /// Decodes a base64 string tolerant of both standard (`+`/`/`) and URL-safe
    /// (`-`/`_`) alphabets. Swift's built-in Data(base64Encoded:) only handles
    /// the standard alphabet; upstream /responses emits URL-safe base64 for
    /// `encrypted_content`, and Claude CLI's `signature` field round-trips that
    /// encoding verbatim. Also strips whitespace/newlines via
    /// .ignoreUnknownCharacters after remapping so benign line breaks are OK.
    static func decodeTolerantBase64(_ input: String) -> Data? {
        guard !input.isEmpty else { return nil }
        // Strip whitespace first so padding arithmetic sees only real base64 chars.
        let compacted = input.filter { !$0.isWhitespace }
        var s = compacted
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad if needed; URL-safe encodings sometimes omit trailing `=`.
        let rem = s.count % 4
        if rem != 0 {
            s.append(String(repeating: "=", count: 4 - rem))
        }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

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

    /// Parses a JSON string into a JSONObject.
    /// Returns empty JSONObject on failure (invalid JSON, or non-object root).
    private static func decodeArgumentsJSON(_ str: String) -> JSONObject {
        guard !str.isEmpty else { return JSONObject() }
        guard let data = str.data(using: .utf8) else { return JSONObject() }
        guard let decoded = try? JSONDecoder().decode(JSONObject.self, from: data) else {
            return JSONObject()
        }
        return decoded
    }

    /// Serialises a JSONObject to a JSON string.
    private static func encodeJSONObjectToString(_ object: JSONObject) -> String {
        guard let data = try? JSONEncoder().encode(object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - JSONValue → JSONObject helper

private extension JSONObject {
    var asJSONValue: JSONValue {
        .object(self)
    }
}
