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
}
