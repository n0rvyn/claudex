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
    private var activeRequests: [UUID: URLSessionTask] = [:]

    public init(endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration, delegate: SIWCNoRedirects(), delegateQueue: nil)
        self.endpoint = endpoint
    }

    /// Constructs a ResponsesClient with a custom URLSession — intended for
    /// test-only injection of URLProtocol stubs (e.g. MockSSEProtocol).
    public init(session: URLSession, endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!) {
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
        try await streamEvents(request: payload, credentials: credentials, requestID: UUID())
    }
    public func cancelRequest(_ requestID: UUID) {
        activeRequests.removeValue(forKey: requestID)?.cancel()
    }
    private func removeRequest(_ requestID: UUID) { activeRequests.removeValue(forKey: requestID) }
    public func streamEvents(request payload: JSONObject, credentials: SubscriptionCredentials, requestID: UUID) async throws -> AsyncThrowingStream<JSONObject, Error> {
        let request = try makeRequest(payload: payload, credentials: credentials)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResponsesHTTPError(statusCode: -1, body: "Missing HTTPURLResponse")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyString = await Self.drainErrorBody(bytes)
            bytes.task.cancel()
            throw ResponsesHTTPError(statusCode: httpResponse.statusCode, body: bodyString)
        }

        let upstream = bytes.task
        activeRequests[requestID] = upstream
        return Self.parseStrictSSEBytes(bytes, onTermination: { [self] in
            upstream.cancel()
            Task { await removeRequest(requestID) }
        })
    }

    /// Foundation AsyncBytes.lines drops empty lines on macOS. SSE frame boundaries
    /// therefore must be decoded from bytes rather than that convenience sequence.
    internal static func parseStrictSSEBytes<S: AsyncSequence & Sendable>(_ bytes: S,
        onTermination: @escaping @Sendable () -> Void = {}) -> AsyncThrowingStream<JSONObject, Error>
        where S.Element == UInt8 {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var buffer = Data()
                var afterCR = false
                var firstLine = true
                func emitLine() throws {
                    guard var line = String(data: buffer, encoding: .utf8) else {
                        throw SIWCError.remote("invalid_sse_utf8")
                    }
                    if firstLine, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
                    firstLine = false
                    buffer.removeAll(keepingCapacity: true)
                    continuation.yield(line)
                }
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 {
                            if !afterCR { try emitLine() }
                            afterCR = false
                        } else if byte == 13 {
                            try emitLine()
                            afterCR = true
                        } else {
                            afterCR = false
                            buffer.append(byte)
                            guard buffer.count <= 16 * 1024 * 1024 else {
                                throw SIWCError.remote("sse_line_too_large")
                            }
                        }
                    }
                    if !buffer.isEmpty { try emitLine() }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return parseStrictSSELines(lines, onTermination: onTermination)
    }

    /// Parse complete SSE frames; malformed JSON and truncated frames fail closed.
    internal static func parseStrictSSELines<S: AsyncSequence & Sendable>(_ lines: S, onTermination: @escaping @Sendable () -> Void = {})
        -> AsyncThrowingStream<JSONObject, Error> where S.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                var dataLines: [String] = []
                do {
                    for try await line in lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                dataLines = []
                                if payload != "[DONE]" {
                                    continuation.yield(try JSONDecoder().decode(JSONObject.self, from: Data(payload.utf8)))
                                }
                            }
                        } else if line.hasPrefix("data:") {
                            var data = String(line.dropFirst(5))
                            if data.hasPrefix(" ") { data.removeFirst() }
                            dataLines.append(data)
                        }
                    }
                    guard dataLines.isEmpty else { throw SIWCError.remote("truncated_sse_frame") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); onTermination() }
        }
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

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = encoded
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Claudex/0.1", forHTTPHeaderField: "user-agent")

        return request
    }
}
