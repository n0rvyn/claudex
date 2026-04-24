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

    public init(
        model: String,
        max_tokens: Int?,
        messages: [AnthropicMessage],
        system: [JSONObject]?,
        tools: [JSONObject]?,
        thinking: JSONObject?,
        context_management: JSONObject?,
        metadata: JSONObject?,
        output_config: JSONObject?,
        stream: Bool?
    ) {
        self.model = model
        self.max_tokens = max_tokens
        self.messages = messages
        self.system = system
        self.tools = tools
        self.thinking = thinking
        self.context_management = context_management
        self.metadata = metadata
        self.output_config = output_config
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case model
        case max_tokens
        case messages
        case system
        case tools
        case thinking
        case context_management
        case metadata
        case output_config
        case stream
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decode(String.self, forKey: .model)
        self.max_tokens = try container.decodeIfPresent(Int.self, forKey: .max_tokens)
        self.messages = try container.decode([AnthropicMessage].self, forKey: .messages)
        self.system = try Self.decodeSystem(from: container)
        self.tools = try container.decodeIfPresent([JSONObject].self, forKey: .tools)
        self.thinking = try container.decodeIfPresent(JSONObject.self, forKey: .thinking)
        self.context_management = try container.decodeIfPresent(JSONObject.self, forKey: .context_management)
        self.metadata = try container.decodeIfPresent(JSONObject.self, forKey: .metadata)
        self.output_config = try container.decodeIfPresent(JSONObject.self, forKey: .output_config)
        self.stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
    }

    private static func decodeSystem(from container: KeyedDecodingContainer<CodingKeys>) throws -> [JSONObject]? {
        if let blocks = try? container.decodeIfPresent([JSONObject].self, forKey: .system) {
            return blocks
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: .system) {
            return [Self.textBlock(text)]
        }
        return nil
    }

    private static func textBlock(_ text: String) -> JSONObject {
        JSONObject.from([
            "type": .string("text"),
            "text": .string(text),
        ])
    }
}

public struct AnthropicMessage: Codable, Sendable {
    public let role: String
    public let content: [JSONObject]

    public init(role: String, content: [JSONObject]) {
        self.role = role
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)

        if let blocks = try? container.decode([JSONObject].self, forKey: .content) {
            self.content = blocks
            return
        }

        if let text = try? container.decode(String.self, forKey: .content) {
            self.content = [
                JSONObject.from([
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .content,
            in: container,
            debugDescription: "message.content must be a string or an array of content blocks"
        )
    }
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

public extension AnthropicMessagesRequest {
    /// Constructs a minimal text-only AnthropicMessagesRequest via raw JSON decode,
    /// sidestepping the memberwise init's 11-field requirement.
    static func textOnlyFixture(model: String) throws -> Self {
        let json = """
        {
          "model": "\(model)",
          "messages": [
            {"role": "user", "content": [{"type": "text", "text": "hi"}]}
          ],
          "stream": true
        }
        """
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}
