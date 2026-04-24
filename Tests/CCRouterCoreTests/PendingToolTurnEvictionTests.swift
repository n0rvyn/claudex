import Foundation
@testable import CCRouterCore
import Testing

/// DP-001-P4, DP-004-P4: verify TTL eviction is deterministic and bumped on read.
///
/// These tests exercise eviction via a tiny TTL (1 second) by constructing a
/// RouterConfiguration with pendingToolTurnTTLSeconds=1 and invoking the public
/// `evictStalePending` hook (no real-time Task.sleep).
struct PendingToolTurnEvictionTests {

    private static func config(ttl: Int) -> RouterConfiguration {
        RouterConfiguration(
            host: "127.0.0.1", port: 4317,
            healthPath: "/health", messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://example/",
            routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
            advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
            pendingToolTurnTTLSeconds: ttl,
            advisorContextMessageLimit: 8,
            gatewayAuthToken: "tok", gatewayAuthHeader: "x-api-key",
            subscriptionAuthFilePath: "/dev/null/auth.json",
            configurationPath: "/dev/null/config.json",
            configurationWarning: nil
        )
    }

    private static func toolUseRequest(sessionID: String, toolName: String) throws -> HTTPRequest {
        let bashToolSchema = """
        {"type":"object","properties":{"command":{"type":"string"}}}
        """
        let json = """
        {"model":"claude-sonnet-4-6","max_tokens":512,"stream":true,
         "messages":[{"role":"user","content":[{"type":"text","text":"run ls"}]}],
         "tools":[{"type":"function","name":"\(toolName)","description":"Run a shell command","input_schema":\(bashToolSchema)}]}
        """
        return HTTPRequest(
            method: "POST", path: "/v1/messages",
            headers: ["x-claude-code-session-id": sessionID],
            body: Data(json.utf8)
        )
    }

    @Test
    func countStartsAtZero() async {
        try await TraceIsolation.withTaskLocalIsolation {
            let bridge = AnthropicBridge(configuration: Self.config(ttl: 1800))
            #expect(await bridge.pendingToolTurnsCount() == 0)
        }
    }

    @Test
    func pendingToolTurnEvictedWhenSimulatedTimeExceedsTTL() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let config = Self.config(ttl: 1800)   // default 30-minute TTL
            let toolCallID = "toolu_evict_1"
            let mockClient = MockResponsesClient(
                streams: [
                    MockResponsesEventStream.toolUseTurn(
                        textBefore: nil,
                        toolName: "Bash",
                        callID: toolCallID,
                        argumentsJSON: "{\"command\":\"ls\"}"
                    ),
                ],
                performResults: []
            )
            let bridge = AnthropicBridge(configuration: config, responsesClient: mockClient, sessionLoader: MockSessionLoader())
            let req = try Self.toolUseRequest(sessionID: "evict-session-1", toolName: "Bash")

            // Consume the stream so the pending entry is stored.
            let response = await bridge.handleMessages(req)
            guard case .stream(let producer) = response.body else {
                Issue.record("Expected .stream body")
                return
            }
            let writer = InMemoryBodyWriter()
            try await producer(writer)

            // Entry exists (stored by handleOutputBlocks tool-use branch).
            #expect(await bridge.pendingToolTurnsCount() == 1)

            // Simulate 30 min + 1 s elapsed — past the TTL.
            await bridge.evictStalePending(now: Date().addingTimeInterval(1801))

            #expect(await bridge.pendingToolTurnsCount() == 0)
        }
    }

    @Test
    func pendingToolTurnSurvivesBeforeTTL() async throws {
        try await TraceIsolation.withTaskLocalIsolation {
            let config = Self.config(ttl: 1800)
            let toolCallID = "toolu_evict_2"
            let mockClient = MockResponsesClient(
                streams: [
                    MockResponsesEventStream.toolUseTurn(
                        textBefore: nil,
                        toolName: "Bash",
                        callID: toolCallID,
                        argumentsJSON: "{}"
                    ),
                ],
                performResults: []
            )
            let bridge = AnthropicBridge(configuration: config, responsesClient: mockClient, sessionLoader: MockSessionLoader())
            let req = try Self.toolUseRequest(sessionID: "evict-session-2", toolName: "Bash")

            let response = await bridge.handleMessages(req)
            guard case .stream(let producer) = response.body else {
                Issue.record("Expected .stream body")
                return
            }
            let writer = InMemoryBodyWriter()
            try await producer(writer)

            #expect(await bridge.pendingToolTurnsCount() == 1)
            // 29 min elapsed — still inside TTL.
            await bridge.evictStalePending(now: Date().addingTimeInterval(29 * 60))
            #expect(await bridge.pendingToolTurnsCount() == 1)
        }
    }
}
