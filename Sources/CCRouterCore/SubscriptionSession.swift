import Foundation

public struct SubscriptionCredentials: Sendable, Equatable {
    public let accessToken: String
    public let accountID: String
    public let refreshToken: String?
    public let lastRefresh: Date?

    public init(
        accessToken: String,
        accountID: String,
        refreshToken: String? = nil,
        lastRefresh: Date? = nil
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.refreshToken = refreshToken
        self.lastRefresh = lastRefresh
    }

    public var accessTokenPreview: String {
        let head = accessToken.prefix(4)
        let tail = accessToken.suffix(4)
        return "\(head)…\(tail)"
    }
}

public enum SubscriptionAuthState: String, Codable, Sendable, Equatable {
    case ready
    case authorizationRequired
    case bookmarkResolutionFailed
    case authFileMissing
    case authFileUnreadable
    case authFileInvalid
    case missingAccessToken
    case missingAccountID
    case unknownFailure

    public var isReady: Bool {
        self == .ready
    }

    public var requiresFileSelection: Bool {
        switch self {
        case .authorizationRequired, .bookmarkResolutionFailed:
            return true
        default:
            return false
        }
    }
}

public enum SubscriptionSessionError: Error, LocalizedError {
    case authFileMissing(URL)
    case authorizationRequired(URL)
    case bookmarkResolutionFailed(URL, String)
    case authFileUnreadable(URL, String)
    case authFileInvalid(URL, String)
    case missingAccessToken
    case missingAccountID

    public var authState: SubscriptionAuthState {
        switch self {
        case .authFileMissing:
            .authFileMissing
        case .authorizationRequired:
            .authorizationRequired
        case .bookmarkResolutionFailed:
            .bookmarkResolutionFailed
        case .authFileUnreadable:
            .authFileUnreadable
        case .authFileInvalid:
            .authFileInvalid
        case .missingAccessToken:
            .missingAccessToken
        case .missingAccountID:
            .missingAccountID
        }
    }

    public var errorDescription: String? {
        switch self {
        case .authFileMissing(let url):
            "Missing auth file at \(url.path)"
        case .authorizationRequired(let url):
            "Sandbox access is not authorized for \(url.path); choose the auth file in Settings."
        case .bookmarkResolutionFailed(let url, let reason):
            "Auth file bookmark could not be resolved for \(url.path): \(reason)"
        case .authFileUnreadable(let url, let reason):
            "Auth file at \(url.path) could not be read: \(reason)"
        case .authFileInvalid(let url, let reason):
            "Auth file at \(url.path) is not valid JSON: \(reason)"
        case .missingAccessToken:
            "ChatGPT access token missing in ~/.codex/auth.json"
        case .missingAccountID:
            "ChatGPT account id missing in ~/.codex/auth.json"
        }
    }
}

/// Protocol allowing `AnthropicBridge` to accept either the production actor
/// `SubscriptionSessionLoader` or a test fake.
///
/// Kept as a simple async-throws contract so the production actor and any test
/// implementation share the same call site in `AnthropicBridge`.
public protocol SubscriptionSessionProviding: Sendable {
    func loadCurrent() async throws -> SubscriptionCredentials
    /// Refreshes the subscription token and reloads credentials.
    /// Throws `SubscriptionSessionError.authorizationRequired` if no refresh token is available.
    func refreshAndReload() async throws -> SubscriptionCredentials
}

public extension SubscriptionSessionProviding {
    func refreshAndReload() async throws -> SubscriptionCredentials {
        throw SubscriptionSessionError.authorizationRequired(URL(fileURLWithPath: "/"))
    }
}

public actor SubscriptionSessionLoader: SubscriptionSessionProviding {
    private let authFileURL: URL
    private let securityScopedBookmarkData: Data?
    private let processHomeDirectoryURL: URL
    private let refresher: any AuthTokenRefreshing

    // Refresh cache for rotating token safety (DP-002 conservative branch).
    // Short-circuit concurrent callers within 5 seconds of a successful refresh.
    private var lastSuccessfulRefreshAt: Date?
    private var cachedCredentialsAfterRefresh: SubscriptionCredentials?

    public init(
        authFileURL: URL = URL(
            fileURLWithPath: UserHomeResolver.defaultSubscriptionAuthFilePath()
        ),
        securityScopedBookmarkData: Data? = nil,
        processHomeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        refresher: (any AuthTokenRefreshing)? = nil
    ) {
        self.authFileURL = authFileURL
        self.securityScopedBookmarkData = securityScopedBookmarkData
        self.processHomeDirectoryURL = processHomeDirectoryURL
        self.refresher = refresher ?? AuthTokenRefresher()
    }

    public func loadCurrent() throws -> SubscriptionCredentials {
        let loaded = try loadAuthFileData()
        let payload: AuthFile
        do {
            payload = try JSONDecoder().decode(AuthFile.self, from: loaded.data)
        } catch {
            throw SubscriptionSessionError.authFileInvalid(
                loaded.url,
                error.localizedDescription
            )
        }

        guard let accessToken = payload.tokens?.access_token, !accessToken.isEmpty else {
            throw SubscriptionSessionError.missingAccessToken
        }
        guard let accountID = payload.tokens?.account_id, !accountID.isEmpty else {
            throw SubscriptionSessionError.missingAccountID
        }

        return SubscriptionCredentials(
            accessToken: accessToken,
            accountID: accountID,
            refreshToken: payload.tokens?.refresh_token,
            lastRefresh: parseLastRefresh(from: payload.last_refresh)
        )
    }

    // MARK: - Refresh

    public func refreshAndReload() async throws -> SubscriptionCredentials {
        // Cache-hit short-circuit (DP-005 conservative branch):
        // Since refresh_token is rotating, concurrent requests hitting a fresh cache
        // should reuse the same token to avoid invalidating the just-issued refresh_token.
        // See: docs/research/2026-04-23-codex-refresh-endpoint-probe.md
        if let last = lastSuccessfulRefreshAt,
           Date().timeIntervalSince(last) < 5.0,
           let cached = cachedCredentialsAfterRefresh {
            return cached
        }

        // Load current auth state to get refresh token.
        let loaded = try loadAuthFileData()
        let url = loaded.url

        let payload: AuthFile
        do {
            payload = try JSONDecoder().decode(AuthFile.self, from: loaded.data)
        } catch {
            throw SubscriptionSessionError.authFileInvalid(url, error.localizedDescription)
        }

        guard let refreshToken = payload.tokens?.refresh_token, !refreshToken.isEmpty else {
            throw SubscriptionSessionError.authorizationRequired(url)
        }

        // Rethrow AuthRefreshError directly so AnthropicBridge.handleMessages
        // can distinguish it in its error_type introspection (DP-004).
        let refreshed = try await refresher.refresh(refreshToken: refreshToken, clientID: nil)

        let newCredentials = SubscriptionCredentials(
            accessToken: refreshed.accessToken,
            accountID: payload.tokens?.account_id ?? "",
            refreshToken: refreshed.refreshToken,
            lastRefresh: refreshed.lastRefresh
        )

        // Update actor-local cache BEFORE write-back so concurrent callers
        // see the fresh credentials even if disk write fails.
        lastSuccessfulRefreshAt = refreshed.lastRefresh
        cachedCredentialsAfterRefresh = newCredentials

        // Attempt atomic write-back; log and continue on failure (degraded but self-healing).
        do {
            try writeAuthFileAtomically(
                refreshed: refreshed,
                destinationURL: url,
                existingJSONData: loaded.data
            )
        } catch {
            await TraceLogger.shared.log(JSONObject.from([
                "stage": .string("subscription_refresh_writeback_failed"),
                "error_message": .string(String(String(describing: error).prefix(200))),
            ]))
            // Do NOT rethrow: memory cache has fresh credentials.
        }

        return newCredentials
    }

    private func writeAuthFileAtomically(
        refreshed: RefreshedTokens,
        destinationURL: URL,
        existingJSONData: Data
    ) throws {
        // Determine whether we need security-scoped access for this URL.
        let needsSecurityScoped = securityScopedBookmarkData != nil
        let resolvedURL: URL
        if needsSecurityScoped {
            var bookmarkIsStale = false
            resolvedURL = try URL(
                resolvingBookmarkData: securityScopedBookmarkData!,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
        } else {
            resolvedURL = destinationURL
        }

        // Wrap all filesystem operations in security-scoped access if needed.
        let writeOperation: () throws -> Void = {
            // Parse existing JSON, preserving all other fields.
            var authDict: [String: Any]
            if let existing = try? JSONSerialization.jsonObject(with: existingJSONData) as? [String: Any] {
                authDict = existing
            } else {
                authDict = [:]
            }

            // Update tokens sub-dict.
            var tokens = (authDict["tokens"] as? [String: Any]) ?? [:]
            tokens["access_token"] = refreshed.accessToken
            tokens["refresh_token"] = refreshed.refreshToken
            if let idToken = refreshed.idToken {
                tokens["id_token"] = idToken
            }
            authDict["tokens"] = tokens

            // Update top-level last_refresh.
            authDict["last_refresh"] = ISO8601DateFormatter().string(from: refreshed.lastRefresh)

            // Serialize back to JSON with pretty printing.
            let encoder = try JSONSerialization.data(
                withJSONObject: authDict,
                options: [.prettyPrinted, .sortedKeys]
            )

            // Write to temp file in the same volume, then atomically replace.
            let tempDir = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: resolvedURL,
                create: true
            )
            let tempURL = tempDir.appendingPathComponent("auth.json.tmp")
            try encoder.write(to: tempURL)

            // Atomic replacement preserves original file permissions (DP-P5-003).
            try FileManager.default.replaceItemAt(
                resolvedURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: []
            )
        }

        if needsSecurityScoped {
            guard resolvedURL.startAccessingSecurityScopedResource() else {
                throw SubscriptionSessionError.authorizationRequired(resolvedURL)
            }
            defer { resolvedURL.stopAccessingSecurityScopedResource() }
        }

        try writeOperation()
    }

    private func loadAuthFileData() throws -> (data: Data, url: URL) {
        if let securityScopedBookmarkData, !securityScopedBookmarkData.isEmpty {
            return try loadWithSecurityScopedBookmark(securityScopedBookmarkData)
        }
        if requiresSandboxAuthorization(for: authFileURL) {
            throw SubscriptionSessionError.authorizationRequired(authFileURL)
        }
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw SubscriptionSessionError.authFileMissing(authFileURL)
        }
        do {
            return (try Data(contentsOf: authFileURL), authFileURL)
        } catch {
            throw SubscriptionSessionError.authFileUnreadable(authFileURL, error.localizedDescription)
        }
    }

    private func loadWithSecurityScopedBookmark(_ bookmarkData: Data) throws -> (data: Data, url: URL) {
        var bookmarkIsStale = false
        let scopedURL: URL
        do {
            scopedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
        } catch {
            throw SubscriptionSessionError.bookmarkResolutionFailed(
                authFileURL,
                error.localizedDescription
            )
        }

        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw SubscriptionSessionError.authorizationRequired(scopedURL)
        }
        defer { scopedURL.stopAccessingSecurityScopedResource() }

        guard FileManager.default.fileExists(atPath: scopedURL.path) else {
            throw SubscriptionSessionError.authFileMissing(scopedURL)
        }
        do {
            return (try Data(contentsOf: scopedURL), scopedURL)
        } catch {
            let reason = bookmarkIsStale
                ? "bookmark is stale and the file could not be reopened"
                : error.localizedDescription
            throw SubscriptionSessionError.authFileUnreadable(scopedURL, reason)
        }
    }

    private func requiresSandboxAuthorization(for url: URL) -> Bool {
        let processHomePath = processHomeDirectoryURL.standardizedFileURL.path
        guard processHomePath.contains("/Library/Containers/"),
              processHomePath.hasSuffix("/Data")
        else {
            return false
        }

        return !url.standardizedFileURL.path.hasPrefix(processHomePath)
    }
}

private struct AuthFile: Decodable {
    let tokens: Tokens?
    let last_refresh: String?

    struct Tokens: Decodable {
        let access_token: String?
        let account_id: String?
        let refresh_token: String?
        let id_token: String?
    }
}

private nonisolated(unsafe) let _iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private nonisolated(unsafe) let _iso8601Fallback: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private nonisolated func parseLastRefresh(from isoString: String?) -> Date? {
    guard let isoString, !isoString.isEmpty else { return nil }
    if let date = _iso8601.date(from: isoString) { return date }
    return _iso8601Fallback.date(from: isoString)
}
