import Foundation
import Testing
@testable import CCRouterCore

struct TraceLoggerDiagnosticsTests {
    @Test
    func logCreatesMissingParentDirectoryAndRecentLinesCanReadIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let traceURL = root
            .appendingPathComponent("nested/trace.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = TraceLogger(fileURL: traceURL)

        await logger.log(
            JSONObject.from([
                "stage": .string("anthropic_in"),
                "session_id": .string("session-create-dir"),
            ])
        )

        let recentLines = await logger.recentLines(limit: 5)

        #expect(FileManager.default.fileExists(atPath: traceURL.path))
        #expect(recentLines.count == 1)
        #expect(recentLines[0].contains("\"stage\":\"anthropic_in\""))
    }

    @Test
    func buildsConnectorSummaryFromRecentEvents() async throws {
        let traceURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-trace.jsonl")
        defer { try? FileManager.default.removeItem(at: traceURL) }

        let logger = TraceLogger(fileURL: traceURL)
        let baseTimestamp = Int(Date().timeIntervalSince1970 * 1000)

        await logger.log(
            JSONObject.from([
                "logged_at_unix_ms": .number(Double(baseTimestamp)),
                "stage": .string("anthropic_in"),
                "session_id": .string("session-1"),
            ])
        )
        await logger.log(
            JSONObject.from([
                "logged_at_unix_ms": .number(Double(baseTimestamp + 180)),
                "stage": .string("responses_in"),
                "function_calls": .array([
                    .object(JSONObject.from([
                        "name": .string("mcp__plugin_Notion_notion__authenticate"),
                        "call_id": .string("call-1"),
                    ])),
                    .object(JSONObject.from([
                        "name": .string("Bash"),
                        "call_id": .string("call-2"),
                    ])),
                ]),
            ])
        )
        await logger.log(
            JSONObject.from([
                "logged_at_unix_ms": .number(Double(baseTimestamp + 240)),
                "stage": .string("anthropic_out"),
                "session_id": .string("session-1"),
                "status_code": .number(200),
                "result": .string("initial"),
                "duration_ms": .number(240),
            ])
        )
        await logger.log(
            JSONObject.from([
                "logged_at_unix_ms": .number(Double(baseTimestamp + 300)),
                "stage": .string("anthropic_in"),
                "session_id": .string("session-2"),
            ])
        )
        await logger.log(
            JSONObject.from([
                "logged_at_unix_ms": .number(Double(baseTimestamp + 320)),
                "stage": .string("local_auth_reject"),
                "path": .string("/v1/messages"),
            ])
        )

        let diagnostics = await logger.diagnostics(limit: 10)

        #expect(diagnostics.recentStageCounts["responses_in"] == 1)
        #expect(diagnostics.recentStageCounts["local_auth_reject"] == 1)
        #expect(diagnostics.recentFunctionCallNames.contains("Bash"))
        #expect(diagnostics.recentConnectorNames.contains("mcp__plugin_Notion_notion__authenticate"))
        #expect(diagnostics.recentRejectedPaths.contains("/v1/messages"))
        #expect(diagnostics.recentRequestCount == 2)
        #expect(diagnostics.recentSuccessCount == 1)
        #expect(diagnostics.recentFailureCount == 1)
        #expect(diagnostics.lastRequestOutcome == "auth_rejected")
        #expect(diagnostics.lastLatencyMilliseconds == 240)
        #expect(diagnostics.p50LatencyMilliseconds == 240)
        #expect(diagnostics.p95LatencyMilliseconds == 240)
        #expect(diagnostics.requestsPerMinute > 0)
        #expect(diagnostics.recentErrorReasons.contains("Local auth rejected: /v1/messages"))
    }
}
