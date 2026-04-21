import Foundation

public struct AnthropicMessagesRequest: Codable, Sendable {
    public let model: String
    public let max_tokens: Int?
    public let messages: [AnthropicMessage]
    public let system: [JSONObject]?
    public let tools: [JSONObject]?
    public let thinking: JSONObject?
    public let context_management: JSONObject?
    public let metadata: JSONObject?
    public let output_config: JSONObject?
    public let stream: Bool?
}

public struct AnthropicMessage: Codable, Sendable {
    public let role: String
    public let content: [JSONObject]
}

public struct AnthropicErrorEnvelope: Codable, Sendable {
    public let type: String
    public let error: AnthropicErrorBody

    public init(error: AnthropicErrorBody) {
        self.type = "error"
        self.error = error
    }
}

public struct AnthropicErrorBody: Codable, Sendable {
    public let type: String
    public let message: String

    public init(type: String, message: String) {
        self.type = type
        self.message = message
    }
}

public extension JSONObject {
    var blockType: String? { string("type") }
    var textValue: String? { string("text") }
}
