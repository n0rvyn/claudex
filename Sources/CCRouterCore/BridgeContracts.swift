import Foundation

// MARK: - ResponsesStreamingClient protocol

/// Protocol allowing `AnthropicBridge` to be tested with a mock streaming client.
public protocol ResponsesStreamingClient: Sendable {
    func streamEvents(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> AsyncThrowingStream<JSONObject, Error>

    func streamEvents(request: JSONObject, credentials: SubscriptionCredentials, requestID: UUID) async throws -> AsyncThrowingStream<JSONObject, Error>
    func cancelRequest(_ requestID: UUID) async

    func perform(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> [JSONObject]
}

extension ResponsesClient: ResponsesStreamingClient {}

// MARK: - BridgeDoctorStatus

public struct BridgeDoctorStatus: Sendable {
    public let authState: SubscriptionAuthState
    public let chatGPTAuthenticated: Bool
    public let accountIDSuffix: String?
    public let authError: String?
    public let lastRefresh: Date?
    public let hasRefreshToken: Bool
    public let accessTokenPreview: String?
}

/// Result type returned by the count_tokens endpoint.
public struct CountTokensResult: Codable, Sendable {
    public let input_tokens: Int

    public init(input_tokens: Int) {
        self.input_tokens = input_tokens
    }
}

public extension ResponsesStreamingClient {
    func streamEvents(request: JSONObject, credentials: SubscriptionCredentials, requestID: UUID) async throws -> AsyncThrowingStream<JSONObject, Error> {
        try await streamEvents(request: request, credentials: credentials)
    }
    func cancelRequest(_ requestID: UUID) async {}
}
