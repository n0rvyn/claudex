import Foundation
@testable import CCRouterCore
import Testing

// MARK: - TraceLoggerRefreshEventsTests

/// Tests that the refresh and count_tokens paths emit correct trace events.
/// Each test binds `TraceLogger.$overrideFileURL` to a per-test temp file so
/// parallel test suites writing to the default shared path cannot interleave
/// with this test's reset + read sequence.
struct TraceLoggerRefreshEventsTests {

    /// Creates a unique temporary trace-log file URL for one test run.
    private static func makeIsolatedTraceFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelBridgeTraceTest-\(UUID().uuidString).jsonl")
    }

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

    private static func makeMessagesRequest() -> HTTPRequest {
        let body = AnthropicMessagesRequest(
            model: "claude-sonnet-4-6",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("hello")])
                ])
            ],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: false
        )
        let bodyData = try! JSONEncoder().encode(body)
        return HTTPRequest(
            method: "POST",
            path: "/v1/messages",
            headers: ["content-type": "application/json"],
            body: bodyData
        )
    }

    private static func makeCountTokensRequest() -> HTTPRequest {
        let body = AnthropicMessagesRequest(
            model: "claude-sonnet-4-6",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "user", content: [
                    JSONObject.from(["type": .string("text"), "text": .string("hello world")])
                ])
            ],
            system: nil,
            tools: nil,
            thinking: nil,
            context_management: nil,
            metadata: nil,
            output_config: nil,
            stream: false
        )
        let bodyData = try! JSONEncoder().encode(body)
        return HTTPRequest(
            method: "POST",
            path: "/v1/messages/count_tokens",
            headers: ["content-type": "application/json"],
            body: bodyData
        )
    }

    // MARK: - Refresh trace tests

    /// verify: handleMessages emits subscription_refresh_success when the 401->refresh->retry path succeeds.
    @Test
    func refreshSuccessEmitsTraceEvent() async throws {
        let traceURL = Self.makeIsolatedTraceFileURL()
        defer { try? FileManager.default.removeItem(at: traceURL) }

        try await TraceLogger.$overrideFileURL.withValue(traceURL) {
            await TraceLogger.shared.resetForTesting()

            let refreshedCreds = SubscriptionCredentials(
                accessToken: "new-access-token",
                accountID: "test-account",
                refreshToken: "new-refresh-token",
                lastRefresh: Date()
            )

            let mockResponsesClient = MockResponsesClient(streams: [])
            await mockResponsesClient.enqueueError(ResponsesHTTPError(statusCode: 401, body: "expired"))

            let mockSessionLoader = MockSessionLoader(
                credentials: Self.testCredentials,
                refreshedCredentials: refreshedCreds
            )

            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: mockResponsesClient,
                sessionLoader: mockSessionLoader
            )

            let request = Self.makeMessagesRequest()
            _ = await bridge.handleMessages(request)

            let lines = await TraceLogger.shared.recentLines(limit: 20)
            let combined = lines.joined(separator: "\n")

            // Must contain the success stage
            try #require(combined.contains("subscription_refresh_success"))
            // Must contain the access token SUFFIX (plan DP-P5-002: last 4 chars).
            // "new-access-token" -> suffix(4) = "oken"
            try #require(combined.contains("\"access_token_suffix\":\"oken\""))
            // Must NOT contain the full access token
            try #require(!combined.contains("new-access-token"))
        }
    }

    // MARK: - count_tokens trace tests

    /// verify: handleCountTokens emits count_tokens_in then count_tokens_out in order.
    @Test
    func countTokensEndpointEmitsTraceEvents() async throws {
        let traceURL = Self.makeIsolatedTraceFileURL()
        defer { try? FileManager.default.removeItem(at: traceURL) }

        try await TraceLogger.$overrideFileURL.withValue(traceURL) {
            await TraceLogger.shared.resetForTesting()

            let bridge = AnthropicBridge(
                configuration: Self.testConfig,
                responsesClient: MockResponsesClient(streams: []),
                sessionLoader: MockSessionLoader(credentials: Self.testCredentials)
            )

            let request = Self.makeCountTokensRequest()
            let response = await bridge.handleCountTokens(request)

            #expect(response.statusCode == 200)
            let result = try JSONDecoder().decode(CountTokensResult.self, from: response.bodyData!)
            #expect(result.input_tokens > 0)

            let lines = await TraceLogger.shared.recentLines(limit: 20)
            let combined = lines.joined(separator: "\n")

            // Must contain count_tokens_in
            try #require(combined.contains("count_tokens_in"))
            // Must contain count_tokens_out
            try #require(combined.contains("count_tokens_out"))
            // count_tokens_out input_tokens must match the response body
            try #require(combined.contains(String(result.input_tokens)))
            // duration_ms must be non-negative (DP-P5-002 B: regression guard for the
            // ContinuousClock direction bug — startTime.duration(to: .now) yields positive
            // elapsed; the previous `now.duration(to: startTime)` form yielded negative.).
            let durationOutLine = try #require(lines.first { $0.contains("count_tokens_out") })
            let durationValue = try Self.extractNumber(key: "duration_ms", from: durationOutLine)
            #expect(durationValue >= 0, "duration_ms must be non-negative, got \(durationValue)")
        }
    }

    /// Extract a numeric JSON value by key from a single JSONL line for duration_ms assertion.
    private static func extractNumber(key: String, from line: String) throws -> Double {
        let data = try #require(line.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try #require(object[key] as? Double)
        return value
    }
}
