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

    public var accessTokenPreview: String { "[redacted]" }
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
            "Claudex ChatGPT authorization is missing."
        case .missingAccountID:
            "Claudex ChatGPT registration is missing."
        }
    }
}

/// Protocol allowing `AnthropicBridge` to accept either the production actor
/// `SIWCAuth` or an offline test fake.
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
