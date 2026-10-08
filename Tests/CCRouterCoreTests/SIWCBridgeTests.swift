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
private actor SIWCFixtureWriter: HTTPBodyWriter {
    var chunks = Data()
    func write(_ chunk: Data) { chunks.append(chunk) }
    func finish() {}
    var text: String { String(data: chunks, encoding: .utf8)! }
}
struct SIWCBridgeTests {
    static let route = ModelRoute(upstreamModel: "fixture-model", reasoningEffort: "low", textVerbosity: "low")
    static let tools = #"[{"name":"Read","description":"Read local file","input_schema":{"type":"object","properties":{"path":{"type":"string"}}}}]"#
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
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client)
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
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client)
        #expect(await bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#, tools: #"[{"type":"web_search_20250305","name":"web_search"}]"#)).statusCode == 400)
        #expect(await client.calls == 0)
    }
    @Test func undeclaredToolCannotBeEmittedAsExecutable() async throws {
        let client = SIWCFixtureClient([[done(call("call_bad", itemID: "item_bad", name: "Undeclared")), completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client)
        let writer = SIWCFixtureWriter()
        await #expect(throws: SIWCError.self) { try await consume(bridge.handleMessages(request(#"[{"role":"user","content":"hello"}]"#)), writer) }
        #expect(!(await writer.text).contains("Undeclared"))
        #expect(!(await writer.text).contains("message_stop"))
    }

    @Test func abandonedResponseReleasesUpstreamAndDoesNotClearANewerLease() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client)
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
    @Test func unsupportedImagesAndNestedResultsNeverSilentlyDisappear() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client)
        let input = request(#"[{"role":"user","content":[{"type":"image","source":{"type":"url","url":"https://example.invalid/image.png"}}]}]"#)
        #expect(await bridge.handleMessages(input).statusCode == 400)
        #expect(await client.calls == 0)
        #expect(throws: SIWCError.self) { try SIWCBridge.validateContent([JSONObject.from(["type": .string("tool_result"), "content": .array([.object(JSONObject.from(["type": .string("unknown")]))])])]) }
    }

    @Test func cancelledPreflightNeverStartsInference() async throws {
        let client = SIWCFixtureClient([[completed]])
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client)
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
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, catalogProvider: { _ in throw SIWCError.remote("must_not_load") })
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
        let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, catalogProvider: { _ in throw SIWCError.remote("metadata unavailable") })
        await bridge.updateRouting(table: ModelRoutingTable(rules: [], fallback: Self.route, allowClientEffort: true), advisorRoute: Self.route)
        #expect(await bridge.handleMessages(effortRequest(#"[{"role":"user","content":"no call"}]"#, effort: "low")).statusCode == 400)
        #expect(await client.calls == 0)
    }

    @Test func fableRouteUsesFixedOrBoundedFollowEffort() async throws {
        let catalog = SIWCModelCatalogSnapshot(accountID: "account-fixture", fetchedAt: Date(), models: [SIWCModelSummary(id: "fixture-model", label: "Fixture", accountID: "account-fixture", details: JSONObject.from(["supported_reasoning_levels": .array(["low", "medium", "high"].map { .object(JSONObject.from(["effort": .string($0)])) })]))])
        for follow in [false, true] {
            let client = SIWCFixtureClient([[completed]])
            let bridge = SIWCBridge(configuration: config(), auth: SIWCFixtureAuth(), client: client, catalogProvider: { _ in if !follow { throw SIWCError.remote("fixed must not load catalog") }; return catalog })
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
