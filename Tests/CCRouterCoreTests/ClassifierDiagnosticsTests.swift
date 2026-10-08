import Foundation
import Testing
@testable import CCRouterCore

@Suite("Redacted classifier diagnostics")
struct ClassifierDiagnosticsTests {
    @Test func errorCategoriesNeverReturnArbitraryDescriptions() {
        #expect(ClassifierDiagnostics.category(SIWCError.unsupported("SECRET_SENTINEL")) == "unsupported_capability")
        #expect(ClassifierDiagnostics.category(SIWCError.unsupported("Claude Code session identifier is required")) == "missing_session")
        #expect(ClassifierDiagnostics.category(SIWCError.unsupported("disabled thinking cannot be translated")) == "unsupported_thinking")
        #expect(ClassifierDiagnostics.category(CancellationError()) == "cancelled")
    }

    @Test func ingressRedactsUserControlledValues() throws {
        let secret = "SECRET_SENTINEL"
        let body = try JSONSerialization.data(withJSONObject: ["model": secret, "system": secret,
            "messages": [["role": "user", "content": secret]], "tools": [["name": secret]],
            "metadata": ["safeguards_review": secret], "output_config": ["format": ["schema": secret]],
            "thinking": ["type": secret], "stream": true])
        let request = HTTPRequest(method: "POST", path: "/private/" + secret + "?token=" + secret,
            headers: ["authorization": secret, "x-classifier-review": secret, "x-claude-code-session-id": secret], body: body)
        let fields = ClassifierDiagnostics.ingress(request)
        let serialized = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        #expect(!serialized.contains(secret))
        #expect(fields.string("endpoint") == "other_endpoint")
        #expect(fields["review_field_present"] == .bool(true))
        #expect(fields["review_header_present"] == .bool(true))
        #expect(fields["output_format_present"] == .bool(true))
        #expect(fields["session_header_present"] == .bool(true))
    }

    @Test func bufferedErrorPreservesProtocolWithoutLoggingErrorText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try await TraceLogger.$overrideFileURL.withValue(url) {
            let response = try HTTPResponse.json(statusCode: 429, value: ["error": ["type": "rate_limit_error", "message": "SECRET_SENTINEL"]])
            let request = HTTPRequest(method: "POST", path: "/v1/messages", headers: [:], body: Data())
            let observed = await ClassifierDiagnostics.observe(request) { response }
            #expect(observed.statusCode == response.statusCode)
            #expect(observed.headers == response.headers)
            #expect(observed.bodyData == response.bodyData)
            let log = try String(contentsOf: url, encoding: .utf8)
            #expect(!log.contains("SECRET_SENTINEL"))
            #expect(log.contains("rate_limit_error"))
            #expect(log.contains("429"))
        }
    }

    @Test func streamPreservesBytesFinishAndReleaseAndRecordsCompletion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try await TraceLogger.$overrideFileURL.withValue(url) {
            let writer = DiagnosticTestWriter()
            let bytes = Data("event: message_stop\ndata: {\"type\":\"message_stop\",\"safeguards_review\":\"SECRET_SENTINEL\"}\n\n".utf8)
            let response = HTTPResponse(statusCode: 200, reasonPhrase: "OK", headers: ["content-type": "text/event-stream"],
                release: { await writer.released() }, stream: { output in try await output.write(bytes); try await output.finish() })
            let request = HTTPRequest(method: "POST", path: "/v1/messages", headers: [:], body: Data())
            let observed = await ClassifierDiagnostics.observe(request) { response }
            guard case .stream(let producer) = observed.body else { Issue.record("Expected stream"); return }
            try await producer(writer)
            await observed.release?()
            #expect(await writer.data == bytes)
            #expect(await writer.finished)
            #expect(await writer.didRelease)
            let log = try String(contentsOf: url, encoding: .utf8)
            #expect(!log.contains("SECRET_SENTINEL"))
            #expect(log.contains("stream_review_fields"))
            #expect(log.contains("message_stop_seen"))
        }
    }

    @Test func thrownStreamErrorRemainsAnErrorAndRedactsDescription() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try await TraceLogger.$overrideFileURL.withValue(url) {
            let request = HTTPRequest(method: "POST", path: "/v1/messages", headers: [:], body: Data())
            let response = HTTPResponse(statusCode: 200, reasonPhrase: "OK", stream: { _ in
                throw ResponsesHTTPError(statusCode: 503, body: "SECRET_SENTINEL")
            })
            let observed = await ClassifierDiagnostics.observe(request) { response }
            guard case .stream(let producer) = observed.body else { Issue.record("Expected stream"); return }
            do { try await producer(DiagnosticTestWriter()); Issue.record("Expected original error") }
            catch let error as ResponsesHTTPError { #expect(error.statusCode == 503); #expect(error.body == "SECRET_SENTINEL") }
            let log = try String(contentsOf: url, encoding: .utf8)
            #expect(!log.contains("SECRET_SENTINEL"))
            #expect(log.contains("stream_failed"))
            #expect(log.contains("upstream_http"))
        }
    }
}

private actor DiagnosticTestWriter: HTTPBodyWriter {
    var data = Data()
    var finished = false
    var didRelease = false
    func write(_ chunk: Data) { data.append(chunk) }
    func finish() { finished = true }
    func released() { didRelease = true }
}
