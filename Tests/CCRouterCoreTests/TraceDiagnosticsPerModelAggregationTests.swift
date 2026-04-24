import Foundation
@testable import CCRouterCore
import Testing

// MARK: - TraceDiagnosticsPerModelAggregationTests

/// Tests that TraceLogger.diagnostics(limit:) aggregates per-Claude-model metrics
/// correctly from the trace log: p50/p95 latency, success/failure counts,
/// lastUpstreamModel, errorReasons.
struct TraceDiagnosticsPerModelAggregationTests {

    private static func makeIsolatedTraceFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TraceDiagnosticsPerModelTest-\(UUID().uuidString).jsonl")
    }

    // MARK: - Trace line builders

    /// Builds an anthropic_in trace line for the given session + model.
    private static func anthroIn(sessionID: String, claudeModel: String, timestamp: Int) -> JSONObject {
        JSONObject.from([
            "stage": .string("anthropic_in"),
            "session_id": .string(sessionID),
            "claude_model": .string(claudeModel),
            "logged_at_unix_ms": .number(Double(timestamp)),
        ])
    }

    /// Builds an anthropic_out trace line for the given session + model + result.
    private static func anthroOut(
        sessionID: String,
        claudeModel: String,
        statusCode: Int,
        durationMs: Int,
        upstreamModel: String?,
        errorMessage: String?
    ) -> JSONObject {
        var obj: [String: JSONValue] = [
            "stage": .string("anthropic_out"),
            "session_id": .string(sessionID),
            "claude_model": .string(claudeModel),
            "status_code": .number(Double(statusCode)),
            "result": .string(statusCode >= 400 ? "error" : "success"),
            "duration_ms": .number(Double(durationMs)),
            "logged_at_unix_ms": .number(0),
        ]
        if let upstreamModel {
            obj["upstream_model"] = .string(upstreamModel)
        }
        if let errorMessage {
            obj["error_message"] = .string(errorMessage)
        }
        return JSONObject.from(obj)
    }

    /// Writes trace lines to a file and returns the URL.
    private static func writeTraceLines(_ lines: [JSONObject]) throws -> URL {
        let traceURL = Self.makeIsolatedTraceFileURL()
        let encoder = JSONEncoder()
        let text = lines.compactMap { line -> String? in
            guard let data = try? encoder.encode(line) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n") + "\n"
        try text.write(to: traceURL, atomically: true, encoding: .utf8)
        return traceURL
    }

    // MARK: - Tests

    /// Verify: 3 successful requests for opus/sonnet/haiku → each model has count 1, success 1.
    @Test
    func threeModelsEachHaveCountOneSuccessOne() async throws {
        let ts = 1_700_000_000_000
        let lines: [JSONObject] = [
            Self.anthroIn(sessionID: "s1", claudeModel: "claude-opus-4-7", timestamp: ts),
            Self.anthroOut(sessionID: "s1", claudeModel: "claude-opus-4-7", statusCode: 200, durationMs: 100, upstreamModel: "gpt-5.4", errorMessage: nil),
            Self.anthroIn(sessionID: "s2", claudeModel: "claude-sonnet-4-6", timestamp: ts + 10),
            Self.anthroOut(sessionID: "s2", claudeModel: "claude-sonnet-4-6", statusCode: 200, durationMs: 200, upstreamModel: "gpt-5.4", errorMessage: nil),
            Self.anthroIn(sessionID: "s3", claudeModel: "claude-haiku-4-5-20251001", timestamp: ts + 20),
            Self.anthroOut(sessionID: "s3", claudeModel: "claude-haiku-4-5-20251001", statusCode: 200, durationMs: 150, upstreamModel: "gpt-5.3-codex-spark", errorMessage: nil),
        ]
        let traceURL = try Self.writeTraceLines(lines)
        defer { try? FileManager.default.removeItem(at: traceURL) }

        let logger = TraceLogger(fileURL: traceURL)
        let diagnostics = await logger.diagnostics(limit: 100)

        let metrics = diagnostics.perClaudeModelMetrics
        #expect(metrics.count == 3)
        #expect(metrics["claude-opus-4-7"]?.requestCount == 1)
        #expect(metrics["claude-opus-4-7"]?.successCount == 1)
        #expect(metrics["claude-opus-4-7"]?.failureCount == 0)
        #expect(metrics["claude-sonnet-4-6"]?.requestCount == 1)
        #expect(metrics["claude-sonnet-4-6"]?.successCount == 1)
        #expect(metrics["claude-haiku-4-5-20251001"]?.requestCount == 1)
        #expect(metrics["claude-haiku-4-5-20251001"]?.successCount == 1)
    }

    /// Verify: opus has 2 successes + 1 failure; error reasons captured.
    @Test
    func mixedSuccessFailureAggregatesCorrectly() async throws {
        let ts = 1_700_000_000_000
        let lines: [JSONObject] = [
            Self.anthroIn(sessionID: "o1", claudeModel: "claude-opus-4-7", timestamp: ts),
            Self.anthroOut(sessionID: "o1", claudeModel: "claude-opus-4-7", statusCode: 200, durationMs: 100, upstreamModel: "gpt-5.4", errorMessage: nil),
            Self.anthroIn(sessionID: "o2", claudeModel: "claude-opus-4-7", timestamp: ts + 10),
            Self.anthroOut(sessionID: "o2", claudeModel: "claude-opus-4-7", statusCode: 200, durationMs: 200, upstreamModel: "gpt-5.4", errorMessage: nil),
            Self.anthroIn(sessionID: "o3", claudeModel: "claude-opus-4-7", timestamp: ts + 20),
            Self.anthroOut(sessionID: "o3", claudeModel: "claude-opus-4-7", statusCode: 503, durationMs: 300, upstreamModel: nil, errorMessage: "upstream 503"),
        ]
        let traceURL = try Self.writeTraceLines(lines)
        defer { try? FileManager.default.removeItem(at: traceURL) }

        let logger = TraceLogger(fileURL: traceURL)
        let diagnostics = await logger.diagnostics(limit: 100)

        let opus = diagnostics.perClaudeModelMetrics["claude-opus-4-7"]
        #expect(opus?.requestCount == 3)
        #expect(opus?.successCount == 2)
        #expect(opus?.failureCount == 1)
        #expect(opus?.recentErrorReasons.first == "upstream 503")
    }

    /// Verify: p50 and p95 latency computed correctly from 5 events.
    @Test
    func p50AndP95ComputedCorrectly() async throws {
        let ts = 1_700_000_000_000
        var lines: [JSONObject] = []
        for i in 0..<5 {
            let ms = (i + 1) * 100  // 100, 200, 300, 400, 500
            lines.append(Self.anthroIn(sessionID: "s\(i)", claudeModel: "claude-opus-4-7", timestamp: ts + Int(i) * 10))
            lines.append(Self.anthroOut(sessionID: "s\(i)", claudeModel: "claude-opus-4-7", statusCode: 200, durationMs: ms, upstreamModel: "gpt-5.4", errorMessage: nil))
        }
        let traceURL = try Self.writeTraceLines(lines)
        defer { try? FileManager.default.removeItem(at: traceURL) }

        let logger = TraceLogger(fileURL: traceURL)
        let diagnostics = await logger.diagnostics(limit: 100)

        let opus = diagnostics.perClaudeModelMetrics["claude-opus-4-7"]
        #expect(opus?.p50LatencyMilliseconds == 300)   // sorted [100,200,300,400,500], index 2
        #expect(opus?.p95LatencyMilliseconds == 500)  // index 4 (95% of 4 rounded)
    }

    /// Verify: lastUpstreamModel is the most recent upstream model.
    @Test
    func lastUpstreamModelIsMostRecent() async throws {
        let ts = 1_700_000_000_000
        let lines: [JSONObject] = [
            Self.anthroIn(sessionID: "s1", claudeModel: "claude-opus-4-7", timestamp: ts),
            Self.anthroOut(sessionID: "s1", claudeModel: "claude-opus-4-7", statusCode: 200, durationMs: 100, upstreamModel: "gpt-5.4", errorMessage: nil),
            Self.anthroIn(sessionID: "s2", claudeModel: "claude-opus-4-7", timestamp: ts + 10),
            Self.anthroOut(sessionID: "s2", claudeModel: "claude-opus-4-7", statusCode: 200, durationMs: 200, upstreamModel: "gpt-5.3-codex-spark", errorMessage: nil),
        ]
        let traceURL = try Self.writeTraceLines(lines)
        defer { try? FileManager.default.removeItem(at: traceURL) }

        let logger = TraceLogger(fileURL: traceURL)
        let diagnostics = await logger.diagnostics(limit: 100)

        let opus = diagnostics.perClaudeModelMetrics["claude-opus-4-7"]
        #expect(opus?.lastUpstreamModel == "gpt-5.3-codex-spark")
    }

    /// Verify: empty trace → perClaudeModelMetrics == [:].
    @Test
    func emptyTraceHasNoPerModelMetrics() async throws {
        let traceURL = Self.makeIsolatedTraceFileURL()
        defer { try? FileManager.default.removeItem(at: traceURL) }
        try "".write(to: traceURL, atomically: true, encoding: .utf8)

        let logger = TraceLogger(fileURL: traceURL)
        let diagnostics = await logger.diagnostics(limit: 100)

        #expect(diagnostics.perClaudeModelMetrics.isEmpty)
        #expect(diagnostics.recentRequestCount == 0)
    }
}
