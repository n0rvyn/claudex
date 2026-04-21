import Foundation
import Testing
@testable import CCRouterCore

struct TraceLoggerDiagnosticsTests {
    @Test
    func buildsConnectorSummaryFromRecentEvents() async throws {
        let traceURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-trace.jsonl")
        defer { try? FileManager.default.removeItem(at: traceURL) }

        let logger = TraceLogger(fileURL: traceURL)

        await logger.log(
            JSONObject.from([
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
    }
}
