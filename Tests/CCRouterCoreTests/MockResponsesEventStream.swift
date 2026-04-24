import Foundation
@testable import CCRouterCore

// MARK: - MockResponsesEventStream (test helpers)

/// Produces canned AsyncThrowingStream<JSONObject> sequences that mirror the
/// validated upstream SSE event shapes documented in docs/scheme3/08 §4.2.
enum MockResponsesEventStream {

    // MARK: - textOnlyTurn

    /// A complete single-pass turn producing one message block with incremental
    /// text deltas followed by response.completed.
    ///
    /// Event sequence per docs/scheme3/08 §4.2:
    ///   response.created → response.output_item.added → response.content_part.added →
    ///   response.output_text.delta (×deltaDelays.count) → response.output_text.done →
    ///   response.content_part.done → response.output_item.done → response.completed
    static func textOnlyTurn(
        text: String,
        deltaDelays: [Duration] = [],
        totalInputTokens: Int = 10,
        totalOutputTokens: Int = 5
    ) -> AsyncThrowingStream<JSONObject, Error> {
        let deltas: [String]
        if text.isEmpty {
            deltas = []
        } else {
            // Split the text into roughly equal delta-sized chunks.
            let chunkCount = max(1, deltaDelays.count == 0 ? 3 : deltaDelays.count)
            let charsPerDelta = max(1, text.count / chunkCount)
            deltas = stride(from: 0, to: text.count, by: charsPerDelta).map { start in
                let end = min(start + charsPerDelta, text.count)
                return String(text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)])
            }
        }

        let clock = ContinuousClock()
        let startTime = clock.now

        return AsyncThrowingStream<JSONObject, Error> { continuation in
            Task {
                do {
                    // response.created
                    try await delay(for: 0, clock: clock, start: startTime, deltas: deltaDelays, total: deltas.count)
                    continuation.yield(JSONObject.from(["type": .string("response.created")]))

                    // response.output_item.added (message item)
                    try await delay(for: 0, clock: clock, start: startTime, deltas: deltaDelays, total: deltas.count)
                    continuation.yield(JSONObject.from([
                        "type": .string("response.output_item.added"),
                        "item": .object(JSONObject.from([
                            "type": .string("message"),
                            "id": .string("msg_\(UUID().uuidString.prefix(8))"),
                        ])),
                    ]))

                    // response.content_part.added
                    try await delay(for: 0, clock: clock, start: startTime, deltas: deltaDelays, total: deltas.count)
                    continuation.yield(JSONObject.from([
                        "type": .string("response.content_part.added"),
                        "output_index": .number(0),
                        "content_index": .number(0),
                        "part": .object(JSONObject.from([
                            "type": .string("output_text"),
                            "text": .string(""),
                        ])),
                    ]))

                    // response.output_text.delta (×N)
                    for (i, delta) in deltas.enumerated() {
                        try await delay(for: i, clock: clock, start: startTime, deltas: deltaDelays, total: deltas.count)
                        continuation.yield(JSONObject.from([
                            "type": .string("response.output_text.delta"),
                            "output_index": .number(0),
                            "content_index": .number(0),
                            "delta": .string(delta),
                        ]))
                    }

                    // response.output_text.done
                    try await delay(for: deltas.count, clock: clock, start: startTime, deltas: deltaDelays, total: deltas.count)
                    continuation.yield(JSONObject.from([
                        "type": .string("response.output_text.done"),
                        "output_index": .number(0),
                        "content_index": .number(0),
                    ]))

                    // response.content_part.done
                    try await delay(for: deltas.count, clock: clock, start: startTime, deltas: deltaDelays, total: deltas.count)
                    continuation.yield(JSONObject.from([
                        "type": .string("response.content_part.done"),
                        "output_index": .number(0),
                        "content_index": .number(0),
                    ]))

                    // response.output_item.done
                    try await delay(for: deltas.count, clock: clock, start: startTime, deltas: deltaDelays, total: deltas.count)
                    continuation.yield(JSONObject.from([
                        "type": .string("response.output_item.done"),
                        "output_index": .number(0),
                        "item": .object(JSONObject.from([
                            "type": .string("message"),
                            "id": .string("msg_\(UUID().uuidString.prefix(8))"),
                            "content": .array([.object(JSONObject.from([
                                "type": .string("output_text"),
                                "text": .string(text),
                            ]))]),
                        ])),
                    ]))

                    // response.completed
                    try await delay(for: deltas.count, clock: clock, start: startTime, deltas: deltaDelays, total: deltas.count)
                    continuation.yield(JSONObject.from([
                        "type": .string("response.completed"),
                        "response": .object(JSONObject.from([
                            "id": .string("resp_\(UUID().uuidString.prefix(8))"),
                            "usage": .object(JSONObject.from([
                                "input_tokens": .number(Double(totalInputTokens)),
                                "output_tokens": .number(Double(totalOutputTokens)),
                            ])),
                        ])),
                    ]))

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - toolUseTurn

    /// A turn that produces a function_call (non-advisor) after optional leading text.
    ///
    /// Sequence: response.created → output_item.added(message) → content_part.added →
    ///           text deltas (optional) → output_text.done → content_part.done →
    ///           output_item.added(function_call) → output_item.done(function_call) →
    ///           [output_item.done(message)] → response.completed
    static func toolUseTurn(
        textBefore: String?,
        toolName: String,
        callID: String,
        argumentsJSON: String
    ) -> AsyncThrowingStream<JSONObject, Error> {
        let textDeltas: [String]
        if let text = textBefore, !text.isEmpty {
            textDeltas = stride(from: 0, to: text.count, by: max(1, text.count / 3)).map { start in
                let end = min(start + max(1, text.count / 3), text.count)
                return String(text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)])
            }
        } else {
            textDeltas = []
        }

        let hasText = !textDeltas.isEmpty

        return AsyncThrowingStream<JSONObject, Error> { continuation in
            Task {
                continuation.yield(JSONObject.from(["type": .string("response.created")]))

                // message item (with optional text)
                if hasText {
                    continuation.yield(JSONObject.from([
                        "type": .string("response.output_item.added"),
                        "output_index": .number(0),
                        "item": .object(JSONObject.from([
                            "type": .string("message"),
                            "id": .string("msg_1"),
                        ])),
                    ]))
                    continuation.yield(JSONObject.from([
                        "type": .string("response.content_part.added"),
                        "output_index": .number(0),
                        "content_index": .number(0),
                        "part": .object(JSONObject.from(["type": .string("output_text"), "text": .string("")])),
                    ]))
                    for delta in textDeltas {
                        continuation.yield(JSONObject.from([
                            "type": .string("response.output_text.delta"),
                            "output_index": .number(0),
                            "content_index": .number(0),
                            "delta": .string(delta),
                        ]))
                    }
                    continuation.yield(JSONObject.from([
                        "type": .string("response.output_text.done"),
                        "output_index": .number(0),
                        "content_index": .number(0),
                    ]))
                    continuation.yield(JSONObject.from([
                        "type": .string("response.content_part.done"),
                        "output_index": .number(0),
                        "content_index": .number(0),
                    ]))
                    // finish message item
                    continuation.yield(JSONObject.from([
                        "type": .string("response.output_item.done"),
                        "output_index": .number(0),
                        "item": .object(JSONObject.from([
                            "type": .string("message"),
                            "id": .string("msg_1"),
                            "content": .array([.object(JSONObject.from(["type": .string("output_text"), "text": .string(textBefore ?? "")]))]),
                        ])),
                    ]))
                }

                // function_call item — real upstream uses `call_id` for tool match;
                // `id` (if present) is the item's tracing id and is distinct.
                let functionCallItem = JSONObject.from([
                    "type": .string("function_call"),
                    "id": .string("fc_\(callID)"),
                    "call_id": .string(callID),
                    "name": .string(toolName),
                    "arguments": .string(argumentsJSON),
                ])
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "output_index": .number(hasText ? 1 : 0),
                    "item": .object(functionCallItem),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.done"),
                    "output_index": .number(hasText ? 1 : 0),
                    "item": .object(functionCallItem),
                ]))

                // response.completed
                continuation.yield(JSONObject.from([
                    "type": .string("response.completed"),
                    "response": .object(JSONObject.from([
                        "id": .string("resp_1"),
                        "usage": .object(JSONObject.from([
                            "input_tokens": .number(10),
                            "output_tokens": .number(5),
                        ])),
                    ])),
                ]))

                continuation.finish()
            }
        }
    }

    // MARK: - advisorTurn

    /// A turn that yields a function_call(name="advisor") followed by text.
    /// Returns (firstStream, secondStream).
    ///
    /// The second stream contains the final text reply.
    static func advisorTurn(
        firstPassText: String?,
        advisorCallID: String,
        finalPassText: String
    ) -> (first: AsyncThrowingStream<JSONObject, Error>, second: AsyncThrowingStream<JSONObject, Error>) {
        let firstStream = toolUseTurn(
            textBefore: firstPassText,
            toolName: "advisor",
            callID: advisorCallID,
            argumentsJSON: "{}"
        )
        let secondStream = textOnlyTurn(text: finalPassText)
        return (first: firstStream, second: secondStream)
    }

    // MARK: - webSearchTurn

    /// A turn that produces a native /responses web_search_call followed by text.
    static func webSearchTurn(
        callID: String,
        query: String,
        sourceURL: String,
        sourceTitle: String,
        finalText: String
    ) -> AsyncThrowingStream<JSONObject, Error> {
        AsyncThrowingStream<JSONObject, Error> { continuation in
            Task {
                continuation.yield(JSONObject.from(["type": .string("response.created")]))

                let searchItem = JSONObject.from([
                    "type": .string("web_search_call"),
                    "id": .string(callID),
                    "status": .string("completed"),
                    "action": .object(JSONObject.from([
                        "type": .string("search"),
                        "query": .string(query),
                        "queries": .array([.string(query)]),
                        "sources": .array([
                            .object(JSONObject.from([
                                "type": .string("url"),
                                "url": .string(sourceURL),
                                "title": .string(sourceTitle),
                            ])),
                        ]),
                    ])),
                ])
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "output_index": .number(0),
                    "item": .object(JSONObject.from([
                        "type": .string("web_search_call"),
                        "id": .string(callID),
                        "status": .string("in_progress"),
                    ])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.done"),
                    "output_index": .number(0),
                    "item": .object(searchItem),
                ]))

                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "output_index": .number(1),
                    "item": .object(JSONObject.from([
                        "type": .string("message"),
                        "id": .string("msg_web_search_1"),
                    ])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.added"),
                    "output_index": .number(1),
                    "content_index": .number(0),
                    "part": .object(JSONObject.from([
                        "type": .string("output_text"),
                        "text": .string(""),
                    ])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.delta"),
                    "output_index": .number(1),
                    "content_index": .number(0),
                    "delta": .string(finalText),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_text.done"),
                    "output_index": .number(1),
                    "content_index": .number(0),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.done"),
                    "output_index": .number(1),
                    "content_index": .number(0),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.done"),
                    "output_index": .number(1),
                    "item": .object(JSONObject.from([
                        "type": .string("message"),
                        "id": .string("msg_web_search_1"),
                        "content": .array([
                            .object(JSONObject.from([
                                "type": .string("output_text"),
                                "text": .string(finalText),
                            ])),
                        ]),
                    ])),
                ]))

                continuation.yield(JSONObject.from([
                    "type": .string("response.completed"),
                    "response": .object(JSONObject.from([
                        "id": .string("resp_web_search_1"),
                        "usage": .object(JSONObject.from([
                            "input_tokens": .number(10),
                            "output_tokens": .number(5),
                        ])),
                    ])),
                ]))

                continuation.finish()
            }
        }
    }

    // MARK: - textThenError

    /// A stream that yields some text deltas then throws the given error.
    static func textThenError(
        partialText: String,
        error: Error
    ) -> AsyncThrowingStream<JSONObject, Error> {
        let deltas = stride(from: 0, to: partialText.count, by: max(1, partialText.count / 3)).map { start in
            let end = min(start + max(1, partialText.count / 3), partialText.count)
            return String(partialText[partialText.index(partialText.startIndex, offsetBy: start)..<partialText.index(partialText.startIndex, offsetBy: end)])
        }

        return AsyncThrowingStream<JSONObject, Error> { continuation in
            Task {
                continuation.yield(JSONObject.from(["type": .string("response.created")]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.output_item.added"),
                    "output_index": .number(0),
                    "item": .object(JSONObject.from(["type": .string("message"), "id": .string("msg_1")])),
                ]))
                continuation.yield(JSONObject.from([
                    "type": .string("response.content_part.added"),
                    "output_index": .number(0),
                    "content_index": .number(0),
                    "part": .object(JSONObject.from(["type": .string("output_text"), "text": .string("")])),
                ]))
                for delta in deltas {
                    continuation.yield(JSONObject.from([
                        "type": .string("response.output_text.delta"),
                        "output_index": .number(0),
                        "content_index": .number(0),
                        "delta": .string(delta),
                    ]))
                }
                // Throw mid-stream — simulates upstream failure.
                continuation.finish(throwing: error)
            }
        }
    }

    /// Waits until the cumulative delay for event `eventIndex` has elapsed.
    /// Events with index < deltaDelays.count use the configured delay; others are immediate.
    private static func delay(
        for eventIndex: Int,
        clock: ContinuousClock,
        start: ContinuousClock.Instant,
        deltas: [Duration],
        total: Int
    ) async throws {
        if eventIndex < deltas.count {
            try await clock.sleep(for: deltas[eventIndex])
        }
    }
}

// MARK: - MockResponsesClient

/// A fake ResponsesStreamingClient that dequeues pre-supplied streams / event arrays
/// in FIFO order, suitable for driving AnthropicBridge tests.
actor MockResponsesClient: ResponsesStreamingClient {

    private var streamQueue: [AsyncThrowingStream<JSONObject, Error>]
    private var performQueue: [[JSONObject]]
    /// Records every request payload passed to streamEvents / perform.
    private(set) var capturedRequests: [JSONObject] = []
    /// Queue of errors to throw on successive streamEvents calls (FIFO).
    private var _errorQueue: [Error] = []

    init(streams: [AsyncThrowingStream<JSONObject, Error>], performResults: [[JSONObject]] = []) {
        self.streamQueue = streams
        self.performQueue = performResults
        self.capturedRequests = []
        self._errorQueue = []
    }

    /// Appends an error to the queue; each streamEvents call dequeues one.
    func enqueueError(_ error: Error) {
        _errorQueue.append(error)
    }

    func streamEvents(request: JSONObject, credentials: SubscriptionCredentials) async throws -> AsyncThrowingStream<JSONObject, Error> {
        capturedRequests.append(request)
        if !_errorQueue.isEmpty {
            throw _errorQueue.removeFirst()
        }
        guard !streamQueue.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        return streamQueue.removeFirst()
    }

    func perform(request: JSONObject, credentials: SubscriptionCredentials) async throws -> [JSONObject] {
        capturedRequests.append(request)
        guard !performQueue.isEmpty else { return [] }
        return performQueue.removeFirst()
    }
}

// MARK: - InMemoryBodyWriter

/// An HTTPBodyWriter that records every write as a timestamped Data chunk for
/// test assertions.
///
/// Each write call appends a chunk of raw bytes to the internal buffer.
/// The chunked-transfer encoding (`NWConnectionBodyWriter`) uses `<hex>\r\n`
/// framing, which adds a `\r` before each `\n\n` SSE record delimiter.  The
/// `parseSSEFrames()` method accounts for this by stripping the trailing `\r`
/// from each record before parsing.
actor InMemoryBodyWriter: HTTPBodyWriter {
    private(set) var chunks: [(timestamp: ContinuousClock.Instant, data: Data)] = []
    private(set) var finished = false

    func write(_ chunk: Data) async throws {
        chunks.append((.now, chunk))
    }

    func finish() async throws {
        finished = true
    }

    /// Raw bytes from all write() calls concatenated in order.
    var concatenated: Data {
        chunks.reduce(Data()) { $0 + $1.data }
    }

    /// All chunks concatenated as a UTF-8 string.
    var concatenatedString: String {
        String(data: concatenated, encoding: .utf8) ?? "<non-utf8>"
    }

    /// Timestamp of the first chunk whose UTF-8 payload contains `needle`.
    func firstChunkTimestamp(containing needle: String) -> ContinuousClock.Instant? {
        for chunk in chunks {
            guard let string = String(data: chunk.data, encoding: .utf8) else { continue }
            if string.contains(needle) {
                return chunk.timestamp
            }
        }
        return nil
    }

    /// Parses the raw chunked-encoding bytes into SSE frames.
    ///
    /// The chunked encoding writes each frame as: `<hex>\r\n<raw-bytes>\r\n`.
    /// Within `<raw-bytes>`, SSE lines use `\n` line endings, so the CRLF `\r\n`
    /// chunk terminator creates a `\r\n\n` sequence at each record boundary.
    /// After splitting on `\n\n` the last line of each record still has a trailing `\r`.
    /// This function strips that `\r` before parsing each line.
    func parseSSEFrames() -> [(event: String, data: JSONObject)] {
        let bodyString = concatenatedString
        var results: [(event: String, data: JSONObject)] = []

        // Split records on the SSE double-newline (preserving trailing \r on the last line).
        let records = bodyString.components(separatedBy: "\n\n")
        for record in records {
            // Strip trailing \r from the record (it's the chunk terminator before next chunk header).
            let trimmedRecord = record.hasSuffix("\r") ? String(record.dropLast()) : record
            guard !trimmedRecord.isEmpty else { continue }

            // Parse each line (each line ends with \n, but we strip \r\n).
            let lines = trimmedRecord.components(separatedBy: "\n")
            var eventType = ""
            var dataString = ""

            for line in lines {
                // Strip trailing \r (from CRLF).
                let stripped = line.hasSuffix("\r") ? String(line.dropLast()) : line
                if stripped.hasPrefix("event:") {
                    eventType = String(stripped.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if stripped.hasPrefix("data:") {
                    dataString = String(stripped.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
            }

            guard !dataString.isEmpty else { continue }
            guard let jsonData = dataString.data(using: .utf8),
                  let json = try? JSONDecoder().decode(JSONObject.self, from: jsonData) else {
                continue
            }
            results.append((event: eventType, data: json))
        }
        return results
    }
}

// MARK: - MockSessionLoader

/// A SubscriptionSessionProviding fake backed by fixed test credentials.
/// Refactored to `final class` so it can track mutable state (refresh call count
/// and configurable refresh outcomes) needed by Task 5's retry-on-401 tests.
/// DP-003 Chosen: A — NSLock protects mutable fields; 20+ existing call sites
/// with the same `init(credentials:)` signature are unaffected.
final class MockSessionLoader: SubscriptionSessionProviding, @unchecked Sendable {
    let credentials: SubscriptionCredentials
    private let lock = NSLock()
    private var _refreshedCredentials: SubscriptionCredentials?
    private var _refreshError: Error?
    private var _refreshAndReloadCallCount: Int = 0

    var refreshAndReloadCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _refreshAndReloadCallCount
    }

    init(
        credentials: SubscriptionCredentials,
        refreshedCredentials: SubscriptionCredentials? = nil,
        refreshError: Error? = nil
    ) {
        self.credentials = credentials
        self._refreshedCredentials = refreshedCredentials
        self._refreshError = refreshError
    }

    /// Convenience init with default credentials (preserves existing call sites).
    convenience init() {
        self.init(
            credentials: SubscriptionCredentials(
                accessToken: "test-token",
                accountID: "test-account"
            )
        )
    }

    func loadCurrent() async throws -> SubscriptionCredentials { credentials }

    private func tickAndSnapshot() -> (Error?, SubscriptionCredentials?) {
        lock.lock()
        defer { lock.unlock() }
        _refreshAndReloadCallCount += 1
        return (_refreshError, _refreshedCredentials)
    }

    func refreshAndReload() async throws -> SubscriptionCredentials {
        let (error, cred) = tickAndSnapshot()
        if let error { throw error }
        return cred ?? credentials
    }
}
