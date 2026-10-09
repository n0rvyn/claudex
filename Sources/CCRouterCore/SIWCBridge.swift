import Foundation
import CryptoKit

/// Model-only bridge: all client tools are emitted to Claude Code for execution.
/// No tool executor, Codex subprocess, or API-key fallback exists in this module.
public actor SIWCBridge {
    public typealias CatalogProvider = @Sendable (String) async throws -> SIWCModelCatalogSnapshot
    private let catalogProvider: CatalogProvider
    private var routing: ModelRoutingTable
    private var configuredAdvisorRoute: ModelRoute
    private let auth: any SubscriptionSessionProviding
    private let client: any ResponsesStreamingClient
    private let advisorClient: any ResponsesStreamingClient
    private let traffic: SIWCTraffic
    private let counter: any AnthropicInputTokenCounting
    private let replayStore: SIWCReplayStore
    private var inflight: [String: UUID] = [:]
    public init(configuration: RouterConfiguration, auth: any SubscriptionSessionProviding = SIWCAuth.shared,
                client: any ResponsesStreamingClient = ResponsesClient(endpoint: URL(string: "https://api.openai.com/v1/responses")!),
                counter: any AnthropicInputTokenCounting = AnthropicInputTokenCounter(), replayStore: SIWCReplayStore = SIWCReplayStore(),
                catalogProvider: @escaping CatalogProvider = { try await SIWCModelCatalog().runtimeSnapshot(accountID: $0) }) {
        self.catalogProvider = catalogProvider
        let traffic = SIWCTraffic(directory: replayStore.directory)
        self.traffic = traffic
        self.client = TrafficResponsesClient(base: client, traffic: traffic, role: "executor")
        self.advisorClient = TrafficResponsesClient(base: client, traffic: traffic, role: "advisor")
        self.routing = configuration.routingTable; self.auth = auth; self.counter = counter; self.replayStore = replayStore
        self.configuredAdvisorRoute = configuration.advisorRoute
    }
    public func updateRouting(table: ModelRoutingTable, advisorRoute: ModelRoute) { routing = table; configuredAdvisorRoute = advisorRoute }
    public func recordLocalAuthRejection() async {
        let id = UUID(), start = Date()
        await traffic.gatewayRequest(id: id)
        await traffic.gatewayFinished(id: id, started: start, failed: true)
    }
    public func trafficSnapshot() async -> SIWCTrafficSnapshot { await traffic.snapshot() }
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
            try Self.validateSystemTurns(input.messages, headers: request.headers)
            let policy = routing
            let effort = try EffortPolicy.clientEffort(input, headers: request.headers)
            if policy.allowClientEffort == true { try EffortPolicy.validateAdjustment(requested: effort, thinking: input.thinking) }
            var route = policy.resolve(for: input.model)
            if policy.allowClientEffort == true {
                let credentials = try await auth.loadCurrent()
                route = try EffortPolicy.resolve(route: route, requested: effort, thinking: input.thinking, catalog: await catalogProvider(credentials.accountID), accountID: credentials.accountID)
            }
            let payload = try Self.payload(input, route: route)
            return try HTTPResponse.json(value: CountTokensResult(input_tokens: try await counter.countInputTokens(for: payload)))
        } catch { return Self.error(error, status: 400) }
    }
    public func handleMessages(_ request: HTTPRequest) async -> HTTPResponse {
        let observationID = UUID(), observationStarted = Date()
        await traffic.gatewayRequest(id: observationID)
        do {
            let input = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request.body)
            try await AcceptanceInferenceGuard.shared.observeIngress(input, headers: request.headers)
            try Self.validateSystemTurns(input.messages, headers: request.headers)
            let policy = routing
            let credentials = try await auth.loadCurrent()
            let session = request.headers["x-claude-code-session-id"] ?? Self.sessionFromMetadata(input.metadata)
            guard let session, !session.isEmpty else { throw SIWCError.unsupported("Claude Code session identifier is required for stateless replay") }
            let scope = credentials.accountID + ":" + session
            let key = scope + ":" + Self.fingerprint(input.messages) + ":" + Self.contractFingerprint(input)
            try Self.validateToolHistory(input.messages)
            let effort = try EffortPolicy.clientEffort(input, headers: request.headers)
            if policy.allowClientEffort == true { try EffortPolicy.validateAdjustment(requested: effort, thinking: input.thinking) }
            var route = policy.resolve(for: input.model)
            var continuationPinned = false
            var pinnedAdvisorRoute: ModelRoute?
            if let lastAssistantIndex = input.messages.lastIndex(where: { $0.role == "assistant" }),
               input.messages.suffix(from: lastAssistantIndex + 1).contains(where: { $0.content.contains(where: { $0.string("type") == "tool_result" }) }) {
                guard let pending = try await loadReplay(Array(input.messages[...lastAssistantIndex]), scope: scope) else {
                    throw SIWCError.remote("tool_continuation_replay_missing: restart from a user turn or restore the original tool history")
                }
                route = pending.route
                pinnedAdvisorRoute = pending.advisorRoute
                continuationPinned = true
            }
            if !continuationPinned, policy.allowClientEffort == true {
                route = try EffortPolicy.resolve(route: route, requested: effort, thinking: input.thinking, catalog: await catalogProvider(credentials.accountID), accountID: credentials.accountID)
            }
            await ClassifierDiagnostics.resolved(route)
            var payload = try Self.payload(input, route: route)
            let advisor = try Self.effectiveTools(input).first(where: { $0.string("type") == "advisor_20260301" }).map(SIWCAdvisor.init)
            let advisorRoute = advisor == nil ? nil : (pinnedAdvisorRoute ?? configuredAdvisorRoute)
            let allowedTools = Self.functionNames(payload)
            var items: [JSONValue] = []
            for index in input.messages.indices {
                let prefix = Array(input.messages[...index])
                let message = input.messages[index]
                if Self.expiredSystemTurn(index, in: input.messages) { continue }
                if message.role == "assistant", let cached = try await loadReplay(prefix, scope: scope) {
                    items.append(contentsOf: cached.output)
                } else {
                    items.append(contentsOf: try Self.encode(message))
                }
            }
            payload["input"] = .array(items)
            let estimated = try await counter.countInputTokens(for: payload)
            try Task.checkCancellation()
            guard inflight[key] == nil else {
                await traffic.gatewayFinished(id: observationID, started: observationStarted, failed: true)
                return Self.error(SIWCError.remote("request_already_in_progress"), status: 409)
            }
            let leaseID = UUID(); inflight[key] = leaseID
            let stream: AsyncThrowingStream<JSONObject, Error>
            do {
                let initial = try await client.streamEvents(request: payload, credentials: credentials, requestID: leaseID)
                if let advisor, let advisorRoute {
                    stream = advisor.transform(initial, payload: payload, route: advisorRoute, client: client, advisorClient: advisorClient, credentials: credentials, requestID: leaseID)
                } else { stream = initial }
            }
            catch { inflight.removeValue(forKey: key); throw error }
            // Anthropic Messages defaults to a buffered Message when stream is omitted.
            // Claude Code's classifier fallback omits it and parses JSON, not SSE.
            if input.stream != true {
                let writer = SIWCCollectingWriter()
                do {
                    let blocks = try await run(stream: stream, writer: writer, inputTokens: estimated, model: input.model, allowedTools: allowedTools, beforeFinish: { [self, route] blocks in
                        try await saveReplay(blocks.raw, route: route, advisorRoute: advisorRoute, assistant: blocks.assistant, history: input.messages, scope: scope, sessionPresent: true)
                    })
                    inflight.removeValue(forKey: key)
                    await traffic.gatewayFinished(id: observationID, started: observationStarted, failed: false)
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
                    await traffic.gatewayFinished(id: observationID, started: observationStarted, failed: false, cancelled: true)
                },
                stream: { [self, route] writer in
                    do {
                        _ = try await run(stream: stream, writer: writer, inputTokens: estimated, model: input.model, allowedTools: allowedTools, beforeFinish: { [self, route] blocks in
                            try await saveReplay(blocks.raw, route: route, advisorRoute: advisorRoute, assistant: blocks.assistant, history: input.messages, scope: scope, sessionPresent: true)
                        })
                        await clearInflight(key, leaseID: leaseID)
                        await traffic.gatewayFinished(id: observationID, started: observationStarted, failed: false)
                    } catch {
                        await client.cancelRequest(leaseID)
                        await clearInflight(key, leaseID: leaseID)
                        await traffic.gatewayFinished(id: observationID, started: observationStarted, failed: !(error is CancellationError), cancelled: error is CancellationError)
                        if Self.isContextLimitError(error), let body = Self.error(error, status: 400).bodyData {
                            var frame = Data("event: error\ndata: ".utf8)
                            frame.append(body); frame.append(Data("\n\n".utf8))
                            try await writer.write(frame)
                        }
                        throw error // committed stream never emits message_stop on error/EOF
                    }
                })
        } catch {
            await traffic.gatewayFinished(id: observationID, started: observationStarted, failed: !(error is CancellationError), cancelled: error is CancellationError)
            let status: Int
            switch error {
            case SIWCError.signInRequired, SIWCError.permissionRequired, SIWCError.invalidIdentity: status = 401
            case let http as ResponsesHTTPError: status = http.statusCode
            default: status = 400
            }
            await ClassifierDiagnostics.log(JSONObject.from(["event": .string("bridge_failure"), "status": .number(Double(status)), "error_category": .string(ClassifierDiagnostics.category(error))]))
            return Self.error(error, status: status)
        }
    }
    private func clearInflight(_ key: String, leaseID: UUID) {
        if inflight[key] == leaseID { inflight.removeValue(forKey: key) }
    }
    private func saveReplay(_ raw: [JSONValue], route: ModelRoute, advisorRoute: ModelRoute?, assistant: [JSONObject], history: [AnthropicMessage], scope: String, sessionPresent: Bool) async throws {
        guard sessionPresent else { return }
        let key = scope + ":" + Self.fingerprint(history + [AnthropicMessage(role: "assistant", content: assistant)])
        try replayStore.save(SIWCReplayRecord(key: key, output: raw, route: route, advisorRoute: advisorRoute, assistantFingerprint: Self.fingerprint([AnthropicMessage(role: "assistant", content: assistant)])))
        try await AcceptanceInferenceGuard.shared.observeReplay(history + [AnthropicMessage(role: "assistant", content: assistant)], scope: scope, stage: "save", cacheHit: true)

    }
    private func loadReplay(_ history: [AnthropicMessage], scope: String) async throws -> SIWCReplayRecord? {
        let canonical = Self.fingerprint(history)
        var record = try replayStore.load(scope + ":" + canonical)
        let legacy = Self.legacyFingerprint(history)
        // Legacy parsing did not retain clear_at. Never let an exact old
        // hash alias a new temporary instruction boundary.
        if record == nil, legacy != canonical, history.allSatisfy({ $0.clear_at == nil }) {
            record = try replayStore.load(scope + ":" + legacy)
        }
        // Installed Claude Code's native compaction summary replaces the prefix.
        // It is a format signal, not authority: exact complete assistant identity,
        // account/session scope and uniqueness are still mandatory.
        if record == nil, let assistant = history.last, assistant.role == "assistant",
           history.allSatisfy({ $0.clear_at == nil }),
           history.first?.role == "user",
           history.first?.content.contains(where: {
               $0.string("type") == "text" && ($0.string("text") ?? "").hasPrefix("This session is being continued from a previous conversation that ran out of context.")
           }) == true {
            record = try replayStore.compactedReplay(scope: scope, assistant: assistant)
        }
        try await AcceptanceInferenceGuard.shared.observeReplay(history, scope: scope, stage: "load", cacheHit: record != nil)
        return record
    }
    static func sessionFromMetadata(_ metadata: JSONObject?) -> String? {
        guard let user = metadata?.string("user_id") else { return nil }
        if let data = user.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONObject.self, from: data),
           let session = parsed.string("session_id"), !session.isEmpty { return session }
        if let range = user.range(of: "_session_") { return String(user[range.upperBound...]) }
        return nil
    }
    static func contractFingerprint(_ input: AnthropicMessagesRequest) -> String {
        var contract = JSONObject.from(["system": .array((input.system ?? []).map(JSONValue.object)),
            "tools": .array((input.tools ?? []).map(JSONValue.object)),
            "tool_choice": input.tool_choice.map(JSONValue.object) ?? .null])
        if let effort = input.output_config { contract["output_config"] = .object(effort) }
        if let thinking = input.thinking { contract["thinking"] = .object(thinking) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: (try? encoder.encode(contract)) ?? Data())).map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ messages: [AnthropicMessage]) -> String {
        historyFingerprint(messages, normalizeCache: true)
    }
    // Exact old wire fingerprint only. Never search other branches or tool IDs.
    static func legacyFingerprint(_ messages: [AnthropicMessage]) -> String {
        historyFingerprint(messages, normalizeCache: false)
    }
    private static func canonicalReplayBlock(_ block: JSONObject) -> JSONObject {
        var value = block
        value["cache_control"] = nil
        // Tool arguments are arbitrary user data. Only nested protocol content
        // blocks may carry cache annotations; never traverse tool input objects.
        if value.string("type") == "tool_result", let content = value.array("content") {
            value["content"] = .array(content.map { item in
                item.objectValue.map { .object(canonicalReplayBlock($0)) } ?? item
            })
        }
        return value
    }
    private static func historyFingerprint(_ messages: [AnthropicMessage], normalizeCache: Bool) -> String {
        let normalized = messages.map { message in
            var value = JSONObject.from(["role": .string(message.role), "content": .array(message.content.filter {
                $0.string("type") != "thinking" && $0.string("type") != "redacted_thinking"
            }.map { .object(normalizeCache ? canonicalReplayBlock($0) : $0) })])
            if let control = message.output_config { value["output_config"] = .object(control) }
            if normalizeCache, let clear = message.clear_at { value["clear_at"] = .string(clear) }
            return value
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: (try? encoder.encode(normalized)) ?? Data())).map { String(format: "%02x", $0) }.joined()
    }
    static func payload(_ input: AnthropicMessagesRequest, route: ModelRoute) throws -> JSONObject {
        var functions: [JSONObject] = [], native: [JSONObject] = []
        var names: Set<String> = []
        for tool in try Self.effectiveTools(input) {
            let type = tool.string("type") ?? "function"
            if type == "advisor_20260301" {
                native.append(try SIWCAdvisor(tool).tool)
            } else if type.hasPrefix("web_search_") || type == "web_search" {
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
            "input": .array(try input.messages.indices.flatMap { expiredSystemTurn($0, in: input.messages) ? [] : try encode(input.messages[$0]) }), "tools": .array(native.map(JSONValue.object)),
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
    static func validateSystemContent(_ blocks: [JSONObject]) throws {
        for block in blocks {
            switch block.string("type") {
            case "text":
                guard Set(block.values.keys).isSubset(of: ["type", "text", "cache_control"]), block.string("text") != nil else { throw SIWCError.unsupported("system text content") }
            case "tool_addition", "tool_removal":
                guard Set(block.values.keys).isSubset(of: ["type", "tool", "cache_control"]), let tool = block.object("tool") else { throw SIWCError.unsupported("system tool change") }
                switch tool.string("type") {
                case "tool_reference":
                    guard Set(tool.values.keys) == Set(["type", "name"]), let name = tool.string("name"), !name.isEmpty else { throw SIWCError.unsupported("malformed tool reference") }
                case "tool_definition" where block.string("type") == "tool_addition":
                    guard Set(tool.values.keys) == Set(["type", "definition"]), tool.object("definition") != nil else { throw SIWCError.unsupported("malformed tool definition") }
                default: throw SIWCError.unsupported("system tool change representation")
                }
            default: throw SIWCError.unsupported("system content type")
            }
        }
    }
    static func validateSystemTurns(_ messages: [AnthropicMessage], headers: [String: String]) throws {
        let betas = Set((headers["anthropic-beta"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        for message in messages {
            if message.clear_at != nil {
                guard message.role == "system", message.clear_at == "next_user_message", message.output_config == nil,
                      message.content.allSatisfy({ $0.string("type") == "text" }) else { throw SIWCError.unsupported("temporary system turn") }
            }
            guard message.role == "system" else { continue }
            if !message.content.isEmpty || message.clear_at != nil {
                guard betas.contains(EffortPolicy.systemMessageBeta) else { throw SIWCError.unsupported("mid-conversation system beta is required") }
            }
            try validateSystemContent(message.content)
            if message.content.contains(where: { ["tool_addition", "tool_removal"].contains($0.string("type") ?? "") }) {
                guard betas.contains(EffortPolicy.toolChangesBeta) else { throw SIWCError.unsupported("mid-conversation tool changes beta is required") }
            }
        }
    }
    private static func expiredSystemTurn(_ index: Int, in messages: [AnthropicMessage]) -> Bool {
        messages[index].role == "system" && messages[index].clear_at == "next_user_message"
            && messages.dropFirst(index + 1).contains(where: { $0.role == "user" })
    }
    private static func effectiveTools(_ input: AnthropicMessagesRequest) throws -> [JSONObject] {
        var definitions: [String: JSONObject] = [:], active: [String: JSONObject] = [:], order: [String] = []
        func validate(_ tool: JSONObject) throws -> String {
            let kind = tool.string("type") ?? "function"
            if kind == "advisor_20260301" { _ = try SIWCAdvisor(tool); return "advisor" }
            guard kind == "function" else {
                throw SIWCError.unsupported("non-function tool declaration type")
            }
            guard let name = tool.string("name"), !name.isEmpty,
                  tool.object("input_schema") != nil || tool.object("parameters") != nil else {
                throw SIWCError.unsupported("invalid or unsupported function tool declaration")
            }
            return name
        }
        for tool in input.tools ?? [] {
            let name = try validate(tool)
            guard definitions[name] == nil else { throw SIWCError.unsupported("invalid or duplicate tool schema") }
            definitions[name] = tool; active[name] = tool; order.append(name)
        }
        for message in input.messages where message.role == "system" {
            try validateSystemContent(message.content)
            for block in message.content where ["tool_addition", "tool_removal"].contains(block.string("type") ?? "") {
                let wrapper = block.object("tool")!
                let name: String, definition: JSONObject
                if let declared = wrapper.object("definition") {
                    name = try validate(declared); definition = declared; definitions[name] = declared
                } else {
                    name = wrapper.string("name")!
                    guard let declared = definitions[name] else { throw SIWCError.unsupported("unresolved system tool reference") }
                    definition = declared
                }
                if block.string("type") == "tool_removal" { active[name] = nil; order.removeAll { $0 == name } }
                else { if active[name] == nil { order.append(name) }; active[name] = definition }
            }
        }
        return order.compactMap { active[$0] }
    }
    private static func functionNames(_ payload: JSONObject) -> Set<String> {
        Set((payload.array("tools") ?? []).flatMap { ($0.objectValue?.array("tools") ?? []).compactMap { $0.objectValue?.string("name") } })
    }
    static func validateToolHistory(_ messages: [AnthropicMessage]) throws {
        var pending: Set<String> = [], seen: Set<String> = []
        var serverPending: Set<String> = []
        for message in messages {
            for block in message.content {
                if block.string("type") == "server_tool_use" {
                    guard message.role == "assistant", let id = block.string("id"), !id.isEmpty, seen.insert(id).inserted else { throw SIWCError.unsupported("duplicate or invalid Advisor call ID") }
                    serverPending.insert(id)
                } else if block.string("type") == "advisor_tool_result" {
                    guard message.role == "assistant", let id = block.string("tool_use_id"), serverPending.remove(id) != nil else { throw SIWCError.unsupported("orphaned or duplicate Advisor result") }
                } else if block.string("type") == "tool_use" {
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
        guard pending.isEmpty, serverPending.isEmpty else { throw SIWCError.unsupported("missing parallel tool results") }
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
            case "server_tool_use" where !nested:
                guard block.string("name") == "advisor", block.string("id") != nil, block.object("input")?.values.isEmpty == true else { throw SIWCError.unsupported("malformed Advisor server call") }
            case "advisor_tool_result" where !nested:
                guard block.string("tool_use_id") != nil, let content = block.object("content"),
                      (content.string("type") == "advisor_result" && content.string("text") != nil) ||
                      (content.string("type") == "advisor_tool_result_error" && content.string("error_code") == "max_uses_exceeded") else { throw SIWCError.unsupported("unsupported Advisor result; encrypted Anthropic results cannot be imported") }
            default: throw SIWCError.unsupported(block.string("type") ?? "content block")
            }
        }
    }

    static func encode(_ message: AnthropicMessage) throws -> [JSONValue] {
        if message.role == "system" {
            try validateSystemContent(message.content)
            // Tool changes are represented by effectiveTools; text keeps its
            // developer instruction priority and original transcript position.
            let text = message.content.filter { $0.string("type") == "text" }
            return IRResponsesCodec.encodeFullHistory([IRMessage(role: "developer", content: IRAnthropicCodec.decodeRequestBlocks(text))])
        }
        guard message.role == "user" || message.role == "assistant" else { throw SIWCError.unsupported("message role") }
        try validateContent(message.content)
        if message.content.contains(where: { ["server_tool_use", "advisor_tool_result"].contains($0.string("type") ?? "") }) {
            guard message.role == "assistant" else { throw SIWCError.unsupported("Advisor blocks require assistant role") }
            return try message.content.flatMap { block -> [JSONValue] in
                if block.string("type") == "server_tool_use" {
                    return [.object(JSONObject.from(["type": .string("function_call"), "call_id": block["id"]!, "namespace": .string(SIWCAdvisor.namespace), "name": .string("advisor"), "arguments": .string("{}")]))]
                }
                if block.string("type") == "advisor_tool_result" {
                    return [.object(JSONObject.from(["type": .string("function_call_output"), "call_id": block["tool_use_id"]!, "output": .string(block.object("content")?.string("text") ?? "Advisor max_uses exceeded.")]))]
                }
                return try encode(AnthropicMessage(role: message.role, content: [block]))
            }
        }
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
            case "claudex.advisor.start":
                guard let call = event.object("call"), let id = call.string("call_id") else { throw SIWCError.remote("invalid_advisor_event") }
                guard received.insert(id).inserted else { throw SIWCError.remote("duplicate_tool_call_id") }
                if !text.isEmpty, let index = textIndex { assistantBlocks[index] = JSONObject.from(["type": .string("text"), "text": .string(text)]); text = ""; textIndex = nil }
                result.raw.append(.object(call))
                try await encoder.emitServerToolUseBlock(id: id, name: "advisor", input: JSONObject())
                assistantBlocks[encoder.blockIndex] = JSONObject.from(["type": .string("server_tool_use"), "id": .string(id), "name": .string("advisor"), "input": .object(JSONObject())])
            case "claudex.advisor.result":
                guard let block = event.object("result"), let id = block.string("tool_use_id") else { throw SIWCError.remote("invalid_advisor_result") }
                try await encoder.emitCompleteBlock(block)
                assistantBlocks[encoder.blockIndex] = block
                result.raw.append(.object(JSONObject.from(["type": .string("function_call_output"), "call_id": .string(id), "output": .string(block.object("content")?.string("text") ?? "Advisor max_uses exceeded.")])))
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
        try Task.checkCancellation()
        guard completed, toolBlocks.isEmpty else { throw SIWCError.remote("interrupted_stream") }
        if !text.isEmpty, let index = textIndex { assistantBlocks[index] = JSONObject.from(["type": .string("text"), "text": .string(text)]) }
        result.assistant = assistantBlocks.sorted { $0.key < $1.key }.map { $0.value }
        try Task.checkCancellation()
        try await beforeFinish(result)
        encoder.updateFinalOutputTokens(result.outputTokens)
        encoder.updateFinalInputTokens(result.inputTokens)
        try await encoder.finish(stopReasonHint: result.hasTools ? .toolUse : .endTurn)
        return result
    }
    static func isContextLimitError(_ error: any Error) -> Bool {
        let codes: Set<String> = ["context_length_exceeded", "prompt_too_long"]
        if case SIWCError.remote(let code) = error { return codes.contains(code) }
        guard let http = error as? ResponsesHTTPError, [400, 413].contains(http.statusCode),
              let data = http.body.data(using: .utf8),
              let body = try? JSONDecoder().decode(JSONObject.self, from: data),
              let code = body.object("error")?.string("code") else { return false }
        return codes.contains(code)
    }
    static func error(_ error: any Error, status: Int) -> HTTPResponse {
        let type = status == 401 ? "authentication_error" : "invalid_request_error"
        let message: String
        if Self.isContextLimitError(error) {
            message = "prompt is too long: upstream model context window exceeded"
        } else { message = error.localizedDescription }
        return try! HTTPResponse.json(statusCode: status, reasonPhrase: "Request Failed",
            value: AnthropicErrorEnvelope(error: AnthropicErrorBody(type: type, message: message)))
    }
}
private actor SIWCCollectingWriter: HTTPBodyWriter {
    func write(_ chunk: Data) {}
    func finish() {}
}
