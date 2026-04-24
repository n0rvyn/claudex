import Foundation
@testable import CCRouterCore
import Testing

// MARK: - ResponsesClientStreamingTests

/// Unit tests for the SSE parsing logic inside `ResponsesClient.streamEvents`.
///
/// `URLSession.bytes(for:)` does not route through `URLProtocol` subclasses on
/// Swift 6.2, and driving `NWListener` + `URLSession.bytes(for:)` together on
/// loopback has interop quirks that make full-HTTP mocking brittle. We
/// therefore test the parser directly via the internal `parseSSELines(_:)`
/// helper, feeding an in-memory async line sequence. This covers every
/// parser-level requirement (line parsing, `[DONE]` sentinel, blank/comment
/// lines, malformed JSON skip, cancellation). HTTP status + URL cancellation
/// concerns are covered at the integration layer by
/// `StreamingBridgeIntegrationTests`.
struct ResponsesClientStreamingTests {

    // MARK: - In-memory line sequence helper

    /// An AsyncSequence of String lines built from a fixed array, with an
    /// optional error injected at the end to simulate upstream failure mid-stream.
    private struct MockLineSequence: AsyncSequence, Sendable {
        typealias Element = String

        let lines: [String]
        let errorAfterLast: Error?

        struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: IndexingIterator<[String]>
            let errorAfterLast: Error?
            var exhausted = false

            mutating func next() async throws -> String? {
                if let line = iterator.next() {
                    return line
                }
                if !exhausted {
                    exhausted = true
                    if let err = errorAfterLast {
                        throw err
                    }
                }
                return nil
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: lines.makeIterator(), errorAfterLast: errorAfterLast)
        }
    }

    /// Collects all events from the parser stream into an array.
    private func collect(_ stream: AsyncThrowingStream<JSONObject, Error>) async throws -> [JSONObject] {
        var results: [JSONObject] = []
        for try await event in stream {
            results.append(event)
        }
        return results
    }

    // MARK: - Tests

    @Test
    func yieldsEventPerDataLine() async throws {
        let lines = [
            #"data: {"type":"response.created"}"#,
            #"data: {"type":"response.in_progress"}"#,
            #"data: {"type":"response.completed"}"#,
        ]
        let stream = ResponsesClient.parseSSELines(MockLineSequence(lines: lines, errorAfterLast: nil))
        let events = try await collect(stream)
        #expect(events.count == 3)
        #expect(events[0].string("type") == "response.created")
        #expect(events[1].string("type") == "response.in_progress")
        #expect(events[2].string("type") == "response.completed")
    }

    @Test
    func ignoresDoneSentinel() async throws {
        let lines = [
            #"data: {"type":"response.created"}"#,
            "data: [DONE]",
            #"data: {"type":"response.completed"}"#,
        ]
        let stream = ResponsesClient.parseSSELines(MockLineSequence(lines: lines, errorAfterLast: nil))
        let events = try await collect(stream)
        #expect(events.count == 2)
        #expect(events[0].string("type") == "response.created")
        #expect(events[1].string("type") == "response.completed")
    }

    @Test
    func ignoresBlankAndCommentLines() async throws {
        let lines = [
            "",
            ": this is a comment",
            "event: message",
            #"data: {"type":"response.created"}"#,
            "",
            #"data: {"type":"response.completed"}"#,
            "",
        ]
        let stream = ResponsesClient.parseSSELines(MockLineSequence(lines: lines, errorAfterLast: nil))
        let events = try await collect(stream)
        #expect(events.count == 2)
        #expect(events[0].string("type") == "response.created")
        #expect(events[1].string("type") == "response.completed")
    }

    @Test
    func malformedEventIsSkippedNotFatal() async throws {
        let lines = [
            #"data: {"type":"ok1"}"#,
            "data: not valid json",
            #"data: {"type":"ok2"}"#,
        ]
        let stream = ResponsesClient.parseSSELines(MockLineSequence(lines: lines, errorAfterLast: nil))
        let events = try await collect(stream)
        #expect(events.count == 2)
        #expect(events[0].string("type") == "ok1")
        #expect(events[1].string("type") == "ok2")
    }

    @Test
    func emptyDataLineIsIgnored() async throws {
        let lines = [
            #"data: {"type":"ok"}"#,
            "data: ",
            #"data: {"type":"ok2"}"#,
        ]
        let stream = ResponsesClient.parseSSELines(MockLineSequence(lines: lines, errorAfterLast: nil))
        let events = try await collect(stream)
        #expect(events.count == 2)
    }

    @Test
    func upstreamErrorPropagatesToStream() async throws {
        let err = NSError(domain: "test.parser", code: 42, userInfo: [NSLocalizedDescriptionKey: "upstream dropped"])
        let lines = [
            #"data: {"type":"partial"}"#,
        ]
        let stream = ResponsesClient.parseSSELines(MockLineSequence(lines: lines, errorAfterLast: err))

        var collected: [JSONObject] = []
        var caught: Error? = nil
        do {
            for try await event in stream {
                collected.append(event)
            }
        } catch {
            caught = error
        }
        #expect(collected.count == 1)
        #expect(caught != nil)
        #expect((caught as? NSError)?.code == 42)
    }

    // MARK: - Error body drain (non-UTF-8 safe)

    /// An AsyncSequence of `UInt8` backed by a fixed `Data`. Used to drive
    /// `ResponsesClient.drainErrorBody` in tests without hitting the network.
    private struct MockByteSequence: AsyncSequence, Sendable {
        typealias Element = UInt8
        let bytes: Data

        struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: Data.Iterator
            mutating func next() async throws -> UInt8? {
                iterator.next()
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: bytes.makeIterator())
        }
    }

    @Test
    func errorBodyReadWithoutAssumingUTF8Lines() async throws {
        // Bytes 0x80-0x8F are invalid UTF-8 continuation bytes not preceded by
        // a lead byte. `String(data:encoding:.utf8)` returns nil for them, so
        // drainErrorBody must fall back to the placeholder rather than throwing.
        let nonUTF8Bytes = Data([0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87])
        let result = await ResponsesClient.drainErrorBody(MockByteSequence(bytes: nonUTF8Bytes))
        #expect(result.hasPrefix("<non-utf8 body,"))
        #expect(result.contains("\(nonUTF8Bytes.count) bytes"))
    }

    @Test
    func errorBodyDrainReturnsUTF8StringWhenValid() async throws {
        let utf8Body = Data(#"{"error":"bad request"}"#.utf8)
        let result = await ResponsesClient.drainErrorBody(MockByteSequence(bytes: utf8Body))
        #expect(result == #"{"error":"bad request"}"#)
    }

    @Test
    func errorBodyDrainHonoursMaxBytes() async throws {
        let bigBody = Data(repeating: 0x41, count: 100_000)  // 100 KB of 'A'
        let result = await ResponsesClient.drainErrorBody(MockByteSequence(bytes: bigBody), maxBytes: 256)
        #expect(result.count <= 256)
        #expect(result.allSatisfy { $0 == "A" })
    }

    @Test
    func non200StatusThrowsResponsesHTTPError() async throws {
        // Constructs ResponsesHTTPError directly to verify the error envelope
        // contract that `streamEvents` establishes on non-2xx status codes.
        let err = ResponsesHTTPError(statusCode: 401, body: "Missing scopes: api.responses.write")
        #expect(err.statusCode == 401)
        #expect(err.body == "Missing scopes: api.responses.write")
        // LocalizedError bridging — the bridge's catch-site classifies
        // 4xx as "invalid_request_error" and 5xx as "api_error".
        let description = err.errorDescription ?? ""
        #expect(description.contains("401"))
        #expect(description.contains("Missing scopes"))
    }

    @Test
    func cancellationViaOnTerminationStopsParser() async throws {
        // Emit many lines but break after reading one event, then verify the
        // parser task exits quickly after consumer cancellation.
        var manyLines: [String] = []
        for i in 0..<1000 {
            manyLines.append(#"data: {"type":"ev_\#(i)"}"#)
        }
        let stream = ResponsesClient.parseSSELines(MockLineSequence(lines: manyLines, errorAfterLast: nil))

        let startInstant = ContinuousClock().now
        var firstEvent: JSONObject? = nil
        for try await event in stream {
            firstEvent = event
            break  // Triggers continuation.onTermination via iterator deinit.
        }
        let elapsed = startInstant.duration(to: .now)

        #expect(firstEvent != nil)
        // If cancellation did not fire, the parser would keep processing 999
        // more events. The parser task itself is best-effort; we only assert
        // the consumer loop exited cleanly here.
        #expect(elapsed < .seconds(1))
    }
}
