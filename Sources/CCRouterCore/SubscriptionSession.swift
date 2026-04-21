import Foundation

public struct SubscriptionCredentials: Sendable, Equatable {
    public let accessToken: String
    public let accountID: String

    public init(accessToken: String, accountID: String) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public enum SubscriptionSessionError: Error, LocalizedError {
    case authFileMissing(URL)
    case missingAccessToken
    case missingAccountID

    public var errorDescription: String? {
        switch self {
        case .authFileMissing(let url):
            "Missing auth file at \(url.path)"
        case .missingAccessToken:
            "ChatGPT access token missing in ~/.codex/auth.json"
        case .missingAccountID:
            "ChatGPT account id missing in ~/.codex/auth.json"
        }
    }
}

public actor SubscriptionSessionLoader {
    private let authFileURL: URL

    public init(authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")) {
        self.authFileURL = authFileURL
    }

    public func loadCurrent() throws -> SubscriptionCredentials {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw SubscriptionSessionError.authFileMissing(authFileURL)
        }

        let data = try Data(contentsOf: authFileURL)
        let payload = try JSONDecoder().decode(AuthFile.self, from: data)

        guard let accessToken = payload.tokens?.access_token, !accessToken.isEmpty else {
            throw SubscriptionSessionError.missingAccessToken
        }
        guard let accountID = payload.tokens?.account_id, !accountID.isEmpty else {
            throw SubscriptionSessionError.missingAccountID
        }

        return SubscriptionCredentials(accessToken: accessToken, accountID: accountID)
    }
}

private struct AuthFile: Decodable {
    let tokens: Tokens?

    struct Tokens: Decodable {
        let access_token: String?
        let account_id: String?
    }
}
