import Foundation
@testable import CCRouterCore
import Testing

/// DP-003-P4: advisor sub-call carries the current task's instructions and
/// the last N conversation messages, not a fixed "current task..." prompt.
///
/// Pattern mirrors BridgeRegressionTests.advisorBridgeStillSynthesizesServerToolUseAndAdvisorToolResult:
/// MockResponsesClient.capturedRequests is populated in call order; [0] is the main
/// streamEvents payload, [1] is the advisor `perform` sub-call payload.
struct AdvisorContextForwardingTests {

    // MARK: - Shared config + request builder

    private static func config(advisorContextMessageLimit: Int) -> RouterConfiguration {
        RouterConfiguration(
            host: "127.0.0.1", port: 4317,
            healthPath: "/health", messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://chatgpt.com/backend-api/codex/responses",
            routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
            advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
            pendingToolTurnTTLSeconds: 1800,
            advisorContextMessageLimit: advisorContextMessageLimit,
            gatewayAuthToken: "tok", gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )
    }

    /// Build an HTTPRequest body directly as JSON (AnthropicMessagesRequest's memberwise
    /// init has 11 parameters — raw JSON is simpler and matches AnthropicProtocol.swift:47
    /// `textOnlyFixture` pattern).
    private static func messagesRequest(messageCount: Int, systemText: String) throws -> HTTPRequest {
        var messageObjects: [String] = []
        for i in 0..<messageCount {
            let role = (i % 2 == 0) ? "user" : "assistant"
            messageObjects.append("""
            {"role":"\(role)","content":[{"type":"text","text":"msg-\(i)"}]}
            """)
        }
        let json = """
        {
          "model": "claude-sonnet-4-6",
          "max_tokens": 512,
          "stream": true,
          "system": [{"type":"text","text":\(Self.jsonEscape(systemText))}],
          "tools": [{"type":"advisor_20260301"}],
          "messages": [\(messageObjects.joined(separator: ","))]
        }
        """
        return HTTPRequest(
            method: "POST", path: "/v1/messages",
            headers: ["x-claude-code-session-id": "test-session"],
            body: Data(json.utf8)
        )
    }

    private static func jsonEscape(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    /// The advisor `perform` sub-call needs a response with a message containing text,
    /// so `joinedMessageText(from:)` returns a non-empty guidance string.
    private static func advisorPerformResult() -> [JSONObject] {
        let messageItem = JSONObject.from([
            "type": .string("message"),
            "role": .string("assistant"),
            "content": .array([.object(JSONObject.from([
                "type": .string("output_text"),
                "text": .string("advisor guidance"),
            ]))]),
        ])
        return [
            JSONObject.from([
                "type": .string("response.output_item.done"),
                "item": .object(messageItem),
            ]),
            JSONObject.from([
                "type": .string("response.completed"),
                "response": .object(JSONObject.from([
                    "usage": .object(JSONObject.from([
                        "input_tokens": .number(5),
                        "output_tokens": .number(3),
                    ])),
                ])),
            ]),
        ]
    }

    // MARK: - Tests

    @Test
    func advisorPayloadIncludesInstructionsAndLastNMessages() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let advisorCallID = "toolu_advisor_ctx_1"
        // Pattern from BridgeRegressionTests.advisorBridge... (line 256-264):
        // first stream = toolUseTurn with toolName="advisor" (main turn calls advisor function),
        // second stream = textOnlyTurn (second-pass reply after advisor result injected).
        let mockClient = MockResponsesClient(
            streams: [
                MockResponsesEventStream.toolUseTurn(
                    textBefore: "Let me consult advisor.",
                    toolName: "advisor",
                    callID: advisorCallID,
                    argumentsJSON: "{}"
                ),
                MockResponsesEventStream.textOnlyTurn(text: "Final reply"),
            ],
            performResults: [Self.advisorPerformResult()]
        )
        let bridge = AnthropicBridge(
            configuration: Self.config(advisorContextMessageLimit: 8),
            responsesClient: mockClient,
            sessionLoader: MockSessionLoader()
        )
        let req = try Self.messagesRequest(messageCount: 10, systemText: "Original system prompt body.")

        let response = await bridge.handleMessages(req)

        // The response is .stream with a deferred body producer — must be consumed
        // to drive streamEvents calls. Use InMemoryBodyWriter to trigger it.
        guard case .stream(let producer) = response.body else {
            Issue.record("Expected .stream body")
            return
        }
        let writer = InMemoryBodyWriter()
        try await producer(writer)

        let captured = await mockClient.capturedRequests
        // [0] main stream, [1] advisor perform, [2] second-pass stream
        #expect(captured.count >= 2)
        let advisorPayload = captured[1]

        // Input is the truncated last-N conversation messages.
        let inputMessages = advisorPayload.array("input") ?? []
        #expect(inputMessages.count == 8)

        // Instructions carry the original system prompt verbatim.
        let advisorInstr = advisorPayload.string("instructions") ?? ""
        #expect(advisorInstr.contains("Original system prompt body."))
        #expect(advisorInstr.contains("planning advisor"))
    
        }
    }

    @Test
    func advisorMessageLimitHonoursConfig() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let advisorCallID = "toolu_advisor_ctx_2"
        let mockClient = MockResponsesClient(
            streams: [
                MockResponsesEventStream.toolUseTurn(
                    textBefore: "Consulting.",
                    toolName: "advisor",
                    callID: advisorCallID,
                    argumentsJSON: "{}"
                ),
                MockResponsesEventStream.textOnlyTurn(text: "Final"),
            ],
            performResults: [Self.advisorPerformResult()]
        )
        let bridge = AnthropicBridge(
            configuration: Self.config(advisorContextMessageLimit: 4),
            responsesClient: mockClient,
            sessionLoader: MockSessionLoader()
        )
        let req = try Self.messagesRequest(messageCount: 10, systemText: "sys")

        let response = await bridge.handleMessages(req)

        guard case .stream(let producer) = response.body else {
            Issue.record("Expected .stream body")
            return
        }
        let writer = InMemoryBodyWriter()
        try await producer(writer)

        let captured = await mockClient.capturedRequests
        let inputMessages = captured[1].array("input") ?? []
        #expect(inputMessages.count == 4)
    
        }
    }

    @Test
    func advisorReplacesFixedGuidancePrompt() async throws {
        try await TraceIsolation.withTaskLocalIsolation {

        let advisorCallID = "toolu_advisor_ctx_3"
        let mockClient = MockResponsesClient(
            streams: [
                MockResponsesEventStream.toolUseTurn(
                    textBefore: nil,
                    toolName: "advisor",
                    callID: advisorCallID,
                    argumentsJSON: "{}"
                ),
                MockResponsesEventStream.textOnlyTurn(text: "ok"),
            ],
            performResults: [Self.advisorPerformResult()]
        )
        let bridge = AnthropicBridge(
            configuration: Self.config(advisorContextMessageLimit: 8),
            responsesClient: mockClient,
            sessionLoader: MockSessionLoader()
        )
        let req = try Self.messagesRequest(messageCount: 2, systemText: "sys")

        let response = await bridge.handleMessages(req)

        guard case .stream(let producer) = response.body else {
            Issue.record("Expected .stream body")
            return
        }
        let writer = InMemoryBodyWriter()
        try await producer(writer)

        let captured = await mockClient.capturedRequests
        let advisorPayload = captured[1]

        // The old fixed string MUST NOT appear as advisor input — it was replaced by real history.
        let inputAsString = advisorPayload.array("input")?
            .compactMap { $0.objectValue }
            .flatMap { ($0.array("content") ?? []).compactMap { $0.objectValue?.string("text") } }
            .joined(separator: " ") ?? ""
        #expect(!inputAsString.contains("Provide concise strategic guidance for the current task"))
    
        }
    }
}
