import Foundation
import Testing
@testable import CCRouterCore

struct SubscriptionSessionTests {
    @Test
    func loadsCredentialsFromDirectAuthFile() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try Data(
            """
            {"tokens":{"access_token":"token-123","account_id":"acct-456"}}
            """.utf8
        ).write(to: tempURL)

        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        let credentials = try await loader.loadCurrent()

        #expect(credentials.accessToken == "token-123")
        #expect(credentials.accountID == "acct-456")
    }

    @Test
    func sandboxedExternalPathRequiresAuthorizationWithoutBookmark() async {
        let loader = SubscriptionSessionLoader(
            authFileURL: URL(fileURLWithPath: "/Users/tester/.codex/auth.json"),
            processHomeDirectoryURL: URL(
                fileURLWithPath: "/Users/tester/Library/Containers/com.90percent.ModelBridge/Data",
                isDirectory: true
            )
        )

        do {
            _ = try await loader.loadCurrent()
            Issue.record("Expected authorizationRequired error")
        } catch let error as SubscriptionSessionError {
            guard case .authorizationRequired(let url) = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
            #expect(url.path == "/Users/tester/.codex/auth.json")
        } catch {
            Issue.record("Unexpected non-SubscriptionSessionError: \(error.localizedDescription)")
        }
    }

    @Test
    func invalidJSONProducesAuthFileInvalidState() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-invalid-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try? Data("{not-json}".utf8).write(to: tempURL)

        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        do {
            _ = try await loader.loadCurrent()
            Issue.record("Expected authFileInvalid error")
        } catch let error as SubscriptionSessionError {
            guard case .authFileInvalid(let url, _) = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
            #expect(url.path == tempURL.path)
            #expect(error.authState == .authFileInvalid)
        } catch {
            Issue.record("Unexpected non-SubscriptionSessionError: \(error.localizedDescription)")
        }
    }

    @Test
    func missingAccessTokenProducesExpectedState() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-missing-token-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try? Data(
            """
            {"tokens":{"account_id":"acct-456"}}
            """.utf8
        ).write(to: tempURL)

        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        do {
            _ = try await loader.loadCurrent()
            Issue.record("Expected missingAccessToken error")
        } catch let error as SubscriptionSessionError {
            guard case .missingAccessToken = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
            #expect(error.authState == .missingAccessToken)
        } catch {
            Issue.record("Unexpected non-SubscriptionSessionError: \(error.localizedDescription)")
        }
    }

    @Test
    func refreshTokenAndLastRefreshParsedFromAuthFile() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-refresh-test-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try Data(
            """
            {"tokens":{"access_token":"a","account_id":"b","refresh_token":"r","id_token":"i"},"last_refresh":"2026-04-23T10:00:00Z"}
            """.utf8
        ).write(to: tempURL)

        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        let credentials = try await loader.loadCurrent()

        #expect(credentials.accessToken == "a")
        #expect(credentials.accountID == "b")
        #expect(credentials.refreshToken == "r")
        #expect(credentials.lastRefresh != nil)
    }

    @Test
    func missingRefreshTokenDoesNotBreakLoad() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-legacy-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Old auth.json format with only access_token + account_id
        try Data(
            """
            {"tokens":{"access_token":"old-access","account_id":"old-account"}}
            """.utf8
        ).write(to: tempURL)

        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        let credentials = try await loader.loadCurrent()

        #expect(credentials.accessToken == "old-access")
        #expect(credentials.accountID == "old-account")
        #expect(credentials.refreshToken == nil)
        #expect(credentials.lastRefresh == nil)
    }

    // MARK: - refreshAndReload tests (Task 4)

    @Test
    func refreshAndReloadUpdatesCredentials() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-refresh-update-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try Data(
            """
            {"tokens":{"access_token":"old","refresh_token":"r-old","account_id":"acc-1"},"OPENAI_API_KEY":"sk-test"}
            """.utf8
        ).write(to: tempURL)

        let mockRefresher = MockRefresher(
            refreshedTokens: RefreshedTokens(
                accessToken: "new-a",
                refreshToken: "r-new",
                idToken: "new-id",
                lastRefresh: Date()
            )
        )

        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            refresher: mockRefresher
        )

        let newCreds = try await loader.refreshAndReload()

        #expect(newCreds.accessToken == "new-a")
        #expect(newCreds.refreshToken == "r-new")

        // Verify auth file was updated atomically
        let fileData = try Data(contentsOf: tempURL)
        let decoded = try JSONDecoder().decode(Task4AuthFile.self, from: fileData)
        #expect(decoded.tokens?.access_token == "new-a")
        #expect(decoded.tokens?.refresh_token == "r-new")
        #expect(decoded.OPENAI_API_KEY == "sk-test") // other fields preserved
    }

    @Test
    func refreshAndReloadPreservesFilePermissions() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-refresh-perms-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try Data(
            """
            {"tokens":{"access_token":"old","refresh_token":"r-old","account_id":"acc-1"}}
            """.utf8
        ).write(to: tempURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tempURL.path
        )

        let mockRefresher = MockRefresher(
            refreshedTokens: RefreshedTokens(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                idToken: nil,
                lastRefresh: Date()
            )
        )

        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            refresher: mockRefresher
        )

        _ = try await loader.refreshAndReload()

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        #expect(attrs[.posixPermissions] as? Int == 0o600)
    }

    @Test
    func refreshWithNoRefreshTokenThrowsAuthorizationRequired() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-no-refresh-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Auth file with no refresh_token (old format)
        try Data(
            """
            {"tokens":{"access_token":"some-token","account_id":"acc-1"}}
            """.utf8
        ).write(to: tempURL)

        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        do {
            _ = try await loader.refreshAndReload()
            Issue.record("Expected authorizationRequired error")
        } catch let error as SubscriptionSessionError {
            guard case .authorizationRequired = error else {
                Issue.record("Wrong error type: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test
    func refreshFailureDoesNotCorruptAuthFile() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-refresh-fail-auth.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let originalData = Data(
            """
            {"tokens":{"access_token":"old-access","refresh_token":"r-old","account_id":"acc-1"}}
            """.utf8
        )
        try originalData.write(to: tempURL)

        let failingRefresher = MockRefresher(refreshError: AuthRefreshError.refreshFailed(statusCode: 401, body: "expired"))
        let loader = SubscriptionSessionLoader(
            authFileURL: tempURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            refresher: failingRefresher
        )

        do {
            _ = try await loader.refreshAndReload()
            Issue.record("Expected rethrow of refresh failure")
        } catch let error as AuthRefreshError {
            // DP-004: AuthRefreshError is rethrown directly so the bridge can
            // distinguish refresh failures from other auth errors in its trace log.
            guard case .refreshFailed(let statusCode, _) = error else {
                Issue.record("Expected refreshFailed variant, got \(error)")
                return
            }
            #expect(statusCode == 401)
        }

        // File content must be byte-for-byte identical
        let currentData = try Data(contentsOf: tempURL)
        #expect(currentData == originalData)
    }

    @Test
    func refreshWritebackFailureReturnsCredentialsWithoutThrow() async throws {
        // Directory that we can create a file in but then make read-only
        let containerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-refresh-writeback-container")
        defer { try? FileManager.default.removeItem(at: containerDir) }
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        let authFileURL = containerDir.appendingPathComponent("auth.json")
        try Data(
            """
            {"tokens":{"access_token":"old-access","refresh_token":"r-old","account_id":"acc-1"}}
            """.utf8
        ).write(to: authFileURL)

        // Make container read-only (auth file becomes non-writable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: containerDir.path
        )

        let mockRefresher = MockRefresher(
            refreshedTokens: RefreshedTokens(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                idToken: nil,
                lastRefresh: Date()
            )
        )

        let loader = SubscriptionSessionLoader(
            authFileURL: authFileURL,
            processHomeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            refresher: mockRefresher
        )

        // Should NOT throw — credentials returned from memory despite writeback failure
        let creds = try await loader.refreshAndReload()
        #expect(creds.accessToken == "new-access")

        // Restore permissions for cleanup
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: containerDir.path
        )
    }
}

// MARK: - Test helpers

/// Minimal decode shape for verifying auth file contents after refresh.
private struct Task4AuthFile: Decodable {
    let tokens: Tokens?
    let OPENAI_API_KEY: String?
    struct Tokens: Decodable {
        let access_token: String?
        let refresh_token: String?
    }
}

/// Mock AuthTokenRefreshing that returns configured tokens or throws configured error.
private actor MockRefresher: AuthTokenRefreshing {
    private let _refreshedTokens: RefreshedTokens?
    private let _error: Error?

    init(refreshedTokens: RefreshedTokens) {
        self._refreshedTokens = refreshedTokens
        self._error = nil
    }

    init(refreshError: Error) {
        self._refreshedTokens = nil
        self._error = refreshError
    }

    func refresh(refreshToken: String, clientID: String?) async throws -> RefreshedTokens {
        if let error = _error { throw error }
        return _refreshedTokens!
    }
}
