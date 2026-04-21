import Foundation

public struct SubscriptionCredentials: Sendable, Equatable {
    public let accessToken: String
    public let accountID: String

    public init(accessToken: String, accountID: String) {
        self.accessToken = accessToken
        self.accountID = accountID
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

public actor SubscriptionSessionLoader {
    private let authFileURL: URL
    private let securityScopedBookmarkData: Data?
    private let processHomeDirectoryURL: URL

    public init(
        authFileURL: URL = URL(
            fileURLWithPath: UserHomeResolver.defaultSubscriptionAuthFilePath()
        ),
        securityScopedBookmarkData: Data? = nil,
        processHomeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.authFileURL = authFileURL
        self.securityScopedBookmarkData = securityScopedBookmarkData
        self.processHomeDirectoryURL = processHomeDirectoryURL
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

        return SubscriptionCredentials(accessToken: accessToken, accountID: accountID)
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

    struct Tokens: Decodable {
        let access_token: String?
        let account_id: String?
    }
}
