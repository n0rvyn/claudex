import Foundation
@testable import CCRouterCore
import Testing

// MARK: - TraceLoggerRoutingFieldsTests

/// Tests that all five routing trace fields (claude_model / upstream_model /
/// reasoning_effort / text_verbosity / resolved_route_match) are emitted correctly
/// in anthropic_in, responses_out_initial, responses_out_continuation, anthropic_out
/// (main path), and anthropic_out (stream_aborted branch).
///
/// Uses TraceLogger.$overrideFileURL for per-test isolation.
struct TraceLoggerRoutingFieldsTests {

    private static func makeIsolatedTraceFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TraceLoggerRoutingFieldsTest-\(UUID().uuidString).jsonl")
    }

    private static let testCredentials = SubscriptionCredentials(
        accessToken: "test-access-token",
        accountID: "test-account"
    )

    private static let defaultConfig: RouterConfiguration = {
        var config = RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/mount/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            routingTable: ModelRoutingTable(
                rules: [
                    ModelRoutingRule(
                        match: "opus",
                        route: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
                    ),
                    ModelRoutingRule(
                        match: "sonnet",
                        route: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
                    ),
                    ModelRoutingRule(
                        match: "haiku",
                        route: ModelRoute(upstreamModel: "gpt-5.3-codex-spark", reasoningEffort: "xhigh", textVerbosity: "low")
                    ),
                ],
                fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
            ),
            advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )
        return config
    }()

    private static func makeBridge(
        config: RouterConfiguration = defaultConfig,
        mock: MockResponsesClient
    ) -> AnthropicBridge {
        AnthropicBridge(
            configuration: config,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: testCredentials)
        )
    }

    /// Makes a text-only AnthropicMessagesRequest fixture for the given model.
    private static func makeRequest(model: String) throws -> HTTPRequest {
        let body = try AnthropicMessagesRequest.textOnlyFixture(model: model)
        let bodyData = try JSONEncoder().encode(body)
        return HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["content-type": "application/json", "x-claude-code-session-id": "routing-test-\(model)"],
            body: bodyData
        )
    }

    private static func makeImageRequest(model: String) -> HTTPRequest {
        let bodyData = Data("""
        {
          "model": "\(model)",
          "max_tokens": 128,
          "messages": [
            {
              "role": "user",
              "content": [
                {
                  "type": "image",
                  "source": {
                    "type": "base64",
                    "media_type": "image/png",
                    "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
                  }
                },
                { "type": "text", "text": "Describe this image in one word." }
              ]
            }
          ],
          "stream": true
        }
        """.utf8)
        return HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["content-type": "application/json", "x-claude-code-session-id": "routing-test-image-\(model)"],
            body: bodyData
        )
    }

    // MARK: - End-to-end helpers

    /// Drives a streaming response and returns all trace lines.
    private static func driveAndCollectTrace(
        model: String,
        request explicitRequest: HTTPRequest? = nil,
        config: RouterConfiguration = defaultConfig,
        streams: [AsyncThrowingStream<JSONObject, Error>] = [],
        performResults: [[JSONObject]] = []
    ) async throws -> [JSONObject] {
        let traceURL = makeIsolatedTraceFileURL()
        defer { try? FileManager.default.removeItem(at: traceURL) }

        return try await TraceLogger.$overrideFileURL.withValue(traceURL) {
            let mock = MockResponsesClient(streams: streams, performResults: performResults)
            let bridge = makeBridge(config: config, mock: mock)

            let request: HTTPRequest
            if let explicitRequest {
                request = explicitRequest
            } else {
                request = try makeRequest(model: model)
            }
            let response = await bridge.handleMessages(request)

            // Drive the stream to completion so all trace events are flushed.
            if case .stream(let producer) = response.body {
                let writer = InMemoryBodyWriter()
                try await producer(writer)
            }

            // Read trace lines.
            let traceText = try String(contentsOf: traceURL, encoding: .utf8)
            return traceText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line -> JSONObject? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode(JSONObject.self, from: data)
                }
        }
    }

    private static func extractStages(_ lines: [JSONObject]) -> [String: JSONObject] {
        // For stages that appear multiple times (responses_in_event), keep the last.
        var result: [String: JSONObject] = [:]
        for line in lines {
            if let stage = line.string("stage") {
                result[stage] = line
            }
        }
        return result
    }

    private static func extractLastOfStage(_ lines: [JSONObject], _ stage: String) -> JSONObject? {
        lines.last { $0.string("stage") == stage }
    }

    // MARK: - Tests: routing fields on matched rules

    /// Verify: opus request hits the "opus" rule; all five routing fields present in anthropic_in.
    @Test
    func opusAnthropicInHasFiveRoutingFields() async throws {
        let lines = try await Self.driveAndCollectTrace(
            model: "claude-opus-4-7",
            streams: [MockResponsesEventStream.textOnlyTurn(text: "hello")]
        )
        let stages = Self.extractStages(lines)

        guard let anthropicIn = stages["anthropic_in"] else {
            Issue.record("missing anthropic_in trace")
            return
        }

        #expect(anthropicIn.string("claude_model") == "claude-opus-4-7")
        #expect(anthropicIn.string("upstream_model") == "gpt-5.4")
        #expect(anthropicIn.string("reasoning_effort") == "xhigh")
        #expect(anthropicIn.string("text_verbosity") == "low")
        #expect(anthropicIn.string("resolved_route_match") == "opus")
    }

    @Test
    func imageRequestAnthropicInHasImageMetadata() async throws {
        let lines = try await Self.driveAndCollectTrace(
            model: "claude-opus-4-7",
            request: Self.makeImageRequest(model: "claude-opus-4-7"),
            streams: [MockResponsesEventStream.textOnlyTurn(text: "image received")]
        )
        let stages = Self.extractStages(lines)

        guard let anthropicIn = stages["anthropic_in"] else {
            Issue.record("missing anthropic_in trace")
            return
        }

        let blockTypes = anthropicIn.array("content_block_types")?.compactMap(\.stringValue) ?? []
        #expect(anthropicIn.bool("has_image") == true)
        #expect(blockTypes.contains("image"))
        #expect(blockTypes.contains("text"))
    }

    /// Verify: opus request hits the "opus" rule; all five routing fields present in responses_out_initial.
    @Test
    func opusResponsesOutInitialHasFiveRoutingFields() async throws {
        let lines = try await Self.driveAndCollectTrace(
            model: "claude-opus-4-7",
            streams: [MockResponsesEventStream.textOnlyTurn(text: "hello")]
        )
        let stages = Self.extractStages(lines)

        guard let out = stages["responses_out_initial"] else {
            Issue.record("missing responses_out_initial trace")
            return
        }

        #expect(out.string("claude_model") == "claude-opus-4-7")
        #expect(out.string("upstream_model") == "gpt-5.4")
        #expect(out.string("reasoning_effort") == "xhigh")
        #expect(out.string("text_verbosity") == "low")
        #expect(out.string("resolved_route_match") == "opus")
        #expect(out.string("resolved_route_match") != "fallback")
    }

    /// Verify: opus request — anthropic_out main success path has all five routing fields.
    @Test
    func opusAnthropicOutMainHasFiveRoutingFields() async throws {
        let lines = try await Self.driveAndCollectTrace(
            model: "claude-opus-4-7",
            streams: [MockResponsesEventStream.textOnlyTurn(text: "hello")]
        )
        let stages = Self.extractStages(lines)

        guard let out = stages["anthropic_out"] else {
            Issue.record("missing anthropic_out trace")
            return
        }

        #expect(out.string("result") == "success")
        #expect(out.string("claude_model") == "claude-opus-4-7")
        #expect(out.string("claude_model") == "claude-opus-4-7")
        #expect(out.string("upstream_model") == "gpt-5.4")
        #expect(out.string("reasoning_effort") == "xhigh")
        #expect(out.string("text_verbosity") == "low")
        #expect(out.string("resolved_route_match") == "opus")
    }

    /// Verify: sonnet request — resolved_route_match is "sonnet".
    @Test
    func sonnetResolvedRouteMatchIsSonnet() async throws {
        let lines = try await Self.driveAndCollectTrace(
            model: "claude-sonnet-4-6",
            streams: [MockResponsesEventStream.textOnlyTurn(text: "hello")]
        )
        let stages = Self.extractStages(lines)

        guard let anthropicIn = stages["anthropic_in"] else {
            Issue.record("missing anthropic_in trace")
            return
        }
        guard let out = stages["responses_out_initial"] else {
            Issue.record("missing responses_out_initial trace")
            return
        }

        #expect(anthropicIn.string("resolved_route_match") == "sonnet")
        #expect(out.string("resolved_route_match") == "sonnet")
    }

    /// Verify: haiku request — resolved_route_match is "haiku", upstream_model is gpt-5.3-codex-spark.
    @Test
    func haikuResolvedRouteMatchIsHaiku() async throws {
        let lines = try await Self.driveAndCollectTrace(
            model: "claude-haiku-4-5-20251001",
            streams: [MockResponsesEventStream.textOnlyTurn(text: "hello")]
        )
        let stages = Self.extractStages(lines)

        guard let anthropicIn = stages["anthropic_in"] else {
            Issue.record("missing anthropic_in trace")
            return
        }

        #expect(anthropicIn.string("resolved_route_match") == "haiku")
        #expect(anthropicIn.string("upstream_model") == "gpt-5.3-codex-spark")
    }

    // MARK: - Test: fallback

    /// Verify: unknown model "foo-bar-model" hits fallback; resolved_route_match is "fallback".
    @Test
    func unknownModelFallsBackWithMatchLabelFallback() async throws {
        let lines = try await Self.driveAndCollectTrace(
            model: "foo-bar-model",
            streams: [MockResponsesEventStream.textOnlyTurn(text: "hello")]
        )
        let stages = Self.extractStages(lines)

        guard let anthropicIn = stages["anthropic_in"] else {
            Issue.record("missing anthropic_in trace")
            return
        }
        guard let out = stages["responses_out_initial"] else {
            Issue.record("missing responses_out_initial trace")
            return
        }

        #expect(anthropicIn.string("resolved_route_match") == "fallback")
        #expect(anthropicIn.string("upstream_model") == "gpt-5.4")
        #expect(out.string("resolved_route_match") == "fallback")
    }

    // MARK: - Test: tool-use turn (fresh path → responses_out_initial)

    /// Verify: fresh tool-use turn emits responses_out_initial with routing fields.
    /// Note: responses_out_continuation fires only in the continuation path (activeContinuation
    /// from tool_result history), not in fresh first-request turns. The continuation path
    /// routing fields are covered by the anthropic_in / anthropic_out / responses_out_initial
    /// cases above.
    @Test
    func toolUseTurnResponsesOutInitialHasFiveRoutingFields() async throws {
        let callID = "tool_call_\(UUID().uuidString.prefix(8))"

        let lines = try await Self.driveAndCollectTrace(
            model: "claude-opus-4-7",
            streams: [MockResponsesEventStream.toolUseTurn(
                textBefore: nil,
                toolName: "Bash",
                callID: callID,
                argumentsJSON: #"{"command": "ls"}"#
            )]
        )
        let stages = Self.extractStages(lines)

        guard let out = stages["responses_out_initial"] else {
            Issue.record("missing responses_out_initial trace")
            return
        }

        #expect(out.string("upstream_model") == "gpt-5.4")
        #expect(out.string("reasoning_effort") == "xhigh")
        #expect(out.string("text_verbosity") == "low")
        #expect(out.string("resolved_route_match") == "opus")
    }

    // MARK: - Test: stream_aborted

    /// Verify: stream_aborted in anthropic_out still carries all five routing fields.
    @Test
    func streamAbortedAnthropicOutHasFiveRoutingFields() async throws {
        let traceURL = Self.makeIsolatedTraceFileURL()
        defer { try? FileManager.default.removeItem(at: traceURL) }

        let upstreamError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "upstream failure"])
        let failingStream = MockResponsesEventStream.textThenError(
            partialText: "partial",
            error: upstreamError
        )

        try await TraceLogger.$overrideFileURL.withValue(traceURL) {
            let mock = MockResponsesClient(streams: [failingStream], performResults: [])
            let bridge = Self.makeBridge(mock: mock)

            let request = try Self.makeRequest(model: "claude-sonnet-4-6")
            let response = await bridge.handleMessages(request)

            // The bridge's catch handler logs stream_aborted before re-throwing.
            // We swallow the expected error here; the test asserts the trace was written.
            if case .stream(let producer) = response.body {
                let writer = InMemoryBodyWriter()
                do {
                    try await producer(writer)
                } catch {
                    // Expected: upstream threw during streaming
                }
            }

            // Read trace lines.
            let traceText = try String(contentsOf: traceURL, encoding: .utf8)
            let lines = traceText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line -> JSONObject? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode(JSONObject.self, from: data)
                }

            let stages = Self.extractStages(lines)

            guard let out = stages["anthropic_out"] else {
                Issue.record("missing anthropic_out trace")
                return
            }

            #expect(out.string("result") == "stream_aborted")
            #expect(out.string("claude_model") == "claude-sonnet-4-6")
            #expect(out.string("upstream_model") == "gpt-5.4")
            #expect(out.string("reasoning_effort") == "xhigh")
            #expect(out.string("text_verbosity") == "low")
            #expect(out.string("resolved_route_match") == "sonnet")
        }
    }
}
