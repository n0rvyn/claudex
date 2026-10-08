import Foundation
import Testing
@testable import CCRouterCore

private struct SIWCFixtureAuth: SubscriptionSessionProviding {
    func loadCurrent() async throws -> SubscriptionCredentials { SubscriptionCredentials(accessToken: "fixture-only", accountID: "account-fixture") }
}
private actor SIWCFixtureClient: ResponsesStreamingClient {
    var payloads: [JSONObject] = []
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

}
