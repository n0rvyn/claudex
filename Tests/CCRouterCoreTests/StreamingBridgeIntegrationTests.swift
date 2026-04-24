import Foundation
@testable import CCRouterCore
import Testing

// MARK: - StreamingBridgeIntegrationTests

private actor StreamTimingProbe {
    private var firstUpstreamTextDelta: ContinuousClock.Instant?

    func recordFirstUpstreamTextDelta() {
        guard firstUpstreamTextDelta == nil else { return }
        firstUpstreamTextDelta = .now
    }

    func upstreamTextDeltaTime() -> ContinuousClock.Instant? {
        firstUpstreamTextDelta
    }
}

private actor TimedTextDeltaStreamingClient: ResponsesStreamingClient {
    private let timingProbe: StreamTimingProbe

    init(timingProbe: StreamTimingProbe) {
        self.timingProbe = timingProbe
    }

    func streamEvents(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> AsyncThrowingStream<JSONObject, Error> {
        AsyncThrowingStream<JSONObject, Error> { continuation in
            Task {
                continuation.yield(JSONObject.from(["type": .string("response.created")]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "item": .object(JSONObject.from([
                        "type": .string("message"),
                        "id": .string("msg_latency"),
                    ])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.added"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                    "part": .object(JSONObject.from([
                        "type": .string("output_text"),
                        "text": .string(""),
                    ])),
                ]))
                await timingProbe.recordFirstUpstreamTextDelta()
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.delta"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                    "delta": .string("Hello world"),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.done"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.done"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.done"),
                    "output_index": .number(0),
                    "item": .object(JSONObject.from([
                        "type": .string("message"),
                        "id": .string("msg_latency"),
                        "content": .array([
                            .object(JSONObject.from([
                                "type": .string("output_text"),
                                "text": .string("Hello world"),
                            ])),
                        ]),
                    ])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.completed"),
                    "response": .object(JSONObject.from([
                        "usage": .object(JSONObject.from([
                            "input_tokens": .number(10),
                            "output_tokens": .number(5),
                        ])),
                    ])),
                ]))
                continuation.finish()
            }
        }
    }

    func perform(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> [JSONObject] {
        []
    }
}

/// Integration tests that drive AnthropicBridge end-to-end with mock upstream streams.
/// These tests verify streaming behaviour, wire-level SSE frame shapes, and the
/// chunked-transfer encoding contract.
struct StreamingBridgeIntegrationTests {

    // MARK: - Shared test configuration

    private static let testConfig = RouterConfiguration(
        host: "127.0.0.1",
        port: 4317,
        healthPath: "/health",
        messagesPath: "/v1/messages",
        countTokensPath: "/v1/messages/count_tokens",
        responsesURL: "https://chatgpt.com/backend-api/codex/responses",
        executorModel: "gpt-5.4",
        advisorModel: "gpt-5.4",
        gatewayAuthToken: "test-token",
        gatewayAuthHeader: "x-api-key",
        subscriptionAuthFilePath: "/dev/null/auth.json",
        configurationPath: "/dev/null/config.json",
        configurationWarning: nil
    )

    private static let testCredentials = SubscriptionCredentials(
        accessToken: "test-token",
        accountID: "test-account"
    )

    // MARK: - Helpers

    /// Wraps an AnthropicMessagesRequest in an HTTPRequest body.
    private static func makeHTTPRequest(
        body: AnthropicMessagesRequest,
        extraHeaders: [String: String] = [:]
    ) -> HTTPRequest {
        let bodyData = try! JSONEncoder().encode(body)
        return HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: extraHeaders.merging(["content-type": "application/json"]) { _, new in new },
            body: bodyData
        )
    }

    /// Builds a minimal tool-use turn request body.
    private static func makeToolRequest(callID: String, toolUseID: String? = nil) -> AnthropicMessagesRequest {
        var content: [JSONObject] = [
            JSONObject.from(["type": .string("text"), "text": .string("Run it")]),
        ]
        if let tid = toolUseID {
            content.append(JSONObject.from([
                "type": .string("tool_result"),
                "tool_use_id": .string(tid),
                "content": .string("success"),
            ]))
        }

        let bashTool = JSONObject.from([
            "type": .string("function"),
            "name": .string("Bash"),
            "description": .string("Run a bash command"),
            "input_schema": .object(JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                ])),
            ])),
        ])

        return AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: content)],
            system: nil,
            tools: [bashTool],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
    }

    /// Builds a request that includes the advisor tool.
    private static func makeAdvisorRequest(callID: String) -> AnthropicMessagesRequest {
        let advisorTool = JSONObject.from([
            "type": .string("advisor_20260301"),
        ])

        return AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("Advise me")]),
                ]),
            ],
            system: nil,
            tools: [advisorTool],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
    }

    /// Parses SSE frames from an InMemoryBodyWriter's concatenated output.
    private static func parseSSEFrames(from writer: InMemoryBodyWriter) async -> [(event: String, data: JSONObject)] {
        await writer.parseSSEFrames()
    }

    // MARK: - Tests

    @Test func firstContentBlockDeltaArrivesWithin50MsOfFirstUpstreamDelta() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let timingProbe = StreamTimingProbe()
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: TimedTextDeltaStreamingClient(timingProbe: timingProbe),
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))

        let response = await bridge.handleMessages(request)

        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected .stream body")
            return
        }

        try await producer(writer)
        guard let upstreamDeltaTime = await timingProbe.upstreamTextDeltaTime() else {
            Issue.record("Missing upstream text delta timestamp")
            return
        }
        guard let firstContentDeltaTime = await writer.firstChunkTimestamp(containing: "event: content_block_delta\n") else {
            Issue.record("Missing content_block_delta write")
            return
        }
        let elapsed = firstContentDeltaTime - upstreamDeltaTime

        #expect(elapsed < .milliseconds(50))

        let frames = await Self.parseSSEFrames(from: writer)
        #expect(!frames.isEmpty)
        let deltaFrames = frames.filter { $0.data.string("type") == "content_block_delta" }
        #expect(deltaFrames.count >= 1)
    
        }
    }

    @Test func responseBodyIsStreamFormAndNotDataFallback() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(text: "Hello"),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))

        let response = await bridge.handleMessages(request)

        // Bridge must return a streaming response body, not buffered data.
        #expect(response.bodyData == nil)
    
        }
    }

    @Test func textDeltasAreEmittedIncrementallyNotAggregated() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textOnlyTurn(text: "ABC", deltaDelays: []),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        if case .stream(let producer) = response.body {
            try await producer(writer)
        }

        let frames = await Self.parseSSEFrames(from: writer)
        // The frame type at the top level is "content_block_delta"; the text delta
        // type is nested inside the "delta" object.
        let deltaFrames = frames.filter { $0.data.string("type") == "content_block_delta" }

        // Three deltas expected (at least 3, since MockResponsesEventStream splits into 3).
        #expect(deltaFrames.count >= 3)

        // Verify the deltas contain partial text (not the whole "ABC" in one frame).
        let innerTexts = deltaFrames.compactMap { $0.data.object("delta")?.string("text") }
        // All three deltas together should form "ABC"; if only one delta has "ABC" it means aggregation.
        #expect(!(innerTexts.count == 1 && innerTexts[0] == "ABC"))
    
        }
    }

    @Test func toolUseTurnStopsWithToolUseReason() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // First pass: mock returns function_call. No tool_result in request → initial turn.
        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.toolUseTurn(
                textBefore: nil,
                toolName: "Bash",
                callID: "toolu_bash_1",
                argumentsJSON: "{\"command\":\"true\"}"
            ),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        // This is an INITIAL turn (no pending tool_result in request).
        let request = Self.makeHTTPRequest(body: AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("run")])])],
            system: nil,
            tools: [JSONObject.from([
                "type": .string("function"),
                "name": .string("Bash"),
                "description": .string("Run bash"),
                "input_schema": .object(JSONObject.from([
                    "type": .string("object"),
                    "properties": .object(JSONObject()),
                ])),
            ])],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        if case .stream(let producer) = response.body {
            try await producer(writer)
        }

        let frames = await Self.parseSSEFrames(from: writer)

        // Look for message_delta with stop_reason == "tool_use".
        // The stop_reason is in the "delta" nested object of the message_delta frame.
        var sawToolUseMessageDelta = false
        for frame in frames {
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") == "tool_use" {
                sawToolUseMessageDelta = true
            }
        }
        #expect(sawToolUseMessageDelta)
    
        }
    }

    @Test func advisorTurnStreamsThroughTwoPasses() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let advisorCallID = "toolu_advisor_1"

        let mock = MockResponsesClient(
            streams: [
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "advisor",
                    callID: advisorCallID,
                    argumentsJSON: "{}"
                ),
                MockResponsesEventStream.textOnlyTurn(text: "Final reply from advisor"),
            ],
            performResults: [
                [
                    JSONObject.from([
                        "type": .string("response.output_item.done"),
                        "item": .object(JSONObject.from([
                            "type": .string("message"),
                            "content": .array([
                                .object(JSONObject.from([
                                    "type": .string("output_text"),
                                    "text": .string("Suggested approach: use the right tool"),
                                ])),
                            ]),
                        ])),
                    ]),
                ],
            ]
        )

        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: Self.makeAdvisorRequest(callID: advisorCallID))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        if case .stream(let producer) = response.body {
            try await producer(writer)
        }

        let frames = await Self.parseSSEFrames(from: writer)
        var sawServerToolUse = false
        var sawAdvisorToolResult = false
        var sawFinalMessageDelta = false

        for frame in frames {
            // server_tool_use and advisor_tool_result are in the content_block of content_block_start frames.
            if let cb = frame.data.object("content_block") {
                if cb.string("type") == "server_tool_use", cb.string("name") == "advisor" {
                    sawServerToolUse = true
                }
                if cb.string("type") == "advisor_tool_result",
                   cb.string("tool_use_id") == advisorCallID {
                    sawAdvisorToolResult = true
                }
            }
            // message_delta stop_reason: inside the "delta" nested object.
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") == "end_turn" {
                if sawServerToolUse && sawAdvisorToolResult {
                    sawFinalMessageDelta = true
                }
            }
        }

        #expect(sawServerToolUse)
        #expect(sawAdvisorToolResult)
        #expect(sawFinalMessageDelta)
    
        }
    }

    @Test func toolUseBlockFollowedByMoreTextOpensNewBlockIndex() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // Tests AnthropicSSEEncoder block index management:
        // text delta x2 → function_call item → text delta x1 should produce
        // content_block_start frames with indices 0 (text), 1 (tool_use), 2 (text).

        let customStream = AsyncThrowingStream<JSONObject, Error> { continuation in
            Task {
                continuation.yield(JSONObject.from(["type": .string("response.created")]))

                // Message item with text
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "output_index": .number(0),
                    "item": .object(JSONObject.from(["type": .string("message"), "id": .string("msg_1")])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.added"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                    "part": .object(JSONObject.from(["type": .string("output_text"), "text": .string("")]))
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.delta"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                    "delta": .string("Hello "),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.delta"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                    "delta": .string("world"),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.done"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.done"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.done"),
                    "output_index": .number(0),
                    "item": .object(JSONObject.from([
                        "type": .string("message"),
                        "id": .string("msg_1"),
                        "content": .array([
                            .object(JSONObject.from(["type": .string("output_text"), "text": .string("Hello world")]))
                        ]),
                    ])),
                ]))

                // Function call item.  Real upstream `function_call` items carry both
                // `id` (item-level identifier, e.g. `fc_xxx`) and `call_id` (the call
                // identifier used by IRResponsesCodec.decodeOutputItem).  Using only `id`
                // makes the codec return nil and the bridge silently skips the tool_use.
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "output_index": .number(1),
                    "item": .object(JSONObject.from([
                        "type": .string("function_call"),
                        "id": .string("fc_toolu_1"),
                        "call_id": .string("toolu_1"),
                        "name": .string("Bash"),
                        "arguments": .string("{\"command\":\"true\"}"),
                    ])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.done"),
                    "output_index": .number(1),
                    "item": .object(JSONObject.from([
                        "type": .string("function_call"),
                        "id": .string("fc_toolu_1"),
                        "call_id": .string("toolu_1"),
                        "name": .string("Bash"),
                        "arguments": .string("{\"command\":\"true\"}"),
                    ])),
                ]))

                // Third text block
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "output_index": .number(2),
                    "item": .object(JSONObject.from(["type": .string("message"), "id": .string("msg_2")])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.added"),
                    "output_index": .number(2),
                    "content_index": .number(0),
                    "part": .object(JSONObject.from(["type": .string("output_text"), "text": .string("")]))
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.delta"),
                    "output_index": .number(2),
                    "content_index": .number(0),
                    "delta": .string("After tool"),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.done"),
                    "output_index": .number(2),
                    "content_index": .number(0),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.done"),
                    "output_index": .number(2),
                    "content_index": .number(0),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.done"),
                    "output_index": .number(2),
                    "item": .object(JSONObject.from([
                        "type": .string("message"),
                        "id": .string("msg_2"),
                        "content": .array([
                            .object(JSONObject.from(["type": .string("output_text"), "text": .string("After tool")]))
                        ]),
                    ])),
                ]))

                continuation.yield(JSONObject.from([
                    "type": .string("response.completed"),
                    "response": .object(JSONObject.from([
                        "usage": .object(JSONObject.from([
                            "input_tokens": .number(10),
                            "output_tokens": .number(5),
                        ])),
                    ])),
                ]))

                continuation.finish()
            }
        }

        let mock = MockResponsesClient(streams: [customStream])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("run")])])],
            system: nil,
            tools: [JSONObject.from([
                "type": .string("function"),
                "name": .string("Bash"),
                "description": .string("Run bash"),
                "input_schema": .object(JSONObject()),
            ])],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        if case .stream(let producer) = response.body {
            try await producer(writer)
        }

        let frames = await Self.parseSSEFrames(from: writer)
        // content_block_start frames have type="content_block_start" and carry index.
        let blockStartFrames = frames.filter {
            $0.data.string("type") == "content_block_start" && $0.data.values["index"] != nil
        }

        // Should have at least 3 content_block_start frames (text0, tool_use, text2).
        #expect(blockStartFrames.count >= 3)

        // Extract indices from the frame data.
        let indices = blockStartFrames.compactMap { $0.data.values["index"]?.intValue }
        #expect(indices.contains(0))
        #expect(indices.contains(1))
        #expect(indices.contains(2))
        // Indices should appear exactly once each.
        #expect(indices.filter { $0 == 0 }.count == 1)
        #expect(indices.filter { $0 == 1 }.count == 1)
    
        }
    }

    @Test func streamErrorPathPreservesPendingToolTurnForRetry() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // First pass: function_call → pendingToolTurns.
        // Second pass: accepted continuation aborts mid-flight.
        // Third pass: same continuation retries successfully with preserved pending state.
        let error = NSError(domain: "TestError", code: 42, userInfo: [NSLocalizedDescriptionKey: "test upstream failure"])

        let firstStream = MockResponsesEventStream.toolUseTurn(
            textBefore: nil,
            toolName: "Bash",
            callID: "toolu_bash_1",
            argumentsJSON: "{\"command\":\"true\"}"
        )
        let secondStream = MockResponsesEventStream.textThenError(
            partialText: "Partial",
            error: error
        )
        let thirdStream = MockResponsesEventStream.textOnlyTurn(
            text: "Retry succeeded."
        )

        let mock = MockResponsesClient(streams: [firstStream, secondStream, thirdStream])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )
        let sessionHeader = ["x-claude-code-session-id": "stream-error-pending-session"]

        // First turn.
        let firstRequest = Self.makeHTTPRequest(body: AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("run")])])],
            system: nil,
            tools: [JSONObject.from([
                "type": .string("function"),
                "name": .string("Bash"),
                "description": .string("Run bash"),
                "input_schema": .object(JSONObject()),
            ])],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ), extraHeaders: sessionHeader)

        let firstResponse = await bridge.handleMessages(firstRequest)
        let firstWriter = InMemoryBodyWriter()
        if case .stream(let producer) = firstResponse.body {
            try await producer(firstWriter)
        }

        // Verify pending turn via wire: message_delta stop_reason == "tool_use".
        let firstFrames = await Self.parseSSEFrames(from: firstWriter)
        var sawToolUseStop = false
        for frame in firstFrames {
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") == "tool_use" {
                sawToolUseStop = true
            }
        }
        #expect(sawToolUseStop)

        // Second turn with error.
        let secondRequest = Self.makeHTTPRequest(
            body: AnthropicMessagesRequest(
                model: "claude-4-sonnet",
                max_tokens: 4096,
                messages: [
                    AnthropicMessage(role: "assistant", content: [
                        JSONObject.from([
                            "type": .string("tool_use"),
                            "id": .string("toolu_bash_1"),
                            "name": .string("Bash"),
                            "input": .object(JSONObject.from(["command": .string("true")])),
                        ]),
                    ]),
                    AnthropicMessage(role: "user", content: [
                        JSONObject.from(["type": .string("text"), "text": .string("Run it")]),
                        JSONObject.from([
                            "type": .string("tool_result"),
                            "tool_use_id": .string("toolu_bash_1"),
                            "content": .string("success"),
                        ]),
                    ]),
                ],
                system: nil,
                tools: nil,
                thinking: nil,
                context_management: nil,
                metadata: nil,
                output_config: nil,
                stream: true
            ),
            extraHeaders: sessionHeader
        )
        let secondResponse = await bridge.handleMessages(secondRequest)
        let secondWriter = InMemoryBodyWriter()

        // Bridge handles the error gracefully — error is rethrown to the stream producer.
        do {
            if case .stream(let producer) = secondResponse.body {
                try await producer(secondWriter)
            }
        } catch {
            // Expected: error propagates from the upstream mock.
        }

        // Verify error marker text is present.
        let secondBody = await secondWriter.concatenatedString
        #expect(secondBody.contains("[upstream error"))
        #expect(await bridge.pendingToolTurnsCount() == 1)

        let retryResponse = await bridge.handleMessages(secondRequest)
        let retryWriter = InMemoryBodyWriter()
        if case .stream(let retryProducer) = retryResponse.body {
            try await retryProducer(retryWriter)
        } else {
            Issue.record("Expected retry continuation to stream")
        }

        let retryFrames = await Self.parseSSEFrames(from: retryWriter)
        #expect(retryFrames.contains {
            $0.data.string("type") == "content_block_delta" &&
            ($0.data.object("delta")?.string("text")?.contains("Retry") ?? false)
        })
        #expect(await bridge.pendingToolTurnsCount() == 0)
        #expect(await mock.capturedRequests.count == 3)
    
        }
    }

    @Test func streamAbortedUpstreamEmitsErrorMarkerAndStopsClean() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let error = NSError(domain: "TestError", code: 99, userInfo: [NSLocalizedDescriptionKey: "connection reset"])

        let mock = MockResponsesClient(streams: [
            MockResponsesEventStream.textThenError(partialText: "Partial text", error: error),
        ])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        // Bridge emits the best-effort error marker, then rethrows to the
        // producer — the test catches it just like LocalHTTPServer would.
        do {
            if case .stream(let producer) = response.body {
                try await producer(writer)
            }
        } catch {
            // Expected: upstream mock error propagates after the error marker is emitted.
        }

        let bodyString = await writer.concatenatedString
        #expect(bodyString.contains("[upstream error"))

        let frames = await Self.parseSSEFrames(from: writer)
        var sawMessageDelta = false
        for frame in frames {
            if frame.data.string("type") == "message_delta",
               frame.data.object("delta")?.string("stop_reason") != nil {
                sawMessageDelta = true
            }
        }
        #expect(sawMessageDelta)
    
        }
    }

    @Test func chunkedTransferHeadersExcludeContentLength() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // Byte-level assertion on the exact header bytes emitted by the
        // streaming branch. Uses ChunkedHTTPEncoder.buildHeaderBytes — the
        // same helper LocalHTTPServer.sendStreamBody calls — so we test the
        // real wire format, not a structural placeholder.
        let userHeaders: [String: String] = [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            // Intentionally include a bogus Content-Length that MUST be filtered.
            "Content-Length": "999",
        ]

        let headerBytes = ChunkedHTTPEncoder.buildHeaderBytes(
            statusCode: 200,
            reasonPhrase: "OK",
            userHeaders: userHeaders
        )
        let headerString = String(data: headerBytes, encoding: .utf8) ?? ""

        // Status line exact bytes.
        #expect(headerString.hasPrefix("HTTP/1.1 200 OK\r\n"))
        // Must contain Transfer-Encoding: chunked.
        #expect(headerString.contains("Transfer-Encoding: chunked\r\n"))
        // Must NOT contain any Content-Length header (RFC 9112 §6.2).
        #expect(!headerString.lowercased().contains("content-length"))
        // Must end with terminating \r\n\r\n.
        #expect(headerString.hasSuffix("\r\n\r\n"))
        // User headers preserved.
        #expect(headerString.contains("Content-Type: text/event-stream\r\n"))
        #expect(headerString.contains("Cache-Control: no-cache\r\n"))
    
        }
    }

    @Test func chunkedFrameFormatMatchesRFC9112() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // <hex-size>\r\n<bytes>\r\n per RFC 9112 §7.1.
        let chunk = Data("hello".utf8)
        let encoded = ChunkedHTTPEncoder.formatChunk(chunk)
        #expect(encoded == Data("5\r\nhello\r\n".utf8))

        // Empty chunk — still well-formed (size 0).
        let emptyEncoded = ChunkedHTTPEncoder.formatChunk(Data())
        #expect(emptyEncoded == Data("0\r\n\r\n".utf8))

        // Size must be lowercase hex.
        let largeChunk = Data(repeating: 0x41, count: 255)  // 255 = "ff"
        let largeEncoded = ChunkedHTTPEncoder.formatChunk(largeChunk)
        let largeString = String(data: largeEncoded.prefix(5), encoding: .utf8) ?? ""
        #expect(largeString == "ff\r\nA")  // lowercase hex prefix + chunk start
    
        }
    }

    @Test func chunkedTerminatorIsCorrect() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        #expect(ChunkedHTTPEncoder.terminator == Data("0\r\n\r\n".utf8))
    
        }
    }

    @Test func chunkedTransferPreservesHTTPResponseEnumForm() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // Ensures the producing side of the API (HTTPResponse.Body.stream) still
        // works end to end: caller can build a streaming response, the enum
        // correctly routes to .stream, and bodyData is nil.
        let streamResponse = HTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: ["Content-Type": "text/event-stream"],
            stream: { writer in
                try await writer.write(Data("hello".utf8))
                try await writer.finish()
            }
        )
        #expect(streamResponse.bodyData == nil)
        if case .stream = streamResponse.body {
            // expected
        } else {
            Issue.record("HTTPResponse.body must be .stream form")
        }
    
        }
    }

    @Test func closeOpenBlockIsIdempotentAndCalledByFinish() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        // Simulates a stream that ends WITHOUT response.output_item.done for the
        // final text block. finish() must emit content_block_stop via closeOpenBlock()
        // so the wire is still well-formed.

        let incompleteStream = AsyncThrowingStream<JSONObject, Error> { continuation in
            Task {
                continuation.yield(JSONObject.from(["type": .string("response.created")]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "output_index": .number(0),
                    "item": .object(JSONObject.from(["type": .string("message"), "id": .string("msg_1")])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.added"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                    "part": .object(JSONObject.from(["type": .string("output_text"), "text": .string("")]))
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.delta"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                    "delta": .string("Hello"),
                ]))
                // Intentionally MISSING: response.output_item.done + response.completed.
                continuation.finish()
            }
        }

        let mock = MockResponsesClient(streams: [incompleteStream])
        let bridge = AnthropicBridge(
            configuration: Self.testConfig,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
        )

        let request = Self.makeHTTPRequest(body: AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hi")])])],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))

        let response = await bridge.handleMessages(request)
        let writer = InMemoryBodyWriter()
        if case .stream(let producer) = response.body {
            try await producer(writer)
        }

        let frames = await Self.parseSSEFrames(from: writer)
        // content_block_stop frame: type="content_block_stop" at top level.
        let stopFrames = frames.filter { $0.data.string("type") == "content_block_stop" }
        #expect(stopFrames.count >= 1)

        // message_stop frame: type="message_stop" at top level.
        let messageStopFrames = frames.filter { $0.data.string("type") == "message_stop" }
        #expect(messageStopFrames.count >= 1)
    
        }
    }
}
