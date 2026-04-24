import Foundation

/// Bidirectional codec between Anthropic wire JSON and typed IR blocks.
///
/// Decoding direction: Anthropic wire → IR (for inbound /v1/messages requests).
/// Encoding direction: IR → Anthropic wire (for outbound SSE frames sent to Claude CLI).
public enum IRAnthropicCodec {

    // MARK: - Decoding (Anthropic wire → IR)

    /// Converts an array of Anthropic request content blocks into IR blocks.
    /// Unknown block types are silently dropped (decoder does not throw).
    public static func decodeRequestBlocks(_ blocks: [JSONObject]) -> [IRBlock] {
        blocks.compactMap { block -> IRBlock? in
            switch block.string("type") {
            case "text":
                guard let text = block.string("text") else { return nil }
                return .text(text)

            case "image":
                guard let source = block.object("source") else { return nil }
                guard source.string("type") == "base64" else { return nil }
                guard let mediaType = source.string("media_type") else { return nil }
                guard let base64String = source.string("data") else { return nil }
                guard let data = IRResponsesCodec.decodeTolerantBase64(base64String) else { return nil }
                return .image(data: data, mediaType: mediaType)

            case "tool_use":
                guard let id = block.string("id") else { return nil }
                guard let name = block.string("name") else { return nil }
                let input = block.object("input") ?? JSONObject()
                return .toolUse(id: id, name: name, input: input)

            case "tool_result":
                guard let toolUseID = block.string("tool_use_id") else { return nil }
                let content: [IRBlock]
                if let contentValue = block["content"] {
                    switch contentValue {
                    case .string(let stringValue):
                        content = [.text(stringValue)]
                    case .array(let items):
                        // Recurse: inner blocks only support text/image
                        content = decodeRequestBlocks(items.compactMap(\.objectValue))
                    case .null, .object, .number, .bool:
                        content = []
                    }
                } else {
                    content = []
                }
                return .toolResult(toolUseID: toolUseID, content: content)

            case "server_tool_use":
                guard let id = block.string("id") else { return nil }
                guard let name = block.string("name") else { return nil }
                let input = block.object("input") ?? JSONObject()
                return .serverToolUse(id: id, name: name, input: input)

            case "web_search_tool_result":
                guard let toolUseID = block.string("tool_use_id") else { return nil }
                let content: [JSONObject]
                switch block["content"] {
                case .array(let items):
                    content = items.compactMap(\.objectValue)
                case .object(let object):
                    content = [object]
                case .string, .number, .bool, .null, .none:
                    content = []
                }
                return .webSearchToolResult(toolUseID: toolUseID, content: content)

            case "thinking":
                // signature ↔ encrypted_content roundtrip (Phase 3 scheme E; crystal [D-005])
                let summary = block.string("thinking")
                let signatureString = block.string("signature")
                let encryptedContent: Data?
                if let signatureString, !signatureString.isEmpty,
                   let decoded = IRResponsesCodec.decodeTolerantBase64(signatureString) {
                    encryptedContent = decoded
                } else {
                    encryptedContent = nil
                }
                return .thinking(encryptedContent: encryptedContent, summary: summary)

            default:
                return nil
            }
        }
    }

    // MARK: - Encoding (IR → Anthropic wire)

    /// Encodes a single IR block to an Anthropic wire content_block JSONObject.
    /// Returns nil for block types that do not appear in SSE response output
    /// (e.g. image, toolResult — they are input-only shapes).
    public static func encodeResponseBlock(_ ir: IRBlock) -> JSONObject? {
        switch ir {
        case .text(let text):
            return JSONObject.from([
                "type": .string("text"),
                "text": .string(text),
            ])

        case .toolUse(let id, let name, let input):
            return JSONObject.from([
                "type": .string("tool_use"),
                "id": .string(id),
                "name": .string(name),
                "input": .object(input),
            ])

        case .serverToolUse(let id, let name, let input):
            return JSONObject.from([
                "type": .string("server_tool_use"),
                "id": .string(id),
                "name": .string(name),
                "input": .object(input),
            ])

        case .advisorToolResult(let toolUseID, let text):
            return JSONObject.from([
                "type": .string("advisor_tool_result"),
                "tool_use_id": .string(toolUseID),
                "content": .object(JSONObject.from([
                    "type": .string("advisor_result"),
                    "text": .string(text),
                ])),
            ])

        case .webSearchToolResult(let toolUseID, let content):
            return JSONObject.from([
                "type": .string("web_search_tool_result"),
                "tool_use_id": .string(toolUseID),
                "content": .array(content.map(JSONValue.object)),
            ])

        case .thinking(let encryptedContent, let summary):
            // signature = base64(encrypted_content) for E-scheme roundtrip; omitted
            // when nil so replay path naturally drops per [D-006]
            var fields: [String: JSONValue] = [
                "type": .string("thinking"),
                "thinking": .string(summary ?? ""),
            ]
            if let encryptedContent, !encryptedContent.isEmpty {
                fields["signature"] = .string(encryptedContent.base64EncodedString())
            }
            return JSONObject.from(fields)

        case .image, .toolResult:
            // These types do not appear in SSE response output frames.
            // Log a warning via stderr for visibility during Phase 1 development.
            fputs("IRAnthropicCodec.encodeResponseBlock: unexpected block type \(String(describing: ir)) — returning nil\n", stderr)
            return nil
        }
    }
}
