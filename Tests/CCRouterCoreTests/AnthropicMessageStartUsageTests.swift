import Foundation
@testable import CCRouterCore
import Testing

struct AnthropicMessageStartUsageTests {
    @Test
    func initialTurnEmitsPreflightInputTokenCount() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let counter = RecordingInputTokenCounter(values: [41])
        let bridge = AnthropicBridge(
            configuration: makeConfiguration(),
            responsesClient: MockResponsesClient(streams: [MockResponsesEventStream.textOnlyTurn(text: "Done")]),
            sessionLoader: MockSessionLoader(),
            inputTokenCounter: counter
        )

        let response = await bridge.handleMessages(makeTextRequest())
        let (_, frames) = try await ModelRoutingBridgeIntegrationTests.driveStream(response)

        #expect(messageStartInputTokens(in: frames) == 41)
        #expect(await counter.capturedPayloads().count == 1)
        }
    }

    @Test
    func continuationTurnEmitsPreflightInputTokenCount() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let counter = RecordingInputTokenCounter(values: [17, 29])
        let bridge = AnthropicBridge(
            configuration: makeConfiguration(),
            responsesClient: MockResponsesClient(streams: [
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "Bash",
                    callID: "toolu_bash_1",
                    argumentsJSON: "{\"command\":\"true\"}"
                ),
                MockResponsesEventStream.textOnlyTurn(text: "Done"),
            ]),
            sessionLoader: MockSessionLoader(),
            inputTokenCounter: counter
        )

        let firstResponse = await bridge.handleMessages(makeToolRequest())
        let (_, firstFrames) = try await ModelRoutingBridgeIntegrationTests.driveStream(firstResponse)
        #expect(messageStartInputTokens(in: firstFrames) == 17)

        let continuationResponse = await bridge.handleMessages(makeToolContinuationRequest())
        let (_, continuationFrames) = try await ModelRoutingBridgeIntegrationTests.driveStream(continuationResponse)
        #expect(messageStartInputTokens(in: continuationFrames) == 29)
        }
    }

    @Test
    func advisorSecondPassDoesNotRewriteMessageStartUsage() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let counter = RecordingInputTokenCounter(values: [73])
        let mock = MockResponsesClient(
            streams: [
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "advisor",
                    callID: "toolu_advisor_1",
                    argumentsJSON: "{}"
                ),
                MockResponsesEventStream.textOnlyTurn(text: "Final answer"),
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
                                    "text": .string("Use the fallback plan"),
                                ])),
                            ]),
                        ])),
                    ]),
                ],
            ]
        )
        let bridge = AnthropicBridge(
            configuration: makeConfiguration(),
            responsesClient: mock,
            sessionLoader: MockSessionLoader(),
            inputTokenCounter: counter
        )

        let response = await bridge.handleMessages(makeAdvisorRequest())
        let (_, frames) = try await ModelRoutingBridgeIntegrationTests.driveStream(response)

        #expect(frames.filter { $0.data.string("type") == "message_start" }.count == 1)
        #expect(messageStartInputTokens(in: frames) == 73)
        }
    }

    private func makeConfiguration() -> RouterConfiguration {
        RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            routingTable: ModelRoutingTable(
                rules: [],
                fallback: ModelRoute(upstreamModel: "executor-upstream", reasoningEffort: "high", textVerbosity: "low")
            ),
            advisorRoute: ModelRoute(upstreamModel: "advisor-upstream", reasoningEffort: "xhigh", textVerbosity: "low"),
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )
    }

    private func makeTextRequest() -> HTTPRequest {
        let body = try! JSONEncoder().encode(AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("hello")])])],
            system: [JSONObject.from(["type": .string("text"), "text": .string("system prompt")])],
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))
        return HTTPRequest(method: "POST", path: "/v1/messages", headers: ["x-claude-code-session-id": "S-message-start"], body: body)
    }

    private func makeToolRequest() -> HTTPRequest {
        let tool = JSONObject.from([
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
        let body = try! JSONEncoder().encode(AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("run")])])],
            system: nil,
            tools: [tool],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))
        return HTTPRequest(method: "POST", path: "/v1/messages", headers: ["x-claude-code-session-id": "S-continuation"], body: body)
    }

    private func makeToolContinuationRequest() -> HTTPRequest {
        let body = try! JSONEncoder().encode(AnthropicMessagesRequest(
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
        ))
        return HTTPRequest(method: "POST", path: "/v1/messages", headers: ["x-claude-code-session-id": "S-continuation"], body: body)
    }

    private func makeAdvisorRequest() -> HTTPRequest {
        let body = try! JSONEncoder().encode(AnthropicMessagesRequest(
            model: "claude-4-sonnet",
            max_tokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string("advise me")])])],
            system: nil,
            tools: [JSONObject.from(["type": .string("advisor_20260301")])],
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: true
        ))
        return HTTPRequest(method: "POST", path: "/v1/messages", headers: ["x-claude-code-session-id": "S-advisor-message-start"], body: body)
    }

    private func messageStartInputTokens(in frames: [(event: String, data: JSONObject)]) -> Int? {
        frames.first { $0.data.string("type") == "message_start" }?
            .data
            .object("message")?
            .object("usage")?["input_tokens"]?
            .intValue
    }
}

private actor RecordingInputTokenCounter: AnthropicInputTokenCounting {
    private let values: [Int]
    private var nextIndex = 0
    private var payloads: [JSONObject] = []

    init(values: [Int]) {
        self.values = values
    }

    func countInputTokens(for responsesPayload: JSONObject) async throws -> Int {
        payloads.append(responsesPayload)
        let value = values[min(nextIndex, values.count - 1)]
        nextIndex += 1
        return value
    }

    func capturedPayloads() -> [JSONObject] {
        payloads
    }
}
