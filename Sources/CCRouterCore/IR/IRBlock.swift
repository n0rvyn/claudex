import Foundation

/// The typed, language-neutral intermediate representation for content blocks
/// flowing between Anthropic request decode, internal routing, and /responses
/// output decode.
public enum IRBlock: Sendable, Equatable {
    case text(String)
    case image(data: Data, mediaType: String)
    case toolUse(id: String, name: String, input: JSONObject)
    case toolResult(toolUseID: String, content: [IRBlock])
    case thinking(encryptedContent: Data?, summary: String?)
    case serverToolUse(id: String, name: String, input: JSONObject)
    case advisorToolResult(toolUseID: String, text: String)
    case webSearchToolResult(toolUseID: String, content: [JSONObject])
}
