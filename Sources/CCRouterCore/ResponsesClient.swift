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

    /// Constructs a ResponsesClient with a custom URLSession — intended for
    /// test-only injection of URLProtocol stubs (e.g. MockSSEProtocol).
    public init(session: URLSession, endpoint: URL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!) {
        self.session = session
        self.endpoint = endpoint
    }

    // MARK: - Streaming API (new)

    /// Streams SSE events from the /responses endpoint as an AsyncThrowingStream.
    ///
    /// Uses `URLSession.bytes(for:)` to begin receiving bytes as soon as they
    /// arrive, parsing each `data:` line into a JSONObject and yielding it.
    /// The returned stream properly wires consumer cancellation back to the
    /// underlying task so the HTTP connection is torn down promptly.
    public func streamEvents(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> AsyncThrowingStream<JSONObject, Error> {
        let request = try makeRequest(payload: payload, credentials: credentials)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResponsesHTTPError(statusCode: -1, body: "Missing HTTPURLResponse")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyString = await Self.drainErrorBody(bytes)
            throw ResponsesHTTPError(statusCode: httpResponse.statusCode, body: bodyString)
        }

        return Self.parseSSELines(bytes.lines)
    }

    /// Drains an async byte sequence into a UTF-8 string (or a byte-count
    /// placeholder when the body is not valid UTF-8). Intended for building
    /// the `body` of a `ResponsesHTTPError` after a non-2xx status. Reads at
    /// most `maxBytes` bytes (default 64 KB) to avoid unbounded memory use on
    /// pathological upstream error bodies.
    ///
    /// `internal` for direct unit testing — `URLSession.bytes(for:)` does not
    /// cooperate with URLProtocol on Swift 6.2, so tests exercise the drain
    /// logic by feeding an in-memory byte sequence.
    internal static func drainErrorBody<S: AsyncSequence & Sendable>(
        _ bytes: S,
        maxBytes: Int = 64_000
    ) async -> String where S.Element == UInt8 {
        var errorBody = Data()
        do {
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count >= maxBytes { break }
            }
        } catch {
            // Drain failure is best-effort; return what we got.
        }
        return String(data: errorBody, encoding: .utf8)
            ?? "<non-utf8 body, \(errorBody.count) bytes>"
    }

    /// Parses an async sequence of SSE lines into JSONObject events.
    ///
    /// Skips blank lines, `[DONE]` sentinels, lines that do not start with
    /// `data: `, and individual lines whose payload fails JSON decoding (a
    /// single malformed event does not abort the rest of the stream).
    ///
    /// This is `internal` rather than `private` so unit tests can drive the
    /// parser directly with an in-memory line sequence (`URLSession.bytes(for:)`
    /// does not cooperate with `URLProtocol` stubs on Swift 6.2, making
    /// higher-level HTTP mocking brittle).
    internal static func parseSSELines<S: AsyncSequence & Sendable>(
        _ lines: S
    ) -> AsyncThrowingStream<JSONObject, Error> where S.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payloadStr = String(line.dropFirst(6))
                        if payloadStr == "[DONE]" { continue }
                        if payloadStr.isEmpty { continue }
                        do {
                            let event = try JSONDecoder().decode(JSONObject.self, from: Data(payloadStr.utf8))
                            continuation.yield(event)
                        } catch {
                            // Skip malformed individual events so the rest of the stream continues.
                            fputs("parseSSELines: skipping malformed event line: \(payloadStr.prefix(120))\n", stderr)
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Wire consumer cancellation back to the upstream task so
            // URLSession.bytes automatically drops the connection.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Collect-all shim (backward-compatible public API)

    /// Collects all SSE events from `streamEvents` into an array.
    /// Internally uses the same HTTP request construction and parsing as
    /// `streamEvents`, so both code paths share a single implementation.
    public func perform(
        request payload: JSONObject,
        credentials: SubscriptionCredentials
    ) async throws -> [JSONObject] {
        var events: [JSONObject] = []
        let stream = try await streamEvents(request: payload, credentials: credentials)
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Private helpers

    /// Constructs the URLRequest for /responses, shared by both `perform` and
    /// `streamEvents`.
    private nonisolated func makeRequest(
        payload: JSONObject,
        credentials: SubscriptionCredentials
    ) throws -> URLRequest {
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

        return request
    }
}
