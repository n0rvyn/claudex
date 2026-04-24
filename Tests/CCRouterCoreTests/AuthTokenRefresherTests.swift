import Foundation
import Testing
@testable import CCRouterCore

struct AuthTokenRefresherTests {
    @Test
    func successfulRefreshReturnsNewTokens() async throws {
        let expectedAccess = "new-access-token-abc"
        let expectedRefresh = "new-refresh-token-xyz"
        let expectedID = "eyJidXQiOiJpbTEifQ.eyJzdWIiOiIxMjM0NTY3ODkwIn0.fake"

        let mockFetcher = MockHTTPFetcher()
        mockFetcher.setResponse(
            statusCode: 200,
            body: Data("""
            {"access_token": "\(expectedAccess)", "refresh_token": "\(expectedRefresh)", "id_token": "\(expectedID)"}
            """.utf8)
        )

        let refresher = AuthTokenRefresher(
            endpoint: URL(string: "https://auth.openai.com/oauth/token")!,
            httpFetcher: mockFetcher
        )

        let result = try await refresher.refresh(
            refreshToken: "old-refresh-token",
            clientID: nil
        )

        #expect(result.accessToken == expectedAccess)
        #expect(result.refreshToken == expectedRefresh)
        #expect(result.idToken == expectedID)
        #expect(result.lastRefresh != nil)
        #expect(mockFetcher.postCallCount == 1)
    }

    @Test
    func http401ThrowsRefreshFailed() async throws {
        let mockFetcher = MockHTTPFetcher()
        mockFetcher.setResponse(
            statusCode: 401,
            body: Data("""
            {"error": "invalid_grant", "code": "refresh_token_expired"}
            """.utf8)
        )

        let refresher = AuthTokenRefresher(
            endpoint: URL(string: "https://auth.openai.com/oauth/token")!,
            httpFetcher: mockFetcher
        )

        do {
            _ = try await refresher.refresh(refreshToken: "expired-token", clientID: nil)
            Issue.record("Expected AuthRefreshError.refreshFailed")
        } catch let error as AuthRefreshError {
            guard case .refreshFailed(statusCode: let code, _) = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }
            #expect(code == 401)
        }
    }

    @Test
    func malformedJSONThrowsInvalidResponseBody() async throws {
        let mockFetcher = MockHTTPFetcher()
        mockFetcher.setResponse(statusCode: 200, body: Data("not json at all".utf8))

        let refresher = AuthTokenRefresher(
            endpoint: URL(string: "https://auth.openai.com/oauth/token")!,
            httpFetcher: mockFetcher
        )

        do {
            _ = try await refresher.refresh(refreshToken: "some-token", clientID: nil)
            Issue.record("Expected AuthRefreshError.invalidResponseBody")
        } catch let error as AuthRefreshError {
            guard case .invalidResponseBody = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }
        }
    }

    @Test
    func networkErrorThrowsURLError() async throws {
        let mockFetcher = MockHTTPFetcher()
        mockFetcher.setError(URLError(.notConnectedToInternet))

        let refresher = AuthTokenRefresher(
            endpoint: URL(string: "https://auth.openai.com/oauth/token")!,
            httpFetcher: mockFetcher
        )

        do {
            _ = try await refresher.refresh(refreshToken: "some-token", clientID: nil)
            Issue.record("Expected URLError")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
    }
}

// MARK: - Mock Fetcher

/// Mock conforming to AuthTokenHTTPFetcher with no concurrency issues.
/// State is set once before the test (sync), read once during the test (async),
/// so no locking is needed.
private final class MockHTTPFetcher: AuthTokenHTTPFetcher, @unchecked Sendable {
    private var _statusCode: Int = 200
    private var _body: Data = Data()
    private var _error: Error?
    private var _postCallCount: Int = 0

    func setResponse(statusCode: Int, body: Data) {
        _statusCode = statusCode
        _body = body
        _error = nil
    }

    func setError(_ error: Error) {
        _error = error
    }

    var postCallCount: Int {
        _postCallCount
    }

    nonisolated func post(url: URL, body: Data) async throws -> (statusCode: Int, body: Data) {
        _postCallCount += 1
        if let error = _error {
            throw error
        }
        return (_statusCode, _body)
    }
}
