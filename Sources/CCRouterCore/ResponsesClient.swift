import Foundation

public struct ResponsesHTTPError: Error, LocalizedError, Sendable {
    public let statusCode: Int
    public let body: String

    public var errorDescription: String? {
        "Upstream /responses returned \(statusCode): \(body)"
    }
}

public actor ResponsesClient {
    private let session: URLSession
    private let endpoint: URL

    public init(endpoint: URL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
        self.endpoint = endpoint
    }

    public func perform(request payload: JSONObject, credentials: SubscriptionCredentials) async throws -> [JSONObject] {
        let encoded = try JSONEncoder().encode(payload)
        let compressed = try ZstdCodec.compress(encoded)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = compressed
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("zstd", forHTTPHeaderField: "content-encoding")
        request.setValue("ModelBridge/0.1", forHTTPHeaderField: "user-agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResponsesHTTPError(statusCode: -1, body: "Missing HTTPURLResponse")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ResponsesHTTPError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            )
        }

        return try Self.parseSSEEvents(from: data)
    }

    private static func parseSSEEvents(from data: Data) throws -> [JSONObject] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ResponsesHTTPError(statusCode: -1, body: "Upstream SSE was not UTF-8")
        }

        var events: [JSONObject] = []
        let decoder = JSONDecoder()

        for chunk in text.components(separatedBy: "\n\n") {
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
            for rawLine in lines {
                guard rawLine.hasPrefix("data: ") else { continue }
                let payload = String(rawLine.dropFirst(6))
                guard payload != "[DONE]" else { continue }
                let event = try decoder.decode(JSONObject.self, from: Data(payload.utf8))
                events.append(event)
            }
        }

        return events
    }
}
