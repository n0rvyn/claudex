import Foundation
@testable import CCRouterCore
import Testing

// MARK: - ModelRoutingBridgeIntegrationTests

/// Integration tests asserting that routing decisions are reflected in the actual
/// `/responses` payloads sent by AnthropicBridge (wire-level assertions on
/// `MockResponsesClient.capturedRequests`).
struct ModelRoutingBridgeIntegrationTests {

    // MARK: - Shared test helpers

    static let testCredentials = SubscriptionCredentials(
        accessToken: "test-access-token",
        accountID: "test-account-id"
    )

    /// Returns a fresh RouterConfiguration with a custom routing table.
    static func makeConfig(
        routingTable: ModelRoutingTable,
        advisorRoute: ModelRoute
    ) -> RouterConfiguration {
        RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            routingTable: routingTable,
            advisorRoute: advisorRoute,
            gatewayAuthToken: "t",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/tmp/auth.json",
            subscriptionAuthBookmarkData: nil,
            configurationPath: "/tmp/config.json",
            configurationWarning: nil
        )
    }

    /// Drives a streaming response body with an InMemoryBodyWriter and returns
    /// both the writer and the concatenated SSE frames for assertions.
    static func driveStream(
        _ response: HTTPResponse
    ) async throws -> (writer: InMemoryBodyWriter, frames: [(event: String, data: JSONObject)]) {
        let writer = InMemoryBodyWriter()
        guard case .stream(let producer) = response.body else {
            Issue.record("expected streaming response body, got non-streaming")
            return (InMemoryBodyWriter(), [])
        }
        try await producer(writer)
        let frames = await writer.parseSSEFrames()
        return (writer, frames)
    }

    // MARK: - Tests

    /// Asserts that a request with model "claude-opus-4-7" hits the "opus" rule
    /// and that the upstream payload carries the correct upstream model, effort,
    /// and verbosity.
    @Test
    func opusRequestHitsOpusRule() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let config = ModelRoutingBridgeIntegrationTests.makeConfig(
            routingTable: ModelRoutingTable(
                rules: [
                    ModelRoutingRule(
                        match: "opus",
                        route: ModelRoute(
                            upstreamModel: "opus-upstream",
                            reasoningEffort: "xhigh",
                            textVerbosity: "low"
                        )
                    ),
                    ModelRoutingRule(
                        match: "haiku",
                        route: ModelRoute(
                            upstreamModel: "haiku-upstream",
                            reasoningEffort: "medium",
                            textVerbosity: "low"
                        )
                    ),
                ],
                fallback: ModelRoute(
                    upstreamModel: "fallback-upstream",
                    reasoningEffort: "xhigh",
                    textVerbosity: "low"
                )
            ),
            advisorRoute: ModelRoute(
                upstreamModel: "advisor-upstream",
                reasoningEffort: "xhigh",
                textVerbosity: "low"
            )
        )

        let mock = MockResponsesClient(
            streams: [MockResponsesEventStream.textOnlyTurn(text: "Hello from opus")],
            performResults: []
        )
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: ModelRoutingBridgeIntegrationTests.testCredentials)
        )

        let requestFixture = try AnthropicMessagesRequest.textOnlyFixture(model: "claude-opus-4-7")
        let body = try JSONEncoder().encode(requestFixture)
        let response = await bridge.handleMessages(
            HTTPRequest(
                method: "POST",
                path: "/v1/messages",
                headers: ["x-claude-code-session-id": "S-opus"],
                body: body
            )
        )

        _ = try await ModelRoutingBridgeIntegrationTests.driveStream(response)

        // The bridge must have sent exactly one upstream request.
        let captured = await mock.capturedRequests
        let captureCount = captured.count
        try #require(captureCount >= 1)
        let payload = captured[0]

        // Wire-level assertions: upstream model, reasoning effort, text verbosity.
        #expect(payload.string("model") == "opus-upstream")
        #expect(payload.object("reasoning")?.string("effort") == "xhigh")
        #expect(payload.object("text")?.string("verbosity") == "low")
    
        }
    }


    /// Asserts that a request with model "claude-haiku-4-5-20251001" hits the
    /// "haiku" rule and carries the haiku-specific effort ("medium").
    

    /// Asserts that a request with model "claude-haiku-4-5-20251001" hits the
    /// "haiku" rule and carries the haiku-specific effort ("medium").
    @Test
    func haikuRequestHitsHaikuRuleWithDifferentEffort() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let config = ModelRoutingBridgeIntegrationTests.makeConfig(
            routingTable: ModelRoutingTable(
                rules: [
                    ModelRoutingRule(
                        match: "opus",
                        route: ModelRoute(
                            upstreamModel: "opus-upstream",
                            reasoningEffort: "xhigh",
                            textVerbosity: "low"
                        )
                    ),
                    ModelRoutingRule(
                        match: "haiku",
                        route: ModelRoute(
                            upstreamModel: "haiku-upstream",
                            reasoningEffort: "medium",
                            textVerbosity: "low"
                        )
                    ),
                ],
                fallback: ModelRoute(
                    upstreamModel: "fallback-upstream",
                    reasoningEffort: "xhigh",
                    textVerbosity: "low"
                )
            ),
            advisorRoute: ModelRoute(
                upstreamModel: "advisor-upstream",
                reasoningEffort: "xhigh",
                textVerbosity: "low"
            )
        )

        let mock = MockResponsesClient(
            streams: [MockResponsesEventStream.textOnlyTurn(text: "Hello from haiku")],
            performResults: []
        )
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: ModelRoutingBridgeIntegrationTests.testCredentials)
        )

        let requestFixture = try AnthropicMessagesRequest.textOnlyFixture(
            model: "claude-haiku-4-5-20251001"
        )
        let body = try JSONEncoder().encode(requestFixture)
        let response = await bridge.handleMessages(
            HTTPRequest(
                method: "POST",
                path: "/v1/messages",
                headers: ["x-claude-code-session-id": "S-haiku"],
                body: body
            )
        )

        _ = try await ModelRoutingBridgeIntegrationTests.driveStream(response)

        let captured = await mock.capturedRequests
        let captureCount = captured.count
        try #require(captureCount >= 1)
        let payload = captured[0]

        #expect(payload.string("model") == "haiku-upstream")
        #expect(payload.object("reasoning")?.string("effort") == "medium")
        #expect(payload.object("text")?.string("verbosity") == "low")
    
        }
    }


    /// Asserts that an unrecognized model falls through to the fallback route.
    

    /// Asserts that an unrecognized model falls through to the fallback route.
    @Test
    func unmatchedModelFallsBack() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let config = ModelRoutingBridgeIntegrationTests.makeConfig(
            routingTable: ModelRoutingTable(
                rules: [
                    ModelRoutingRule(
                        match: "opus",
                        route: ModelRoute(
                            upstreamModel: "opus-upstream",
                            reasoningEffort: "xhigh",
                            textVerbosity: "low"
                        )
                    ),
                ],
                fallback: ModelRoute(
                    upstreamModel: "fallback-upstream",
                    reasoningEffort: "xhigh",
                    textVerbosity: "low"
                )
            ),
            advisorRoute: ModelRoute(
                upstreamModel: "advisor-upstream",
                reasoningEffort: "xhigh",
                textVerbosity: "low"
            )
        )

        let mock = MockResponsesClient(
            streams: [MockResponsesEventStream.textOnlyTurn(text: "Hello fallback")],
            performResults: []
        )
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: ModelRoutingBridgeIntegrationTests.testCredentials)
        )

        let requestFixture = try AnthropicMessagesRequest.textOnlyFixture(
            model: "claude-unknown-model"
        )
        let body = try JSONEncoder().encode(requestFixture)
        let response = await bridge.handleMessages(
            HTTPRequest(
                method: "POST",
                path: "/v1/messages",
                headers: ["x-claude-code-session-id": "S-fallback"],
                body: body
            )
        )

        _ = try await ModelRoutingBridgeIntegrationTests.driveStream(response)

        let captured = await mock.capturedRequests
        let captureCount = captured.count
        try #require(captureCount >= 1)
        let payload = captured[0]

        #expect(payload.string("model") == "fallback-upstream")
    
        }
    }


    /// Asserts that the advisor sub-call uses advisorRoute (not executor route).
    /// Round 1: upstream emits function_call(name="advisor").
    /// The bridge calls perform() for the advisor sub-call — we assert that
    /// the second captured request carries the advisor upstream model.
    

    /// Asserts that the advisor sub-call uses advisorRoute (not executor route).
    /// Round 1: upstream emits function_call(name="advisor").
    /// The bridge calls perform() for the advisor sub-call — we assert that
    /// the second captured request carries the advisor upstream model.
    @Test
    func advisorSubcallUsesAdvisorRoute() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let advisorCallID = "toolu_advisor_1"
        let config = ModelRoutingBridgeIntegrationTests.makeConfig(
            routingTable: ModelRoutingTable(
                rules: [],
                fallback: ModelRoute(
                    upstreamModel: "executor-upstream",
                    reasoningEffort: "xhigh",
                    textVerbosity: "low"
                )
            ),
            advisorRoute: ModelRoute(
                upstreamModel: "advisor-upstream",
                reasoningEffort: "xhigh",
                textVerbosity: "low"
            )
        )

        let mock = MockResponsesClient(
            streams: [
                // First pass: advisor function_call
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "advisor",
                    callID: advisorCallID,
                    argumentsJSON: "{}"
                ),
                // Second pass: final text reply
                MockResponsesEventStream.textOnlyTurn(text: "Final reply"),
            ],
            performResults: [
                // Advisor sub-call answer
                [
                    JSONObject.from([
                        "type": .string("response.output_item.done"),
                        "item": .object(JSONObject.from([
                            "type": .string("message"),
                            "content": .array([
                                .object(JSONObject.from([
                                    "type": .string("output_text"),
                                    "text": .string("Consider the context carefully."),
                                ])),
                            ]),
                        ])),
                    ]),
                    JSONObject.from([
                        "type": .string("response.completed"),
                        "response": .object(JSONObject.from([
                            "usage": .object(JSONObject.from([
                                "output_tokens": .number(10),
                            ])),
                        ])),
                    ]),
                ],
            ]
        )
        let advisorTool = JSONObject.from(["type": .string("advisor_20260301")])
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: ModelRoutingBridgeIntegrationTests.testCredentials)
        )
        let request = AnthropicMessagesRequest(
            model: "claude-opus-4-7",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(
                    role: "user",
                    content: [
                        JSONObject.from([
                            "type": .string("text"),
                            "text": .string("Advise me"),
                        ])
                    ]
                ),
            ],
            system: nil,
            tools: [advisorTool],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
        let body = try JSONEncoder().encode(request)
        let response = await bridge.handleMessages(
            HTTPRequest(
                method: "POST",
                path: "/v1/messages",
                headers: ["x-claude-code-session-id": "S-advisor"],
                body: body
            )
        )

        _ = try await ModelRoutingBridgeIntegrationTests.driveStream(response)

        // Captured: [executor_initial, advisor_perform, executor_second_pass]
        let captured = await mock.capturedRequests
        let advisorCaptureCount = captured.count
        try #require(advisorCaptureCount >= 2)
        // The second capture is the advisor perform() sub-call.
        let advisorPayload = captured[1]

        #expect(advisorPayload.string("model") == "advisor-upstream")
        #expect(advisorPayload.object("reasoning")?.string("effort") == "xhigh")
    
        }
    }


    /// Asserts that a tool-use turn followed by a continuation preserves the same
    /// resolved route across both segments (pending.resolvedRoute is not re-resolved
    /// in the continuation branch).
    

    /// Asserts that a tool-use turn followed by a continuation preserves the same
    /// resolved route across both segments (pending.resolvedRoute is not re-resolved
    /// in the continuation branch).
    @Test
    func pendingToolTurnSecondSegmentKeepsSameRoute() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let config = ModelRoutingBridgeIntegrationTests.makeConfig(
            routingTable: ModelRoutingTable(
                rules: [
                    ModelRoutingRule(
                        match: "sonnet",
                        route: ModelRoute(
                            upstreamModel: "sonnet-upstream",
                            reasoningEffort: "high",
                            textVerbosity: "low"
                        )
                    ),
                ],
                fallback: ModelRoute(
                    upstreamModel: "fallback-upstream",
                    reasoningEffort: "xhigh",
                    textVerbosity: "low"
                )
            ),
            advisorRoute: ModelRoute(
                upstreamModel: "advisor-upstream",
                reasoningEffort: "xhigh",
                textVerbosity: "low"
            )
        )

        let mock = MockResponsesClient(
            streams: [
                // Round 1: tool_use
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "Bash",
                    callID: "toolu_bash_1",
                    argumentsJSON: "{\"command\":\"true\"}"
                ),
                // Round 2: text reply
                MockResponsesEventStream.textOnlyTurn(text: "Done."),
            ],
            performResults: []
        )
        let bridge = AnthropicBridge(
            configuration: config,
            responsesClient: mock,
            sessionLoader: MockSessionLoader(credentials: ModelRoutingBridgeIntegrationTests.testCredentials)
        )

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
        let request = AnthropicMessagesRequest(
            model: "claude-sonnet-4-6",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(
                    role: "user",
                    content: [
                        JSONObject.from([
                            "type": .string("text"),
                            "text": .string("Run it"),
                        ])
                    ]
                ),
            ],
            system: nil,
            tools: [bashTool],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
        let body = try JSONEncoder().encode(request)
        let sessionID = "S-tool-continuation"
        let sessionHeader = ["x-claude-code-session-id": sessionID]

        // --- Round 1 ---
        let firstResponse = await bridge.handleMessages(
            HTTPRequest(method: "POST", path: "/v1/messages", headers: sessionHeader, body: body)
        )
        _ = try await ModelRoutingBridgeIntegrationTests.driveStream(firstResponse)

        // --- Round 2 (continuation) ---
        let toolResultContent = JSONObject.from([
            "type": .string("tool_result"),
            "tool_use_id": .string("toolu_bash_1"),
            "content": .string("success"),
        ])
        let continuationRequest = AnthropicMessagesRequest(
            model: "claude-sonnet-4-6",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(
                    role: "assistant",
                    content: [
                        JSONObject.from([
                            "type": .string("tool_use"),
                            "id": .string("toolu_bash_1"),
                            "name": .string("Bash"),
                            "input": .object(JSONObject.from(["command": .string("true")])),
                        ]),
                    ]
                ),
                AnthropicMessage(
                    role: "user",
                    content: [toolResultContent]
                ),
            ],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
        let continuationBody = try JSONEncoder().encode(continuationRequest)
        let secondResponse = await bridge.handleMessages(
            HTTPRequest(method: "POST", path: "/v1/messages", headers: sessionHeader, body: continuationBody)
        )
        _ = try await ModelRoutingBridgeIntegrationTests.driveStream(secondResponse)

        let captured = await mock.capturedRequests
        let captureCount4 = captured.count
        try #require(captureCount4 >= 2)
        let firstPayload = captured[0]
        let secondPayload = captured[1]

        // Both segments must use the sonnet rule's upstream model (not re-resolved).
        #expect(firstPayload.string("model") == "sonnet-upstream")
        #expect(secondPayload.string("model") == "sonnet-upstream")
        // Effort and verbosity also preserved.
        #expect(firstPayload.object("reasoning")?.string("effort") == "high")
        #expect(secondPayload.object("reasoning")?.string("effort") == "high")
        let secondTools = secondPayload.array("tools")?.compactMap(\.objectValue) ?? []
        #expect(secondTools.count == 1)
        #expect(secondTools.first?.string("name") == "Bash")
        #expect(secondTools.first?.string("description") == "Run a bash command")
        #expect(
            secondTools.first?.object("parameters")?.object("properties")?.object("command")?.string("type") == "string"
        )
    
        }
    }
}
