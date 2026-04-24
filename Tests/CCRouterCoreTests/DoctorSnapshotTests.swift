import Foundation
@testable import CCRouterCore
import Testing

struct DoctorSnapshotTests {
    @Test
    func doctorSnapshotIncludesPendingToolTurnsCount() throws {
        let snapshot = DoctorSnapshot(
            host: "127.0.0.1", port: 4317, daemonState: "running", startedAt: nil,
            anthropicMessagesPath: "/v1/messages", countTokensPath: "/v1/messages/count_tokens",
            messagesImplemented: true, countTokensImplemented: true, countTokensStrategy: "cl100k-bpe",
            responsesURL: "https://example/",
            executorModel: "gpt-5.4", advisorModel: "gpt-5.4",
            gatewayAuthHeader: "x-api-key", gatewayAuthTokenSuffix: "xxxxxx",
            configurationPath: "/dev/null/config.json", configurationWarning: nil,
            subscriptionAuthFilePath: "/dev/null/auth.json",
            authState: .ready, chatGPTAuthenticated: true, accountIDSuffix: "abcdef", authError: nil,
            lastRefresh: nil, hasRefreshToken: false,
            accessTokenPreview: nil,
            tracePath: "/tmp/trace.jsonl", recentTraceLines: [],
            traceDiagnostics: .empty,
            pendingToolTurnsCount: 3
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DoctorSnapshot.self, from: data)
        #expect(decoded.pendingToolTurnsCount == 3)
    }

    @Test
    func doctorSnapshotIncludesLastRefreshAndRefreshTokenPresence() async throws {
        // Fixture auth.json with refresh_token + last_refresh.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let authURL = tempDir.appendingPathComponent("auth.json")
        let authJSON = """
        {
          "tokens": {
            "access_token": "access-old",
            "account_id": "acc-1",
            "refresh_token": "refresh-r1",
            "id_token": "id-token-1"
          },
          "last_refresh": "2026-04-23T10:00:00Z"
        }
        """
        try authJSON.write(to: authURL, atomically: true, encoding: .utf8)

        let loader = SubscriptionSessionLoader(
            authFileURL: authURL,
            securityScopedBookmarkData: nil
        )
        let bridge = AnthropicBridge(
            configuration: RouterConfiguration(
                host: "127.0.0.1", port: 4317,
                healthPath: "/health", messagesPath: "/v1/messages",
                countTokensPath: "/v1/messages/count_tokens",
                responsesURL: "https://chatgpt.com/backend-api/codex/responses",
                executorModel: "gpt-5.4", advisorModel: "gpt-5.4",
                gatewayAuthToken: "test-token", gatewayAuthHeader: "x-api-key",
                subscriptionAuthFilePath: authURL.path,
                configurationPath: "/dev/null/config.json",
                configurationWarning: nil
            ),
            sessionLoader: loader
        )

        let status = await bridge.doctorStatus()
        #expect(status.hasRefreshToken == true)
        #expect(status.lastRefresh != nil)
        #expect(status.accessTokenPreview == "acce…-old")

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test
    func snapshotHandlesLegacyAuthFileWithoutRefreshToken() async throws {
        // Fixture auth.json with only access_token (old format, no refresh_token).
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let authURL = tempDir.appendingPathComponent("auth.json")
        let authJSON = """
        {
          "tokens": {
            "access_token": "access-old",
            "account_id": "acc-1"
          }
        }
        """
        try authJSON.write(to: authURL, atomically: true, encoding: .utf8)

        let loader = SubscriptionSessionLoader(
            authFileURL: authURL,
            securityScopedBookmarkData: nil
        )
        let bridge = AnthropicBridge(
            configuration: RouterConfiguration(
                host: "127.0.0.1", port: 4317,
                healthPath: "/health", messagesPath: "/v1/messages",
                countTokensPath: "/v1/messages/count_tokens",
                responsesURL: "https://chatgpt.com/backend-api/codex/responses",
                executorModel: "gpt-5.4", advisorModel: "gpt-5.4",
                gatewayAuthToken: "test-token", gatewayAuthHeader: "x-api-key",
                subscriptionAuthFilePath: authURL.path,
                configurationPath: "/dev/null/config.json",
                configurationWarning: nil
            ),
            sessionLoader: loader
        )

        let status = await bridge.doctorStatus()
        #expect(status.hasRefreshToken == false)
        #expect(status.lastRefresh == nil)
        #expect(status.accessTokenPreview == "acce…-old")

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test
    func accessTokenPreviewExposedWhenAuthenticated() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let authURL = tempDir.appendingPathComponent("auth.json")
        let authJSON = """
        {
          "tokens": {
            "access_token": "abcd1234efgh5678",
            "account_id": "acc-1",
            "refresh_token": "refresh-r1"
          }
        }
        """
        try authJSON.write(to: authURL, atomically: true, encoding: .utf8)

        let bridge = AnthropicBridge(
            configuration: RouterConfiguration(
                host: "127.0.0.1", port: 4317,
                healthPath: "/health", messagesPath: "/v1/messages",
                countTokensPath: "/v1/messages/count_tokens",
                responsesURL: "https://chatgpt.com/backend-api/codex/responses",
                executorModel: "gpt-5.4", advisorModel: "gpt-5.4",
                gatewayAuthToken: "test-token", gatewayAuthHeader: "x-api-key",
                subscriptionAuthFilePath: authURL.path,
                configurationPath: "/dev/null/config.json",
                configurationWarning: nil
            ),
            sessionLoader: SubscriptionSessionLoader(authFileURL: authURL)
        )

        let status = await bridge.doctorStatus()
        #expect(status.accessTokenPreview == "abcd…5678")
    }
}
