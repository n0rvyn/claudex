import Foundation

// MARK: - Public Types

public protocol AuthTokenRefreshing: Sendable {
    func refresh(refreshToken: String, clientID: String?) async throws -> RefreshedTokens
}

public struct RefreshedTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String   // upstream may rotate
    public let idToken: String?
    public let lastRefresh: Date

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        lastRefresh: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.lastRefresh = lastRefresh
    }
}

public enum AuthRefreshError: Error, Sendable, Equatable {
    case refreshFailed(statusCode: Int, body: String)
    case invalidResponseBody(String)
}

// MARK: - HTTP Fetcher Protocol (public so test module can conform)

/// Abstracts the HTTP POST so AuthTokenRefresher can be tested without URLProtocol tricks.
public protocol AuthTokenHTTPFetcher: Sendable {
    /// Performs a POST request. Caller handles status-code checking.
    func post(url: URL, body: Data) async throws -> (statusCode: Int, body: Data)
}

// MARK: - Default Production Fetcher

/// Default production implementation using URLSession.
public actor AuthTokenDefaultFetcher: AuthTokenHTTPFetcher {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10      // first byte deadline
        config.timeoutIntervalForResource = 15     // overall refresh deadline
        self.session = session ?? URLSession(configuration: config)
    }

    public func post(url: URL, body: Data) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error  // rethrow URLError so caller can distinguish network vs auth
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthRefreshError.refreshFailed(statusCode: -1, body: "non-HTTP response")
        }

        return (httpResponse.statusCode, data)
    }
}

// MARK: - Refresh Request / Response

private struct RefreshRequest: Encodable {
    let client_id: String
    let grant_type: String
    let refresh_token: String
}

private struct RefreshResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let id_token: String?
}

// MARK: - Actor Implementation

/// Refreshes ChatGPT/OAuth tokens against auth.openai.com.
/// - Endpoint: https://auth.openai.com/oauth/token (hardcoded; not from auth.json)
/// - Request: POST application/json
/// - Request body: { "client_id": "...", "grant_type": "refresh_token", "refresh_token": "..." }
/// - Response: { "access_token": "...", "refresh_token": "...", "id_token": "..." }
public actor AuthTokenRefresher: AuthTokenRefreshing {
    private let endpoint: URL
    private let httpFetcher: any AuthTokenHTTPFetcher

    // From codex-rs/login/src/auth/manager.rs:
    // pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
    private static let defaultClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public init(
        endpoint: URL = URL(string: "https://auth.openai.com/oauth/token")!,
        httpFetcher: (any AuthTokenHTTPFetcher)? = nil
    ) {
        self.endpoint = endpoint
        // Use the concrete actor as the default; actors conform to their own protocol
        self.httpFetcher = httpFetcher ?? AuthTokenDefaultFetcher()
    }

    public func refresh(refreshToken: String, clientID: String?) async throws -> RefreshedTokens {
        let resolvedClientID = clientID ?? Self.defaultClientID

        let requestBody = RefreshRequest(
            client_id: resolvedClientID,
            grant_type: "refresh_token",
            refresh_token: refreshToken
        )

        let bodyData = try JSONEncoder().encode(requestBody)

        let (statusCode, data): (Int, Data)
        do {
            (statusCode, data) = try await httpFetcher.post(url: endpoint, body: bodyData)
        } catch {
            throw error  // rethrow URLError so caller can distinguish network vs auth
        }

        guard (200...299).contains(statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<binary data>"
            throw AuthRefreshError.refreshFailed(statusCode: statusCode, body: bodyString)
        }

        let refreshed: RefreshResponse
        do {
            refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        } catch {
            throw AuthRefreshError.invalidResponseBody(String(data: data, encoding: .utf8) ?? "<binary data>")
        }

        guard let accessToken = refreshed.access_token, !accessToken.isEmpty else {
            throw AuthRefreshError.invalidResponseBody("response missing access_token")
        }

        guard let newRefreshToken = refreshed.refresh_token, !newRefreshToken.isEmpty else {
            throw AuthRefreshError.invalidResponseBody("response missing refresh_token")
        }

        return RefreshedTokens(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            idToken: refreshed.id_token,
            lastRefresh: Date()
        )
    }
}
