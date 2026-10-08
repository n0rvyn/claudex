import Foundation
import CryptoKit

/// Model-only bridge: all client tools are emitted to Claude Code for execution.
/// No tool executor, Codex subprocess, or API-key fallback exists in this module.
public actor SIWCBridge {
    private var routing: ModelRoutingTable
    private let auth: any SubscriptionSessionProviding
    private let client: any ResponsesStreamingClient
    private let counter: any AnthropicInputTokenCounting
    private let replayStore: SIWCReplayStore
    private var inflight: [String: UUID] = [:]
    public init(configuration: RouterConfiguration, auth: any SubscriptionSessionProviding = SIWCAuth.shared,
                client: any ResponsesStreamingClient = ResponsesClient(endpoint: URL(string: "https://api.openai.com/v1/responses")!),
                counter: any AnthropicInputTokenCounting = AnthropicInputTokenCounter(), replayStore: SIWCReplayStore = SIWCReplayStore()) {
        self.routing = configuration.routingTable; self.auth = auth; self.client = client; self.counter = counter; self.replayStore = replayStore
    }
    public func updateRouting(table: ModelRoutingTable, advisorRoute: ModelRoute) { routing = table }
    public func pendingToolTurnsCount() -> Int { inflight.count }
    public func doctorStatus() async -> BridgeDoctorStatus {
        do {
            _ = try await auth.loadCurrent()
            return BridgeDoctorStatus(authState: .ready, chatGPTAuthenticated: true, accountIDSuffix: nil,
                authError: nil, lastRefresh: nil, hasRefreshToken: false, accessTokenPreview: nil)
        } catch {
            return BridgeDoctorStatus(authState: .authorizationRequired, chatGPTAuthenticated: false,
                accountIDSuffix: nil, authError: error.localizedDescription, lastRefresh: nil,
                hasRefreshToken: false, accessTokenPreview: nil)
        }
    }
    public func handleCountTokens(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let input = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request.body)
            let payload = try Self.payload(input, route: routing.resolve(for: input.model))
            return try HTTPResponse.json(value: CountTokensResult(input_tokens: try await counter.countInputTokens(for: payload)))
        } catch { return Self.error(error, status: 400) }
    }
    public func handleMessages(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let input = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request.body)
            let credentials = try await auth.loadCurrent()
            let session = request.headers["x-claude-code-session-id"] ?? Self.sessionFromMetadata(input.metadata)
            guard let session, !session.isEmpty else { throw SIWCError.unsupported("Claude Code session identifier is required for stateless replay") }
            let scope = credentials.accountID + ":" + session
            let key = scope + ":" + Self.fingerprint(input.messages) + ":" + Self.contractFingerprint(input)
            try Self.validateToolHistory(input.messages)
            var route = routing.resolve(for: input.model)
            if let lastAssistantIndex = input.messages.lastIndex(where: { $0.role == "assistant" }),
               input.messages.suffix(from: lastAssistantIndex + 1).contains(where: { $0.content.contains(where: { $0.string("type") == "tool_result" }) }),
               let pending = try replayStore.load(scope + ":" + Self.fingerprint(Array(input.messages[...lastAssistantIndex]))) {
                route = pending.route
            }
            var payload = try Self.payload(input, route: route)
            var items: [JSONValue] = []
            for index in input.messages.indices {
                let prefix = Array(input.messages[...index])
                let message = input.messages[index]
                if message.role == "assistant", let cached = try replayStore.load(scope + ":" + Self.fingerprint(prefix)) {
                    items.append(contentsOf: cached.output)
                } else {
                    items.append(contentsOf: try Self.encode(message))
                }
            }
            payload["input"] = .array(items)
            let estimated = try await counter.countInputTokens(for: payload)
            try Task.checkCancellation()
            guard inflight[key] == nil else { return Self.error(SIWCError.remote("request_already_in_progress"), status: 409) }
            let leaseID = UUID(); inflight[key] = leaseID
            let stream: AsyncThrowingStream<JSONObject, Error>
            do { stream = try await client.streamEvents(request: payload, credentials: credentials, requestID: leaseID) }
            catch { inflight.removeValue(forKey: key); throw error }
            if input.stream == false {
                let writer = SIWCCollectingWriter()
                do {
                    let blocks = try await run(stream: stream, writer: writer, inputTokens: estimated, model: input.model, allowedTools: Set((input.tools ?? []).compactMap { $0.string("name") }), beforeFinish: { [self, route] blocks in
                        try await saveReplay(blocks.raw, route: route, assistant: blocks.assistant, history: input.messages, scope: scope, sessionPresent: true)
                    })
                    inflight.removeValue(forKey: key)
                    return try HTTPResponse.json(value: JSONObject.from([
                        "id": .string("msg_" + UUID().uuidString), "type": .string("message"), "role": .string("assistant"),
                        "model": .string(input.model), "content": .array(blocks.assistant.map(JSONValue.object)),
                        "stop_reason": .string(blocks.hasTools ? "tool_use" : "end_turn"), "stop_sequence": .null,
                        "usage": .object(JSONObject.from(["input_tokens": .number(Double(blocks.inputTokens)), "output_tokens": .number(Double(blocks.outputTokens))]))
                    ]))
                } catch { await client.cancelRequest(leaseID); inflight.removeValue(forKey: key); throw error }
            }
            return HTTPResponse(statusCode: 200, reasonPhrase: "OK",
                headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
                release: { [self] in
                    await client.cancelRequest(leaseID)
                    await clearInflight(key, leaseID: leaseID)
                },
                stream: { [self, route] writer in
                    do {
                        let blocks = try await run(stream: stream, writer: writer, inputTokens: estimated, model: input.model, allowedTools: Set((input.tools ?? []).compactMap { $0.string("name") }), beforeFinish: { [self, route] blocks in
                            try await saveReplay(blocks.raw, route: route, assistant: blocks.assistant, history: input.messages, scope: scope, sessionPresent: true)
                        })
                        await clearInflight(key, leaseID: leaseID)
                    } catch {
                        await client.cancelRequest(leaseID)
                        await clearInflight(key, leaseID: leaseID)
                        throw error // committed stream never emits message_stop on error/EOF
                    }
                })
        } catch {
            let status: Int
            switch error {
            case SIWCError.signInRequired, SIWCError.permissionRequired, SIWCError.invalidIdentity: status = 401
            case let http as ResponsesHTTPError: status = http.statusCode
            default: status = 400
            }
            return Self.error(error, status: status)
        }
    }
    private func clearInflight(_ key: String, leaseID: UUID) {
        if inflight[key] == leaseID { inflight.removeValue(forKey: key) }
    }
    private func saveReplay(_ raw: [JSONValue], route: ModelRoute, assistant: [JSONObject], history: [AnthropicMessage], scope: String, sessionPresent: Bool) throws {
        guard sessionPresent else { return }
        let key = scope + ":" + Self.fingerprint(history + [AnthropicMessage(role: "assistant", content: assistant)])
        try replayStore.save(SIWCReplayRecord(key: key, output: raw, route: route))
    }
    static func sessionFromMetadata(_ metadata: JSONObject?) -> String? {
        guard let user = metadata?.string("user_id") else { return nil }
        if let data = user.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONObject.self, from: data),
           let session = parsed.string("session_id"), !session.isEmpty { return session }
        if let range = user.range(of: "_session_") { return String(user[range.upperBound...]) }
        return nil
    }
    static func contractFingerprint(_ input: AnthropicMessagesRequest) -> String {
        let contract = JSONObject.from(["system": .array((input.system ?? []).map(JSONValue.object)),
            "tools": .array((input.tools ?? []).map(JSONValue.object)),
            "tool_choice": input.tool_choice.map(JSONValue.object) ?? .null])
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: (try? encoder.encode(contract)) ?? Data())).map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ messages: [AnthropicMessage]) -> String {
        let normalized = messages.map { message in
            JSONObject.from(["role": .string(message.role), "content": .array(message.content.filter {
                $0.string("type") != "thinking" && $0.string("type") != "redacted_thinking"
            }.map(JSONValue.object))])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: (try? encoder.encode(normalized)) ?? Data())).map { String(format: "%02x", $0) }.joined()
    }
    static func payload(_ input: AnthropicMessagesRequest, route: ModelRoute) throws -> JSONObject {
        var functions: [JSONObject] = [], native: [JSONObject] = []
        var names: Set<String> = []
        for tool in input.tools ?? [] {
            let type = tool.string("type") ?? "function"
            if type.hasPrefix("web_search_") || type == "web_search" {
                throw SIWCError.unsupported("native web_search result conversion; use a Claude-owned function tool")
            } else if type == "function" {
                guard let name = tool.string("name"), !name.isEmpty, names.insert(name).inserted,
                      let schema = tool.object("input_schema") ?? tool.object("parameters") else { throw SIWCError.unsupported("invalid or duplicate tool schema") }
                functions.append(JSONObject.from(["type": .string("function"), "name": .string(name),
                    "description": .string(tool.string("description") ?? ""), "parameters": .object(schema), "strict": .bool(false)]))
            } else { throw SIWCError.unsupported(type) }
        }
        if !functions.isEmpty {
            native.append(JSONObject.from(["type": .string("namespace"), "name": .string("claude"),
                "description": .string("Tools executed by Claude Code with its local permissions."), "tools": .array(functions.map(JSONValue.object))]))
        }
        let instructions = (input.system ?? []).compactMap { $0.string("text") }.joined(separator: "\n")
        var payload = JSONObject.from(["model": .string(route.upstreamModel), "instructions": .string(instructions),
            "input": .array(try input.messages.flatMap(encode)), "tools": .array(native.map(JSONValue.object)),
            "store": .bool(false), "stream": .bool(true), "parallel_tool_calls": .bool(true),
            "include": .array([.string("reasoning.encrypted_content"), .string("web_search_call.action.sources")])])
        if let choice = input.tool_choice {
            switch choice.string("type") {
            case "auto": payload["tool_choice"] = .string("auto")
            case "none": payload["tool_choice"] = .string("none")
            case "any": payload["tool_choice"] = .string("required")
            default: throw SIWCError.unsupported("named tool_choice")
            }
            if choice.bool("disable_parallel_tool_use") == true { payload["parallel_tool_calls"] = .bool(false) }
        }
        if !route.reasoningEffort.isEmpty { payload["reasoning"] = .object(JSONObject.from(["effort": .string(route.reasoningEffort)])) }
        if !route.textVerbosity.isEmpty { payload["text"] = .object(JSONObject.from(["verbosity": .string(route.textVerbosity)])) }
        return payload
    }
    static func validateToolHistory(_ messages: [AnthropicMessage]) throws {
        var pending: Set<String> = [], seen: Set<String> = []
        for message in messages {
            for block in message.content {
                if block.string("type") == "tool_use" {
                    guard message.role == "assistant", let id = block.string("id"), !id.isEmpty,
                          seen.insert(id).inserted else { throw SIWCError.unsupported("duplicate or invalid tool call ID") }
                    pending.insert(id)
                } else if block.string("type") == "tool_result" {
                    guard message.role == "user", let id = block.string("tool_use_id"), pending.remove(id) != nil else {
                        throw SIWCError.unsupported("orphaned or duplicate tool result")
                    }
                }
            }
        }
        guard pending.isEmpty else { throw SIWCError.unsupported("missing parallel tool results") }
    }

    static func validateContent(_ blocks: [JSONObject], nested: Bool = false) throws {
        for block in blocks {
            switch block.string("type") {
            case "text": guard block.string("text") != nil else { throw SIWCError.unsupported("malformed text") }
            case "image":
                guard let source = block.object("source"), source.string("type") == "base64",
                      let data = source.string("data"), !data.isEmpty, IRResponsesCodec.decodeTolerantBase64(data) != nil,
                      source.string("media_type")?.hasPrefix("image/") == true else { throw SIWCError.unsupported("image source must be valid inline base64") }
            case "tool_use" where !nested:
                guard block.string("id") != nil, block.string("name") != nil, block.object("input") != nil else { throw SIWCError.unsupported("malformed tool call") }
            case "tool_result" where !nested:
                if let content = block["content"] {
                    switch content {
                    case .string, .null: break
                    case .array(let items):
                        guard items.allSatisfy({ $0.objectValue != nil }) else { throw SIWCError.unsupported("tool result blocks") }
                        try validateContent(items.compactMap(\.objectValue), nested: true)
                    default: throw SIWCError.unsupported("tool result content")
                    }
                }
            case "thinking", "redacted_thinking":
                guard !nested else { throw SIWCError.unsupported("nested thinking block") }
            default: throw SIWCError.unsupported(block.string("type") ?? "content block")
            }
        }
    }

    static func encode(_ message: AnthropicMessage) throws -> [JSONValue] {
        guard message.role == "user" || message.role == "assistant" else { throw SIWCError.unsupported("message role") }
        try validateContent(message.content)
        var items = IRResponsesCodec.encodeFullHistory([IRMessage(role: message.role,
            content: IRAnthropicCodec.decodeRequestBlocks(message.content.filter { $0.string("type") != "thinking" && $0.string("type") != "redacted_thinking" }))])
        let errors = Set(message.content.filter { $0.string("type") == "tool_result" && $0.bool("is_error") == true }.compactMap { $0.string("tool_use_id") })
        for index in items.indices {
            if var output = items[index].objectValue, output.string("type") == "function_call_output",
               errors.contains(output.string("call_id") ?? "") {
                output["output"] = .string("Tool execution failed: " + (output.string("output") ?? ""))
                items[index] = .object(output)
            }
            if var object = items[index].objectValue, object.string("type") == "function_call" {
                object["namespace"] = .string("claude"); items[index] = .object(object)
            }
        }
        return items
    }
    private struct Result: Sendable {
        var raw: [JSONValue] = [], assistant: [JSONObject] = [], hasTools = false, inputTokens = 0, outputTokens = 0
    }
    private func run(stream: AsyncThrowingStream<JSONObject, Error>, writer: any HTTPBodyWriter, inputTokens: Int, model: String, allowedTools: Set<String>, beforeFinish: @Sendable (Result) async throws -> Void) async throws -> Result {
        try Task.checkCancellation()
        let encoder = AnthropicSSEEncoder(anthropicModel: model, writer: writer)
        try await encoder.startMessage(initialInputTokens: inputTokens)
        var result = Result(inputTokens: inputTokens)
        var completed = false
        var text = ""
        var messageText = ""
        var textIndex: Int?
        var assistantBlocks: [Int: JSONObject] = [:]
        var toolBlocks: [String: Int] = [:], toolNames: [String: String] = [:], toolCalls: [String: String] = [:]
        var received: Set<String> = []
        var callOrder: [String: Int] = [:]
        var argumentsByItem: [String: String] = [:]
        for try await event in stream {
            try Task.checkCancellation()
            let type = event.string("type") ?? ""
            switch type {
            case "response.output_text.delta", "response.refusal.delta":
                let delta = event.string("delta") ?? ""; text += delta; messageText += delta
                try await encoder.emitTextDelta(delta)
                if textIndex == nil && !delta.isEmpty { textIndex = encoder.blockIndex }
            case "response.output_item.added":
                guard let item = event.object("item"), item.string("type") == "function_call",
                      let itemID = item.string("id"), let callID = item.string("call_id"), let name = item.string("name"),
                      item.string("namespace") == "claude" else { break }
                guard allowedTools.contains(name) else { throw SIWCError.remote("undeclared_tool_call") }
                guard !received.contains(callID) else { throw SIWCError.remote("duplicate_tool_call_id") }
                received.insert(callID); toolNames[itemID] = name; toolCalls[itemID] = callID
                if !text.isEmpty, let index = textIndex {
                    assistantBlocks[index] = JSONObject.from(["type": .string("text"), "text": .string(text)])
                    text = ""; textIndex = nil
                }
                let index = try await encoder.startToolUse(id: callID, name: name)
                toolBlocks[itemID] = index; callOrder[callID] = index
            case "response.function_call_arguments.delta":
                guard let itemID = event.string("item_id"), let index = toolBlocks[itemID] else { throw SIWCError.remote("orphaned_tool_argument") }
                let delta = event.string("delta") ?? ""
                argumentsByItem[itemID, default: ""] += delta
                try await encoder.emitToolArgument(delta: delta, index: index)
            case "response.output_item.done":
                guard let item = event.object("item") else { throw SIWCError.remote("missing_output_item") }
                result.raw.append(.object(item))
                if item.string("type") == "function_call" {
                    guard let id = item.string("call_id"), let name = item.string("name"),
                          item.string("namespace") == "claude", let json = item.string("arguments"),
                          let arguments = try? JSONDecoder().decode(JSONObject.self, from: Data(json.utf8)) else { throw SIWCError.remote("invalid_tool_call") }
                    guard allowedTools.contains(name) else { throw SIWCError.remote("undeclared_tool_call") }
                    let itemID = item.string("id") ?? ""
                    if let index = toolBlocks[itemID] {
                        guard toolCalls[itemID] == id, toolNames[itemID] == name,
                              argumentsByItem[itemID, default: ""] == json else { throw SIWCError.remote("tool_identity_changed") }
                        try await encoder.stopToolUse(index: index)
                        toolBlocks.removeValue(forKey: itemID)
                    } else {
                        guard received.insert(id).inserted else { throw SIWCError.remote("duplicate_tool_call_id") }
                        if !text.isEmpty, let index = textIndex {
                            assistantBlocks[index] = JSONObject.from(["type": .string("text"), "text": .string(text)])
                            text = ""; textIndex = nil
                        }
                        try await encoder.emitToolUseBlock(id: id, name: name, argumentsJSON: json)
                        callOrder[id] = encoder.blockIndex
                    }
                    result.hasTools = true
                    assistantBlocks[callOrder[id]!] = JSONObject.from(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": .object(arguments)])
                } else if item.string("type") == "message" {
                    let finalText = (item.array("content") ?? []).compactMap { $0.objectValue?.string("text") ?? $0.objectValue?.string("refusal") }.joined()
                    if !messageText.isEmpty, messageText != finalText { throw SIWCError.remote("message_text_changed") }
                    if messageText.isEmpty {
                        text = finalText
                        if !text.isEmpty { try await encoder.emitTextDelta(text); textIndex = encoder.blockIndex }
                    }
                    if !text.isEmpty, let index = textIndex { assistantBlocks[index] = JSONObject.from(["type": .string("text"), "text": .string(text)]) }
                    text = ""; messageText = ""; textIndex = nil
                    try await encoder.closeOpenBlock()
                } else if item.string("type") == "web_search_call" {
                    throw SIWCError.unsupported("native web_search result conversion")
                }

            case "response.completed":
                completed = true
                if let usage = event.object("response")?.object("usage") {
                    result.inputTokens = usage["input_tokens"]?.intValue ?? inputTokens
                    result.outputTokens = usage["output_tokens"]?.intValue ?? 0
                }
            case "response.failed", "response.incomplete", "error":
                throw SIWCError.remote(event.object("response")?.object("error")?.string("code") ?? event.object("error")?.string("code") ?? type)
            default: break
            }
        }
        guard completed, toolBlocks.isEmpty else { throw SIWCError.remote("interrupted_stream") }
        if !text.isEmpty, let index = textIndex { assistantBlocks[index] = JSONObject.from(["type": .string("text"), "text": .string(text)]) }
        result.assistant = assistantBlocks.sorted { $0.key < $1.key }.map { $0.value }
        try Task.checkCancellation()
        try await beforeFinish(result)
        encoder.updateFinalOutputTokens(result.outputTokens)
        try await encoder.finish(stopReasonHint: result.hasTools ? .toolUse : .endTurn)
        return result
    }
    static func error(_ error: any Error, status: Int) -> HTTPResponse {
        let type = status == 401 ? "authentication_error" : "invalid_request_error"
        return try! HTTPResponse.json(statusCode: status, reasonPhrase: "Request Failed",
            value: AnthropicErrorEnvelope(error: AnthropicErrorBody(type: type, message: error.localizedDescription)))
    }
}
private actor SIWCCollectingWriter: HTTPBodyWriter {
    func write(_ chunk: Data) {}
    func finish() {}
}
