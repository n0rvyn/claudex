import Foundation
@testable import CCRouterCore
import Testing

struct AnthropicBridgeRoutingHotReloadTests {
    private static let credentials = SubscriptionCredentials(
        accessToken: "test-access-token",
        accountID: "test-account-id"
    )

    private static func config() -> RouterConfiguration {
        RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            routingTable: ModelRoutingTable(
                rules: [
                    ModelRoutingRule(
                        match: "opus",
                        route: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
                    ),
                ],
                fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
            ),
            advisorRoute: ModelRoute(upstreamModel: "advisor-old", reasoningEffort: "xhigh", textVerbosity: "low"),
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/tmp/auth.json",
            configurationPath: "/tmp/config.json",
            configurationWarning: nil
        )
    }

    @Test
    func hotReloadChangesNextExecutorRoute() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let mock = MockResponsesClient(
                streams: [
                    MockResponsesEventStream.textOnlyTurn(text: "old"),
                    MockResponsesEventStream.textOnlyTurn(text: "new"),
                ]
            )
            let bridge = AnthropicBridge(
                configuration: Self.config(),
                responsesClient: mock,
                sessionLoader: MockSessionLoader(credentials: Self.credentials)
            )

            _ = try await Self.sendTextRequest(bridge: bridge, model: "claude-opus-4-7", sessionID: "old-route")

            await bridge.updateRouting(
                table: ModelRoutingTable(
                    rules: [
                        ModelRoutingRule(
                            match: "opus",
                            route: ModelRoute(upstreamModel: "gpt-5.4-mini", reasoningEffort: "medium", textVerbosity: "low")
                        ),
                    ],
                    fallback: ModelRoute(upstreamModel: "fallback-new", reasoningEffort: "low", textVerbosity: "medium")
                ),
                advisorRoute: ModelRoute(upstreamModel: "advisor-old", reasoningEffort: "xhigh", textVerbosity: "low")
            )

            _ = try await Self.sendTextRequest(bridge: bridge, model: "claude-opus-4-7", sessionID: "new-route")

            let captured = await mock.capturedRequests
            #expect(captured[0].string("model") == "gpt-5.4")
            #expect(captured[1].string("model") == "gpt-5.4-mini")
            #expect(captured[1].object("reasoning")?.string("effort") == "medium")
        }
    }

    @Test
    func hotReloadChangesAdvisorRouteOnlyForAdvisorSubcall() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let advisorCallID = "toolu_advisor_hot_reload"
            let mock = MockResponsesClient(
                streams: [
                    MockResponsesEventStream.toolUseTurn(
                        textBefore: "checking",
                        toolName: "advisor",
                        callID: advisorCallID,
                        argumentsJSON: "{}"
                    ),
                    MockResponsesEventStream.textOnlyTurn(text: "done"),
                ],
                performResults: [Self.advisorPerformResult()]
            )
            let bridge = AnthropicBridge(
                configuration: Self.config(),
                responsesClient: mock,
                sessionLoader: MockSessionLoader(credentials: Self.credentials)
            )

            await bridge.updateRouting(
                table: Self.config().routingTable,
                advisorRoute: ModelRoute(upstreamModel: "advisor-new", reasoningEffort: "high", textVerbosity: "medium")
            )

            let request = try Self.advisorRequest(sessionID: "advisor-route")
            let response = await bridge.handleMessages(request)
            _ = try await ModelRoutingBridgeIntegrationTests.driveStream(response)

            let captured = await mock.capturedRequests
            try #require(captured.count >= 2)
            #expect(captured[0].string("model") == "gpt-5.4")
            #expect(captured[1].string("model") == "advisor-new")
            #expect(captured[1].object("reasoning")?.string("effort") == "high")
        }
    }

    @Test
    func concurrentUpdateAndRequestDoNotCrashOrPartiallyRoute() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let mock = MockResponsesClient(
                streams: [MockResponsesEventStream.textOnlyTurn(text: "ok")]
            )
            let bridge = AnthropicBridge(
                configuration: Self.config(),
                responsesClient: mock,
                sessionLoader: MockSessionLoader(credentials: Self.credentials)
            )
            let newTable = ModelRoutingTable(
                rules: [
                    ModelRoutingRule(
                        match: "opus",
                        route: ModelRoute(upstreamModel: "gpt-5.4-mini", reasoningEffort: "medium", textVerbosity: "high")
                    ),
                ],
                fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")
            )

            async let update: Void = bridge.updateRouting(
                table: newTable,
                advisorRoute: ModelRoute(upstreamModel: "advisor-new", reasoningEffort: "high", textVerbosity: "medium")
            )
            async let request: Void = Self.sendTextRequest(bridge: bridge, model: "claude-opus-4-7", sessionID: "race")
            _ = try await (update, request)

            let captured = await mock.capturedRequests
            try #require(captured.count == 1)
            let model = captured[0].string("model")
            #expect(model == "gpt-5.4" || model == "gpt-5.4-mini")
        }
    }

    private static func sendTextRequest(
        bridge: AnthropicBridge,
        model: String,
        sessionID: String
    ) async throws {
        let body = try JSONEncoder().encode(AnthropicMessagesRequest.textOnlyFixture(model: model))
        let response = await bridge.handleMessages(
            HTTPRequest(
                method: "POST",
                path: "/v1/messages",
                headers: ["x-claude-code-session-id": sessionID],
                body: body
            )
        )
        _ = try await ModelRoutingBridgeIntegrationTests.driveStream(response)
    }

    private static func advisorRequest(sessionID: String) throws -> HTTPRequest {
        let request = AnthropicMessagesRequest(
            model: "claude-opus-4-7",
            max_tokens: 128,
            messages: [
                AnthropicMessage(
                    role: "user",
                    content: [JSONObject.from(["type": .string("text"), "text": .string("Please review")])]
                ),
            ],
            system: nil,
            tools: [JSONObject.from(["type": .string("advisor_20260301")])],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        )
        let body = try JSONEncoder().encode(request)
        return HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["x-claude-code-session-id": sessionID],
            body: body
        )
    }

    private static func advisorPerformResult() -> [JSONObject] {
        [
            JSONObject.from([
                "type": .string("response.output_item.done"),
                "item": .object(JSONObject.from([
                    "type": .string("message"),
                    "content": .array([
                        .object(JSONObject.from([
                            "type": .string("output_text"),
                            "text": .string("advisor guidance"),
                        ])),
                    ]),
                ])),
            ]),
        ]
    }
}
