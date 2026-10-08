import Foundation
import Testing
@testable import CCRouterCore

private struct SIWCFixtureAuth: SubscriptionSessionProviding {
    func loadCurrent() async throws -> SubscriptionCredentials { SubscriptionCredentials(accessToken: "fixture-only", accountID: "account-fixture") }
}
private actor SIWCFixtureClient: ResponsesStreamingClient {
    var payloads: [JSONObject] = []
    var cancellations: [UUID] = []
    func cancelRequest(_ id: UUID) { cancellations.append(id) }
    var cancelled: Int { cancellations.count }
    let scripts: [[JSONObject]]
    init(_ scripts: [[JSONObject]]) { self.scripts = scripts }
    func streamEvents(request: JSONObject, credentials: SubscriptionCredentials) async throws -> AsyncThrowingStream<JSONObject, Error> {
        if (request.array("input") ?? []).contains(where: { $0.objectValue?.string("role") == "system" }) {
            throw SIWCError.remote("system messages are not allowed")
        }
        let index = payloads.count; payloads.append(request)
        let events = scripts[min(index, scripts.count - 1)]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func perform(request: JSONObject, credentials: SubscriptionCredentials) async throws -> [JSONObject] { [] }
    func payload(_ index: Int) -> JSONObject { payloads[index] }
    var calls: Int { payloads.count }
}
private actor SuspendedAdvisorClient: ResponsesStreamingClient {
    let initial: [JSONObject]
    var calls = 0
    var cancellations = 0
    var pending: AsyncThrowingStream<JSONObject, Error>.Continuation?
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(initial: [JSONObject]) { self.initial = initial }
    func streamEvents(request: JSONObject, credentials: SubscriptionCredentials) async throws -> AsyncThrowingStream<JSONObject, Error> {
        calls += 1
        if calls == 1 { return AsyncThrowingStream { c in initial.forEach { c.yield($0) }; c.finish() } }
        let stream = AsyncThrowingStream<JSONObject, Error> { pending = $0 }
        waiters.forEach { $0.resume() }; waiters.removeAll()
        return stream
    }
    func waitForReview() async {
        if calls >= 2 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func cancelRequest(_ id: UUID) { cancellations += 1; pending?.finish(throwing: CancellationError()) }
    func perform(request: JSONObject, credentials: SubscriptionCredentials) async throws -> [JSONObject] { [] }
}
private actor SIWCFixtureWriter: HTTPBodyWriter {
    var chunks = Data()
    func write(_ chunk: Data) { chunks.append(chunk) }
    func finish() {}
    var text: String { String(data: chunks, encoding: .utf8)! }
}
struct SIWCBridgeTests {
    static let route = ModelRoute(upstreamModel: "fixture-model", reasoningEffort: "low", textVerbosity: "low")
    static let tools = #"[{"name":"Read","description":"Read local file","input_schema":{"type":"object","properties":{"path":{"type":"string"}}}}]"#
    private func isolatedReplay() -> SIWCReplayStore {
        SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-test-replay-" + UUID().uuidString))
    }
    private func config() -> RouterConfiguration {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("siwc-config-" + UUID().uuidString)
        return RouterConfiguration(environment: ["CC_ROUTER_CONFIG_PATH": home.appendingPathComponent("config.json").path], homeDirectoryURL: home)
    }
    private func request(_ history: String, session: String = "branch-fixture", tools: String = Self.tools) -> HTTPRequest {
        let body = "{\"model\":\"claude-fixture\",\"stream\":true,\"system\":\"Keep instructions\",\"tools\":" + tools + ",\"messages\":" + history + "}"
        return HTTPRequest(method: "POST", path: "/v1/messages", headers: ["x-claude-code-session-id": session], body: Data(body.utf8))
    }
    private func consume(_ response: HTTPResponse, _ writer: SIWCFixtureWriter) async throws {
        guard case .stream(let producer) = response.body else { throw SIWCError.remote("expected_stream") }
        try await producer(writer)
    }
    private func done(_ item: JSONObject) -> JSONObject { JSONObject.from(["type": .string("response.output_item.done"), "item": .object(item)]) }
    private var completed: JSONObject { JSONObject.from(["type": .string("response.completed")]) }
    private func call(_ id: String, itemID: String, name: String = "Read", arguments: String = "{\"path\":\"a\"}") -> JSONObject {
        JSONObject.from(["type": .string("function_call"), "id": .string(itemID), "call_id": .string(id),
            "namespace": .string("claude"), "name": .string(name), "arguments": .string(arguments)])
    }
    @Test func requestContractIsNamespacedAndStateless() throws {
        let input = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request(#"[{"role":"user","content":"hello"}]"#).body)
        let payload = try SIWCBridge.payload(input, route: Self.route)
        #expect(payload.bool("store") == false)
        #expect(payload.bool("stream") == true)
        #expect(payload["previous_response_id"] == nil)
        #expect(payload["max_output_tokens"] == nil)
        #expect(payload["service_tier"] == nil)
        #expect(payload.array("tools")?.first?.objectValue?.string("type") == "namespace")
        #expect(payload.string("instructions") == "Keep instructions")
    }
    @Test func rejectsUnknownOrDuplicateToolsBeforeInference() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-replay-" + UUID().uuidString)))
        let response = await bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#, tools: #"[{"type":"tool_search"}]"#))
        #expect(response.statusCode == 400)
        #expect(await client.calls == 0)
        let traffic = await bridge.trafficSnapshot()
        #expect(traffic.requests == 1 && traffic.errors == 1 && traffic.modelCalls == 0)
    }
    @Test func capturedClaude294AdvisorMapsAndClientSchemasSurvive() throws {
        let url = try #require(Bundle.module.url(forResource: "claude-code-2.1.294-advisor-tools", withExtension: "json"))
        let captured = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
        let tools = try #require(captured.array("tools"))
        #expect(tools.contains { $0.objectValue?.string("type") == "advisor_20260301" && $0.objectValue?.bool("defer_loading") == true })
        var body = JSONObject.from(["model": .string("fixture"), "messages": .array([]), "tools": .array(tools)])
        let input = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: JSONEncoder().encode(body))
        let mapped = try SIWCBridge.payload(input, route: Self.route)
        #expect(mapped.array("tools")?.contains { $0.objectValue?.string("name") == SIWCAdvisor.namespace } == true)
        body["tools"] = .array(tools.filter { $0.objectValue?.string("type") != "advisor_20260301" })
        let clientInput = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: JSONEncoder().encode(body))
        let payload = try SIWCBridge.payload(clientInput, route: Self.route)
        let converted = try #require(payload.array("tools")?.first?.objectValue?.array("tools"))
        for original in tools.compactMap(\.objectValue) where original.string("type") == nil {
            let function = try #require(converted.compactMap(\.objectValue).first { $0.string("name") == original.string("name") })
            #expect(function.object("parameters") == original.object("input_schema"))
        }
    }
    private var advisorTools: String { #"[{"type":"advisor_20260301","name":"advisor","model":"claude-opus-5-5","defer_loading":true},{"name":"Read","input_schema":{"type":"object"}}]"# }
    private func advisorCall(_ id: String = "advisor_one") -> JSONObject {
        JSONObject.from(["type": .string("function_call"), "id": .string("item_" + id), "call_id": .string(id), "namespace": .string(SIWCAdvisor.namespace), "name": .string("advisor"), "arguments": .string("{}")])
    }
    private func message(_ text: String) -> JSONObject {
        JSONObject.from(["type": .string("message"), "role": .string("assistant"), "content": .array([.object(JSONObject.from(["type": .string("output_text"), "text": .string(text)]))])])
    }
    private func usageDone(_ input: Int, _ output: Int) -> JSONObject {
        JSONObject.from(["type": .string("response.completed"), "response": .object(JSONObject.from(["usage": .object(JSONObject.from(["input_tokens": .number(Double(input)), "output_tokens": .number(Double(output))]))]))])
    }
    @Test func cancellingAdvisorReviewCancelsChildWithoutResumingExecutor() async throws {
        let client = SuspendedAdvisorClient(initial: [done(advisorCall()), completed])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let writer = SIWCFixtureWriter()
        let response = await bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#, tools: #"[{"type":"advisor_20260301","name":"advisor","model":"claude-opus-5-5"}]"#))
        let task = Task { try await consume(response, writer) }
        await client.waitForReview()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await client.calls == 2)
        #expect(await client.cancellations > 0)
        #expect(!(await writer.text).contains("message_stop"))
        #expect(await bridge.trafficSnapshot().errors == 0)
    }

    @Test func advisorRunsToolFreeAndExecutorResumesWithinOneClaudeMessage() async throws {
        let client = SIWCFixtureClient([[done(advisorCall()), usageDone(10, 2)], [done(message("Review the file first.")), usageDone(20, 3)], [done(call("read_after_advice", itemID: "read_item")), usageDone(30, 4)], [done(message("Final answer")), completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let writer = SIWCFixtureWriter()
        let history = #"[{"role":"user","content":"Check the file"}]"#
        try await consume(bridge.handleMessages(request(history, tools: advisorTools)), writer)
        let text = await writer.text
        #expect(text.components(separatedBy: "event: message_start").count == 2)
        #expect(text.components(separatedBy: "event: message_stop").count == 2)
        #expect(text.contains("server_tool_use"))
        #expect(text.contains("advisor_result"))
        #expect(text.contains("Review the file first."))
        #expect(text.contains("\"input_tokens\":60"))
        #expect(text.contains("\"output_tokens\":9"))
        let review = await client.payload(1)
        #expect(review.array("tools")?.isEmpty == true)
        let resumed = await client.payload(2)
        #expect(resumed.array("input")?.contains { $0.objectValue?.string("type") == "function_call_output" && $0.objectValue?.string("output") == "Review the file first." } == true)
        let events = text.split(separator: "\n").filter { $0.hasPrefix("data: ") }.compactMap { try? JSONDecoder().decode(JSONObject.self, from: Data($0.dropFirst(6).utf8)) }
        let blocks = events.filter { $0.string("type") == "content_block_start" }.compactMap { $0.object("content_block") }.map { block -> JSONObject in
            var b = block
            if b.string("type") == "tool_use" { b["input"] = .object(JSONObject.from(["path": .string("a")])) }
            b["cache_control"] = .object(JSONObject.from(["type": .string("ephemeral")]))
            return b
        }
        var next = JSONObject.from(["model": .string("claude-fixture"), "stream": .bool(true), "tools": .array(try JSONDecoder().decode([JSONObject].self, from: Data(advisorTools.utf8)).map(JSONValue.object)),
            "messages": .array([.object(JSONObject.from(["role": .string("user"), "content": .string("Check the file")])), .object(JSONObject.from(["role": .string("assistant"), "content": .array(blocks.map(JSONValue.object))])), .object(JSONObject.from(["role": .string("user"), "content": .array([.object(JSONObject.from(["type": .string("tool_result"), "tool_use_id": .string("read_after_advice"), "content": .string("file contents")]))])]))])])
        next["system"] = .string("Keep instructions")
        try await consume(bridge.handleMessages(HTTPRequest(method: "POST", path: "/v1/messages", headers: ["x-claude-code-session-id": "branch-fixture"], body: JSONEncoder().encode(next))), SIWCFixtureWriter())
        let traffic = await bridge.trafficSnapshot()
        #expect(traffic.requests == 2)
        #expect(traffic.modelCalls == 4)
        #expect(traffic.errors == 0 && traffic.successes == 2)
        #expect(traffic.lastOutcome == "Last request completed")
        #expect(traffic.p50LatencyMilliseconds != nil && traffic.p95LatencyMilliseconds != nil)
        #expect(traffic.inputTokens == 60)
        #expect(traffic.outputTokens == 9)
        #expect(traffic.advisorTokens == 23)
        #expect(traffic.usageReported && traffic.usageIncomplete)
        if let path = ProcessInfo.processInfo.environment["CLAUDEX_TRAFFIC_FIXTURE_SNAPSHOT"], path.hasPrefix("/tmp/") {
            try JSONEncoder().encode(traffic).write(to: URL(fileURLWithPath: path))
        }
        #expect(await client.calls == 4)
        #expect(await client.payload(3).array("input")?.contains { $0.objectValue?.string("namespace") == SIWCAdvisor.namespace } == true)
    }
    @Test func advisorUsesIndependentFixedEffortAndPinnedRoute() async throws {
        let client = SIWCFixtureClient([[done(call("pin_read", itemID: "pin_read_item")), completed], [done(advisorCall()), completed], [done(message("Pinned advice")), completed], [done(message("Final")), completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let executorRoute = ModelRoute(upstreamModel: "executor-fixture", reasoningEffort: "high", textVerbosity: "low")
        let advisorRoute = ModelRoute(upstreamModel: "advisor-fixture", reasoningEffort: "low", textVerbosity: "low")
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: executorRoute), advisorRoute: advisorRoute)
        try await consume(bridge.handleMessages(effortRequest(#"[{"role":"user","content":"pin"}]"#, effort: "ultra")), SIWCFixtureWriter())
        // Initial request must declare Advisor to pin its configuration.
        let firstClient = SIWCFixtureClient([[done(call("pin_read", itemID: "pin_read_item")), completed], [done(advisorCall()), completed], [done(message("Pinned advice")), completed], [done(message("Final")), completed]])
        let pinnedBridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: firstClient, replayStore: isolatedReplay())
        await pinnedBridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: executorRoute), advisorRoute: advisorRoute)
        try await consume(pinnedBridge.handleMessages(request(#"[{"role":"user","content":"pin"}]"#, tools: advisorTools)), SIWCFixtureWriter())
        await pinnedBridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: Self.route), advisorRoute: ModelRoute(upstreamModel: "changed", reasoningEffort: "ultra", textVerbosity: "high"))
        try await consume(pinnedBridge.handleMessages(request(#"[{"role":"user","content":"pin"},{"role":"assistant","content":[{"type":"tool_use","id":"pin_read","name":"Read","input":{"path":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"pin_read","content":"file"}]}]"#, tools: advisorTools)), SIWCFixtureWriter())
        #expect(await firstClient.payload(2).string("model") == "advisor-fixture")
        #expect(await firstClient.payload(2).object("reasoning")?.string("effort") == "low")
        #expect(await firstClient.payload(1).string("model") == "executor-fixture")
    }
    @Test func installedClaudeOfflineAdvisorReadRoundtrip() async throws {
        guard let binary = ProcessInfo.processInfo.environment["CLAUDEX_CLAUDE_BIN"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claudex-installed-offline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data("OFFLINE_READ_MARKER\n".utf8).write(to: file)
        let read = call("installed_read", itemID: "installed_read_item", arguments: "{\"file_path\":\"" + file.path + "\"}")
        let client = SIWCFixtureClient([[done(advisorCall()), completed], [done(message("Read the requested file.")), completed], [done(read), completed], [done(message("OFFLINE_READ_MARKER")), completed]])
        let configuration = RouterConfiguration(host: "127.0.0.1", port: 14319, healthPath: "/health", messagesPath: "/v1/messages", countTokensPath: "/v1/messages/count_tokens", responsesURL: "https://fixture.invalid", routingTable: ModelRoutingTable(rules: [], fallback: Self.route), advisorRoute: ModelRoute(upstreamModel: "advisor-fixture", reasoningEffort: "low", textVerbosity: "low"), gatewayAuthToken: "offline-fixture", gatewayAuthHeader: "x-mb-token", subscriptionAuthFilePath: directory.appendingPathComponent("unused").path, configurationPath: directory.appendingPathComponent("config.json").path, configurationWarning: nil)
        let bridge = SIWCBridge(configuration: configuration, auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: directory.appendingPathComponent("Replay")))
        let server = LocalHTTPServer(configuration: configuration) { request in
            guard LocalGatewayAuthorization.providedToken(from: request.headers) == "offline-fixture" else { return SIWCBridge.error(SIWCError.permissionRequired, status: 401) }
            if request.path == "/v1/messages/count_tokens" { return await bridge.handleCountTokens(request) }
            return await bridge.handleMessages(request)
        }
        try server.start(); defer { server.stop() }
        let output = directory.appendingPathComponent("client.jsonl")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.currentDirectoryURL = directory
        process.arguments = ["--bare", "--setting-sources", "", "--settings", "{\"advisorModel\":\"opus\",\"permissions\":{\"defaultMode\":\"manual\"}}", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--model", "claude-sonnet-5-5", "--effort", "low", "--tools", "Read", "--allowedTools", "Read", "--permission-mode", "manual", "--permission-prompts", "none", "-p", "--output-format", "stream-json", "--verbose", "--", "Use Read once on " + file.path + ", then return its content."]
        process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CLAUDE_CONFIG_DIR": directory.appendingPathComponent("client").path, "ANTHROPIC_BASE_URL": "http://127.0.0.1:14319", "ANTHROPIC_AUTH_TOKEN": "offline-fixture", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL": "1"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        try process.run()
        await Task.detached { process.waitUntilExit() }.value
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(process.terminationStatus == 0, Comment(rawValue: text))
        #expect(text.contains("OFFLINE_READ_MARKER"))
        #expect(text.contains("tool_result"))
        #expect(await client.calls == 4, Comment(rawValue: text))
    }
    @Test func advisorAndReadTogetherDoNotResumeUntilClaudeReturnsRead() async throws {
        let client = SIWCFixtureClient([[done(advisorCall()), done(call("mixed_read", itemID: "mixed_item")), completed], [done(message("Advice")), completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let writer = SIWCFixtureWriter()
        try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"mixed"}]"#, tools: advisorTools)), writer)
        #expect(await client.calls == 2)
        #expect(await writer.text.contains("\"stop_reason\":\"tool_use\""))
    }
    @Test func explicitAdvisorLimitsAndUnsupportedControlsAreNotDropped() throws {
        let native = JSONObject.from(["type": .string("advisor_20260301"), "name": .string("advisor"), "model": .string("fixture"), "max_uses": .number(0)])
        let advisor = try SIWCAdvisor(native)
        #expect(advisor.maxUses == 0)
        #expect(try advisor.reviewPayload(executor: JSONObject(), output: [], route: Self.route)["max_output_tokens"] == nil)
        var capped = native; capped["max_tokens"] = .number(1024)
        #expect(throws: SIWCError.self) { try SIWCAdvisor(capped) }
        var invalid = native; invalid["caching"] = .object(JSONObject.from(["type": .string("ephemeral"), "ttl": .string("1h")]))
        #expect(throws: SIWCError.self) { try SIWCAdvisor(invalid) }
        invalid = native; invalid["max_tokens"] = .number(1)
        #expect(throws: SIWCError.self) { try SIWCAdvisor(invalid) }
    }
    @Test func advisorUseLimitReturnsNativeErrorWithoutReviewInference() async throws {
        let client = SIWCFixtureClient([[done(advisorCall()), completed], [done(message("Continue without advice")), completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let writer = SIWCFixtureWriter()
        try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"limit"}]"#, tools: #"[{"type":"advisor_20260301","name":"advisor","model":"fixture","max_uses":0}]"#)), writer)
        #expect(await client.calls == 2)
        #expect(await writer.text.contains("max_uses_exceeded"))
    }
    @Test func orphanedAdvisorResultsAreRejected() throws {
        #expect(throws: SIWCError.self) { try SIWCBridge.validateToolHistory([AnthropicMessage(role: "assistant", content: [JSONObject.from(["type": .string("advisor_tool_result"), "tool_use_id": .string("orphan"), "content": .object(JSONObject.from(["type": .string("advisor_result"), "text": .string("text")]))])])]) }
    }
    @Test func partialStreamIsNeverSuccessful() async throws {
        let client = SIWCFixtureClient([[JSONObject.from(["type": .string("response.output_text.delta"), "delta": .string("partial")])]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-replay-" + UUID().uuidString)))
        let writer = SIWCFixtureWriter()
        await #expect(throws: SIWCError.self) { try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#)), writer) }
        let text = await writer.text
        #expect(text.contains("partial"))
        #expect(!text.contains("message_stop"))
        #expect(await client.calls == 1)
    }
    @Test func terminalUsageFailureIsNotRetried() async throws {
        let failure = JSONObject.from(["type": .string("response.failed"), "response": .object(JSONObject.from([
            "error": .object(JSONObject.from(["code": .string("subscription_sharing_usage_limit_exceeded")]))]))])
        let client = SIWCFixtureClient([[failure]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-replay-" + UUID().uuidString)))
        let response = await bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#))
        let writer = SIWCFixtureWriter()
        await #expect(throws: SIWCError.self) { try await consume(response, writer) }
        #expect(await client.calls == 1)
        #expect(await bridge.pendingToolTurnsCount() == 0)
    }
    @Test func fullHistoryAndOpaqueReasoningSurviveContinuation() async throws {
        let reasoning = JSONObject.from(["type": .string("reasoning"), "id": .string("rs_fixture"),
            "encrypted_content": .string("opaque-fixture"), "summary": .array([])])
        let message = JSONObject.from(["type": .string("message"), "id": .string("msg_fixture"), "role": .string("assistant"),
            "phase": .string("commentary"), "content": .array([.object(JSONObject.from(["type": .string("output_text"), "text": .string("before tools")]))])])
        let client = SIWCFixtureClient([[done(reasoning), done(message), done(call("call_fixture", itemID: "item_fixture")), completed], [completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-replay-" + UUID().uuidString)))
        let writer = SIWCFixtureWriter()
        try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#)), writer)
        let text = await writer.text
        #expect(!text.contains("opaque-fixture"))
        #expect(!text.contains("signature_delta"))
        let next = request(#"[{"role":"user","content":"hello"},{"role":"assistant","content":[{"type":"text","text":"before tools"},{"type":"tool_use","id":"call_fixture","name":"Read","input":{"path":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_fixture","content":"file"}]}]"#)
        try await consume(bridge.handleMessages(next), SIWCFixtureWriter())
        let payload = await client.payload(1)
        #expect(payload.string("instructions") == "Keep instructions")
        let items = try #require(payload.array("input"))
        #expect(items.contains { $0.objectValue?.string("type") == "reasoning" && $0.objectValue?.string("encrypted_content") == "opaque-fixture" })
        #expect(items.contains { $0.objectValue?.string("role") == "user" })
        #expect(items.contains { $0.objectValue?.string("phase") == "commentary" })
        #expect(items.contains { $0.objectValue?.string("type") == "function_call_output" && $0.objectValue?.string("call_id") == "call_fixture" })
    }
    @Test func parallelItemsKeepCallIDsAndIndependentDeltaIndexes() async throws {
        let first = call("call_first", itemID: "item_first"), second = call("call_second", itemID: "item_second")
        let events = [JSONObject.from(["type": .string("response.output_item.added"), "item": .object(first)]),
                      JSONObject.from(["type": .string("response.output_item.added"), "item": .object(second)]),
                      JSONObject.from(["type": .string("response.function_call_arguments.delta"), "item_id": .string("item_second"), "delta": .string("{\"path\":\"a\"}")]),
                      JSONObject.from(["type": .string("response.function_call_arguments.delta"), "item_id": .string("item_first"), "delta": .string("{\"path\":\"a\"}")]),
                      done(second), done(first), completed]
        let client = SIWCFixtureClient([events])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-replay-" + UUID().uuidString)))
        let writer = SIWCFixtureWriter()
        try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#)), writer)
        let text = await writer.text
        #expect(text.contains("call_first"))
        #expect(text.contains("call_second"))
        #expect(!text.contains("item_first"))
        #expect(text.contains("input_json_delta"))
        #expect(text.contains("message_stop"))
    }
    @Test func missingNamespaceFailsExplicitly() async throws {
        var tool = call("call_wrong", itemID: "item_wrong"); tool["namespace"] = nil
        let client = SIWCFixtureClient([[done(tool), completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-replay-" + UUID().uuidString)))
        let response = await bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#))
        await #expect(throws: SIWCError.self) { try await consume(response, SIWCFixtureWriter()) }
    }
    @Test func replayWriteFailureNeverReportsSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("siwc-invalid-replay-" + UUID().uuidString)
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: directory))
        let writer = SIWCFixtureWriter()
        await #expect(throws: (any Error).self) {
            try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#)), writer)
        }
        #expect(!(await writer.text).contains("message_stop"))
        #expect(await bridge.pendingToolTurnsCount() == 0)
    }
    @Test func toolChoiceIsPreservedOrExplicitlyRejected() throws {
        let data = Data(#"{"model":"fixture","messages":[],"tool_choice":{"type":"any","disable_parallel_tool_use":true}}"#.utf8)
        let input = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)
        let payload = try SIWCBridge.payload(input, route: Self.route)
        #expect(payload.string("tool_choice") == "required")
        #expect(payload.bool("parallel_tool_calls") == false)
        let forced = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: Data(#"{"model":"fixture","messages":[],"tool_choice":{"type":"tool","name":"Read"}}"#.utf8))
        #expect(throws: SIWCError.self) { try SIWCBridge.payload(forced, route: Self.route) }
    }
    @Test func replayContractSeparatesChangedInstructionsAndTools() throws {
        let first = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request("[]").body)
        let changedTools = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: request("[]", tools: "[]").body)
        #expect(SIWCBridge.contractFingerprint(first) != SIWCBridge.contractFingerprint(changedTools))
        let changedInstructions = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: Data(String(decoding: request("[]").body, as: UTF8.self).replacingOccurrences(of: "Keep instructions", with: "Other instructions").utf8))
        #expect(SIWCBridge.contractFingerprint(first) != SIWCBridge.contractFingerprint(changedInstructions))
    }

    @Test func missingSessionNeverCallsInference() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let source = request(#"[{"role":"user","content":"hello"}]"#)
        let missing = HTTPRequest(method: source.method, path: source.path, headers: [:], body: source.body)
        #expect(await bridge.handleMessages(missing).statusCode == 400)
        #expect(await client.calls == 0)
    }

    @Test func parallelHistoryAcceptsReversedResultsAndRejectsMissingDuplicateOrOrphanIDs() throws {
        func history(_ results: String) throws -> [AnthropicMessage] {
            let text = #"[{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Read","input":{}},{"type":"tool_use","id":"b","name":"Read","input":{}}]},{"role":"user","content":\#(results)}]"#
            return try JSONDecoder().decode([AnthropicMessage].self, from: Data(text.utf8))
        }
        try SIWCBridge.validateToolHistory(history(#"[{"type":"tool_result","tool_use_id":"b","content":"second"},{"type":"tool_result","tool_use_id":"a","content":"first"}]"#))
        for invalid in [#"[{"type":"tool_result","tool_use_id":"b","content":"second"}]"#,
            #"[{"type":"tool_result","tool_use_id":"a","content":"first"},{"type":"tool_result","tool_use_id":"a","content":"duplicate"}]"#,
            #"[{"type":"tool_result","tool_use_id":"orphan","content":"unknown"}]"#] {
            #expect(throws: SIWCError.self) { try SIWCBridge.validateToolHistory(history(invalid)) }
        }
    }

    @Test func nativeWebSearchIsRejectedBeforeInference() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        #expect(await bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#, tools: #"[{"type":"web_search_20250305","name":"web_search"}]"#)).statusCode == 400)
        #expect(await client.calls == 0)
    }
    @Test func undeclaredToolCannotBeEmittedAsExecutable() async throws {
        let client = SIWCFixtureClient([[done(call("call_bad", itemID: "item_bad", name: "Undeclared")), completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let writer = SIWCFixtureWriter()
        await #expect(throws: SIWCError.self) { try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#)), writer) }
        #expect(!(await writer.text).contains("Undeclared"))
        #expect(!(await writer.text).contains("message_stop"))
    }

    @Test func abandonedResponseReleasesUpstreamAndDoesNotClearANewerLease() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let first = await bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#))
        #expect(await bridge.pendingToolTurnsCount() == 1)
        await first.release?()
        #expect(await bridge.pendingToolTurnsCount() == 0)
        #expect(await client.cancelled == 1)
        let second = await bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#))
        await first.release?()
        #expect(await bridge.pendingToolTurnsCount() == 1)
        await second.release?()
        #expect(await bridge.pendingToolTurnsCount() == 0)
    }
    @Test func textAfterToolPreservesPrefixOrderAcrossBridgeRestart() async throws {
        let reasoning = JSONObject.from(["type": .string("reasoning"), "encrypted_content": .string("opaque-order"), "id": .string("rs_order")])
        let message = JSONObject.from(["type": .string("message"), "role": .string("assistant"), "phase": .string("final_answer"),
            "content": .array([.object(JSONObject.from(["type": .string("output_text"), "text": .string("after tool")]))])])
        let client = SIWCFixtureClient([[done(reasoning), done(call("call_order", itemID: "item_order")), done(message), completed], [completed]])
        let store = SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-order-" + UUID().uuidString))
        let first = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: store)
        try await consume(first.handleMessages(request(#"[{"role":"user","content":"hello"}]"#)), SIWCFixtureWriter())
        let restarted = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: store)
        let next = request(#"[{"role":"user","content":"hello"},{"role":"assistant","content":[{"type":"tool_use","id":"call_order","name":"Read","input":{"path":"a"}},{"type":"text","text":"after tool"}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_order","content":"file"}]}]"#)
        try await consume(restarted.handleMessages(next), SIWCFixtureWriter())
        let items = await client.payload(1).array("input") ?? []
        #expect(items.contains { $0.objectValue?.string("encrypted_content") == "opaque-order" })
        #expect(items.contains { $0.objectValue?.string("phase") == "final_answer" })
    }
    @Test func cacheMarkersCanMoveAcrossNativeReadContinuationAfterRestart() async throws {
        // Read-shaped native fixture. Marker movement was not captured in the failed live request.
        let toolID = "call_TN9mDcXyF8NsMay4TBf91l9y"
        let reasoning = JSONObject.from(["type": .string("reasoning"), "encrypted_content": .string("opaque-native-read")])
        let client = SIWCFixtureClient([[done(reasoning), done(call(toolID, itemID: "item_native", arguments: #"{"file_path":"note.txt"}"#)), completed], [completed]])
        let store = SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-native-read-" + UUID().uuidString))
        let first = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: store)
        await first.updateRouting(table: ModelRoutingTable(rules: [], fallback: Self.route), advisorRoute: Self.route)
        try await consume(first.handleMessages(request(#"[{"role":"user","content":[{"type":"text","text":"Read note.txt","cache_control":{"type":"ephemeral"}}]}]"#)), SIWCFixtureWriter())
        let restarted = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: store)
        let changed = ModelRoute(upstreamModel: "changed-model", reasoningEffort: "high", textVerbosity: "low")
        await restarted.updateRouting(table: ModelRoutingTable(rules: [], fallback: changed), advisorRoute: changed)
        let history = #"[{"role":"user","content":[{"type":"text","text":"Read note.txt"}]},{"role":"assistant","content":[{"type":"tool_use","id":"call_TN9mDcXyF8NsMay4TBf91l9y","name":"Read","input":{"file_path":"note.txt"},"cache_control":{"type":"ephemeral"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_TN9mDcXyF8NsMay4TBf91l9y","content":"1\tREAD_OK\n2\t","cache_control":{"type":"ephemeral","ttl":"1h"}}]}]"#
        try await consume(restarted.handleMessages(request(history)), SIWCFixtureWriter())
        let payload = await client.payload(1)
        #expect(payload.string("model") == Self.route.upstreamModel)
        #expect(payload.object("reasoning")?.string("effort") == "low")
        #expect(payload.array("input")?.contains { $0.objectValue?.string("encrypted_content") == "opaque-native-read" } == true)
        #expect(payload.array("input")?.contains { $0.objectValue?.string("type") == "function_call_output" && $0.objectValue?.string("output") == "1\tREAD_OK\n2\t" } == true)
    }
    @Test func replayFingerprintRetainsSemanticHistoryAndEffortControls() throws {
        func decode(_ value: String) throws -> [AnthropicMessage] {
            try JSONDecoder().decode([AnthropicMessage].self, from: Data(value.utf8))
        }
        let plain = try decode(#"[{"role":"assistant","content":[{"type":"tool_use","id":"call_a","name":"Read","input":{"file_path":"a"}}]}]"#)
        let marked = try decode(#"[{"role":"assistant","content":[{"type":"tool_use","id":"call_a","name":"Read","input":{"file_path":"a"},"cache_control":{"type":"ephemeral"}}]}]"#)
        #expect(SIWCBridge.fingerprint(plain) == SIWCBridge.fingerprint(marked))
        for altered in [
            #"[{"role":"assistant","content":[{"type":"tool_use","id":"call_b","name":"Read","input":{"file_path":"a"}}]}]"#,
            #"[{"role":"assistant","content":[{"type":"tool_use","id":"call_a","name":"Read","input":{"file_path":"b"}}]}]"#,
            #"[{"role":"assistant","content":[{"type":"tool_use","id":"call_a","name":"Write","input":{"file_path":"a"}}]}]"#,
            #"[{"role":"assistant","content":[{"type":"tool_use","id":"call_a","name":"Read","input":{"file_path":"a"},"unknown_semantic_field":true}]}]"#,
            #"[{"role":"system","content":[],"output_config":{"effort":"low"}},{"role":"assistant","content":[{"type":"tool_use","id":"call_a","name":"Read","input":{"file_path":"a"}}]}]"#
        ] { #expect(SIWCBridge.fingerprint(plain) != SIWCBridge.fingerprint(try decode(altered))) }
    }
    @Test func exactLegacyCacheAnnotatedReplayRestoresOriginalRoute() async throws {
        let history = #"[{"role":"user","content":[{"type":"text","text":"legacy","cache_control":{"type":"ephemeral"}}]},{"role":"assistant","content":[{"type":"tool_use","id":"call_legacy","name":"Read","input":{"path":"a"}}]}]"#
        let prefix = try JSONDecoder().decode([AnthropicMessage].self, from: Data(history.utf8))
        let reasoning = JSONObject.from(["type": .string("reasoning"), "encrypted_content": .string("opaque-legacy")])
        let store = SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-legacy-" + UUID().uuidString))
        try store.save(SIWCReplayRecord(key: "account-fixture:branch-fixture:" + SIWCBridge.legacyFingerprint(prefix), output: [.object(reasoning), .object(call("call_legacy", itemID: "item_legacy"))], route: Self.route))
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: store)
        let changed = ModelRoute(upstreamModel: "changed", reasoningEffort: "high", textVerbosity: "high")
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: changed), advisorRoute: changed)
        let continuation = String(history.dropLast()) + #",{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_legacy","content":"file"}]}]"#
        try await consume(bridge.handleMessages(request(continuation)), SIWCFixtureWriter())
        let payload = await client.payload(0)
        #expect(payload.string("model") == Self.route.upstreamModel)
        #expect(payload.object("reasoning")?.string("effort") == "low")
        #expect(payload.array("input")?.contains { $0.objectValue?.string("encrypted_content") == "opaque-legacy" } == true)
    }
    @Test func nestedProtocolHintsNormalizeButToolArgumentsAndUnknownFieldsRemainSemantic() throws {
        func hash(_ value: String) throws -> String {
            SIWCBridge.fingerprint(try JSONDecoder().decode([AnthropicMessage].self, from: Data(value.utf8)))
        }
        let plain = #"[{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_a","content":[{"type":"text","text":"file"}]}]}]"#
        let marked = #"[{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_a","cache_control":{"type":"ephemeral"},"content":[{"type":"text","text":"file","cache_control":{"type":"ephemeral"}}]}]}]"#
        #expect(try hash(plain) == hash(marked))
        let argument = #"[{"role":"assistant","content":[{"type":"tool_use","id":"call_a","name":"Read","input":{"cache_control":{"type":"ephemeral"}}}]}]"#
        let changedArgument = #"[{"role":"assistant","content":[{"type":"tool_use","id":"call_a","name":"Read","input":{}}]}]"#
        #expect(try hash(argument) != hash(changedArgument))
        #expect(try hash(plain) != hash(plain.replacingOccurrences(of: "file", with: "different")))
        #expect(try hash(plain) != hash(plain.replacingOccurrences(of: "tool_result", with: "tool_result_extra")))
    }
    @Test func continuationCannotCrossSessionAccountOrChangedSemanticPrefix() async throws {
        struct OtherAccount: SubscriptionSessionProviding {
            func loadCurrent() async throws -> SubscriptionCredentials { SubscriptionCredentials(accessToken: "fixture-only", accountID: "other-fixture") }
        }
        let client = SIWCFixtureClient([[done(call("call_scope", itemID: "item_scope")), completed]])
        let store = SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-scope-" + UUID().uuidString))
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: store)
        try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"scope"}]"#)), SIWCFixtureWriter())
        let continuation = #"[{"role":"user","content":"scope"},{"role":"assistant","content":[{"type":"tool_use","id":"call_scope","name":"Read","input":{"path":"a"},"cache_control":{"type":"ephemeral"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_scope","content":"file"}]}]"#
        #expect(await bridge.handleMessages(request(continuation, session: "other-session")).statusCode == 400)
        #expect(await bridge.handleMessages(request(continuation.replacingOccurrences(of: "\"content\":\"scope\"", with: "\"content\":\"branch\""))).statusCode == 400)
        #expect(await bridge.handleMessages(request(continuation.replacingOccurrences(of: "\"path\":\"a\"", with: "\"path\":\"b\""))).statusCode == 400)
        let other = SIWCBridge(configuration: config(), auth: OtherAccount(), client: client, replayStore: store)
        #expect(await other.handleMessages(request(continuation)).statusCode == 400)
        #expect(await client.calls == 1)
    }
    @Test func nativeSystemToolAdditionStreamsAndContinuationKeepsPinnedRoute() async throws {
        func native(_ history: String) -> HTTPRequest {
            let base = request(history)
            return HTTPRequest(method: base.method, path: base.path, headers: base.headers.merging(["anthropic-beta": [EffortPolicy.claudeCodeMessageBeta, EffortPolicy.systemMessageBeta, EffortPolicy.toolChangesBeta].joined(separator: ",")]) { _, new in new }, body: base.body)
        }
        let client = SIWCFixtureClient([[done(call("call_native", itemID: "item_native", name: "Write")), completed], [completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-native-system-" + UUID().uuidString)))
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: Self.route), advisorRoute: Self.route)
        let prefix = #"[{"role":"user","content":"one"},{"role":"system","output_config":{"effort":"low"},"content":[{"type":"text","text":"Workspace instructions"},{"type":"tool_addition","tool":{"type":"tool_definition","definition":{"name":"Write","input_schema":{"type":"object"}}}}]}]"#
        let writer = SIWCFixtureWriter()
        try await consume(bridge.handleMessages(native(prefix)), writer)
        #expect((await writer.text).contains("Write"))
        let changed = ModelRoute(upstreamModel: "changed", reasoningEffort: "high", textVerbosity: "low")
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: changed), advisorRoute: changed)
        let continuation = String(prefix.dropLast()) + #",{"role":"assistant","content":[{"type":"tool_use","id":"call_native","name":"Write","input":{"path":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_native","content":"written"}]},{"role":"system","content":[],"output_config":{"effort":"high"}}]"#
        try await consume(bridge.handleMessages(native(continuation)), SIWCFixtureWriter())
        #expect(await client.payload(1).string("model") == Self.route.upstreamModel)
        #expect(await client.payload(1).object("reasoning")?.string("effort") == "low")
        for index in [0, 1] {
            let payload = await client.payload(index)
            #expect(payload.string("instructions") == "Keep instructions")
            let items = payload.array("input") ?? []
            #expect(!items.contains { $0.objectValue?.string("role") == "system" })
            #expect(items[1].objectValue?.string("role") == "developer")
            #expect(items[1].objectValue?.array("content")?.first?.objectValue?.string("text") == "Workspace instructions")
        }
    }
    @Test func unsupportedNativeSystemContentCannotReachInference() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        for history in [
            #"[{"role":"system","content":[{"type":"future_block","data":"retain-or-reject"}],"output_config":{"effort":"low"}}]"#,
            #"[{"role":"system","content":[{"type":"text","text":"instruction","unknown_semantic":true}]}]"#,
            #"[{"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"Missing"}}]}]"#,
            #"[{"role":"system","content":[{"type":"text","text":"instruction"}],"clear_at":"unknown"}]"#
        ] {
            let base = request(history)
            let native = HTTPRequest(method: base.method, path: base.path, headers: base.headers.merging(["anthropic-beta": [EffortPolicy.claudeCodeMessageBeta, EffortPolicy.systemMessageBeta, EffortPolicy.toolChangesBeta].joined(separator: ",")]) { _, new in new }, body: base.body)
            #expect(await bridge.handleMessages(native).statusCode == 400)
        }
        #expect(await client.calls == 0)
    }
    @Test func temporaryInstructionBoundaryCannotAliasPermanentLegacyReplay() async throws {
        let permanent = #"[{"role":"user","content":"one"},{"role":"system","content":[{"type":"text","text":"instruction"}]},{"role":"assistant","content":[{"type":"tool_use","id":"call_clear","name":"Read","input":{"path":"a"}}]}]"#
        let prefix = try JSONDecoder().decode([AnthropicMessage].self, from: Data(permanent.utf8))
        let store = SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("siwc-clear-boundary-" + UUID().uuidString))
        try store.save(SIWCReplayRecord(key: "account-fixture:branch-fixture:" + SIWCBridge.legacyFingerprint(prefix), output: [.object(call("call_clear", itemID: "item_clear"))], route: Self.route))
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: store)
        let temporary = permanent.replacingOccurrences(of: #""text":"instruction"}]}"#, with: #""text":"instruction"}],"clear_at":"next_user_message"}"#)
        let continuation = String(temporary.dropLast()) + #",{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_clear","content":"file"}]}]"#
        let base = request(continuation)
        let native = HTTPRequest(method: base.method, path: base.path, headers: base.headers.merging(["anthropic-beta": EffortPolicy.systemMessageBeta]) { _, new in new }, body: base.body)
        #expect(await bridge.handleMessages(native).statusCode == 400)
        #expect(await client.calls == 0)
    }
    @Test func unsupportedImagesAndNestedResultsNeverSilentlyDisappear() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let input = request(#"[{"role":"user","content":[{"type":"image","source":{"type":"url","url":"https://example.invalid/image.png"}}]}]"#)
        #expect(await bridge.handleMessages(input).statusCode == 400)
        #expect(await client.calls == 0)
        #expect(throws: SIWCError.self) { try SIWCBridge.validateContent([JSONObject.from(["type": .string("tool_result"), "content": .array([.object(JSONObject.from(["type": .string("unknown")]))])])]) }
    }

    @Test func cancelledPreflightNeverStartsInference() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay())
        let input = request(#"[{"role":"user","content":"hello"}]"#)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await bridge.handleMessages(input)
        }
        #expect(await task.value.statusCode != 200)
        #expect(await client.calls == 0)
        #expect(await bridge.pendingToolTurnsCount() == 0)
    }

    private func effortRequest(_ history: String, effort: String, budget: Bool = false) -> HTTPRequest {
        let old = request(history)
        var body = try! JSONDecoder().decode(JSONObject.self, from: old.body)
        body["output_config"] = .object(JSONObject.from(["effort": .string(effort)]))
        if budget { body["thinking"] = .object(JSONObject.from(["type": .string("enabled"), "budget_tokens": .number(4096)])) }
        return HTTPRequest(method: old.method, path: old.path, headers: old.headers, body: try! JSONEncoder().encode(body))
    }
    @Test func fixedIgnoresClientEffortAndNeverNeedsCatalog() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay(), catalogProvider: { _ in throw SIWCError.remote("must_not_load") })
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: Self.route, singleModelMode: true), advisorRoute: Self.route)
        try await consume(bridge.handleMessages(effortRequest(#"[{"role":"user","content":"fixed"}]"#, effort: "ultra", budget: true)), SIWCFixtureWriter())
        #expect(await client.payload(0).object("reasoning")?.string("effort") == "low")
    }
    @Test func adjustedRouteIsPinnedAcrossClientAndRoutingChanges() async throws {
        let client = SIWCFixtureClient([[done(call("call_pin", itemID: "item_pin")), completed], [completed]])
        let catalog = SIWCModelCatalogSnapshot(accountID: "account-fixture", fetchedAt: Date(), models: [SIWCModelSummary(id: "fixture-model", label: "Fixture", accountID: "account-fixture", details: JSONObject.from(["supported_reasoning_levels": .array(["low", "medium", "high"].map { .object(JSONObject.from(["effort": .string($0)])) })]))])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: SIWCReplayStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), catalogProvider: { _ in catalog })
        let ceiling = ModelRoute(upstreamModel: "fixture-model", reasoningEffort: "high", textVerbosity: "low")
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: ceiling, allowClientEffort: true), advisorRoute: ceiling)
        try await consume(bridge.handleMessages(effortRequest(#"[{"role":"user","content":"pin"}]"#, effort: "medium")), SIWCFixtureWriter())
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "changed", reasoningEffort: "max", textVerbosity: "high"), allowClientEffort: true), advisorRoute: ceiling)
        try await consume(bridge.handleMessages(effortRequest(#"[{"role":"user","content":"pin"},{"role":"assistant","content":[{"type":"tool_use","id":"call_pin","name":"Read","input":{"path":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_pin","content":"file"}]}]"#, effort: "low")), SIWCFixtureWriter())
        #expect(await client.payload(0).object("reasoning")?.string("effort") == "medium")
        #expect(await client.payload(1).object("reasoning")?.string("effort") == "medium")
        #expect(await client.payload(1).string("model") == "fixture-model")
    }
    @Test func unsupportedAdjustmentFailsBeforeInference() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay(), catalogProvider: { _ in throw SIWCError.remote("metadata unavailable") })
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: Self.route, allowClientEffort: true), advisorRoute: Self.route)
        #expect(await bridge.handleMessages(effortRequest(#"[{"role":"user","content":"no call"}]"#, effort: "low")).statusCode == 400)
        #expect(await client.calls == 0)
    }

    @Test func fableRouteUsesFixedOrBoundedFollowEffort() async throws {
        let catalog = SIWCModelCatalogSnapshot(accountID: "account-fixture", fetchedAt: Date(), models: [SIWCModelSummary(id: "fixture-model", label: "Fixture", accountID: "account-fixture", details: JSONObject.from(["supported_reasoning_levels": .array(["low", "medium", "high"].map { .object(JSONObject.from(["effort": .string($0)])) })]))])
        for follow in [false, true] {
            let client = SIWCFixtureClient([[completed]])
            let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, replayStore: isolatedReplay(), catalogProvider: { _ in if !follow { throw SIWCError.remote("fixed must not load catalog") }; return catalog })
            let ceiling = ModelRoute(upstreamModel: "fixture-model", reasoningEffort: "high", textVerbosity: "medium")
            await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: Self.route, allowClientEffort: follow, fableRoute: ceiling), advisorRoute: Self.route)
            let old = effortRequest(#"[{"role":"user","content":"fable"}]"#, effort: "low")
            var body = try JSONDecoder().decode(JSONObject.self, from: old.body)
            body["model"] = .string("claude-fable-5-1")
            let input = HTTPRequest(method: old.method, path: old.path, headers: old.headers, body: try JSONEncoder().encode(body))
            try await consume(bridge.handleMessages(input), SIWCFixtureWriter())
            #expect(await client.payload(0).string("model") == "fixture-model")
            #expect(await client.payload(0).object("reasoning")?.string("effort") == (follow ? "low" : "high"))
            #expect(await client.payload(0).object("text")?.string("verbosity") == "medium")
        }
    }

}
