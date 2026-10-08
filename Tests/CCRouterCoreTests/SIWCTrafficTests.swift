import Foundation
import Testing
@testable import CCRouterCore

struct SIWCTrafficTests {
    @Test func windowExpiresAndMetadataSurvivesRestartWithoutDoubleCounting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let traffic = SIWCTraffic(directory: directory), id = UUID()
        await traffic.gatewayRequest(id: id)
        await traffic.callStarted(id: id, role: "advisor")
        let usage = JSONObject.from(["input_tokens": .number(12), "output_tokens": .number(3)])
        await traffic.callFinished(id: id, role: "advisor", started: Date(), usage: usage, failed: false)
        await traffic.callFinished(id: id, role: "advisor", started: Date(), usage: usage, failed: false)
        let restored = SIWCTraffic(directory: directory)
        let measured = await restored.snapshot()
        #expect(measured.requests == 1 && measured.modelCalls == 1)
        #expect(measured.inputTokens == 12 && measured.outputTokens == 3 && measured.advisorTokens == 15)
        #expect(measured.buckets.reduce(0, +) == 1)
        let expired = await restored.snapshot(now: Date().addingTimeInterval(301))
        #expect(expired.requests == 0 && expired.inputTokens == 0 && expired.buckets.reduce(0, +) == 0)
        let text = try String(contentsOf: directory.appendingPathComponent("traffic.jsonl"), encoding: .utf8)
        #expect(!text.contains("accessToken") && !text.contains("instructions") && !text.contains("content"))
    }
    @Test func timestampWindowIgnoresOldFutureMalformedAndOtherEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            #"{"stage":"gateway_request","logged_at_unix_ms":720000}"#,
            #"{"stage":"gateway_request","logged_at_unix_ms":990000}"#,
            #"{"stage":"gateway_request","logged_at_unix_ms":600000}"#,
            #"{"stage":"model_call","logged_at_unix_ms":990000}"#,
            #"{"stage":"gateway_request","logged_at_unix_ms":1100000}"#, "invalid"
        ]
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("traffic.jsonl"), atomically: true, encoding: .utf8)
        let traffic = SIWCTraffic(directory: directory)
        let snapshot = await traffic.snapshot(now: Date(timeIntervalSince1970: 1000))
        #expect(snapshot.requests == 2 && snapshot.modelCalls == 1)
        #expect(snapshot.buckets == [1, 0, 0, 0, 1])
        let expired = await traffic.snapshot(now: Date(timeIntervalSince1970: 1500))
        #expect(expired.requests == 0 && expired.buckets == [0, 0, 0, 0, 0])
    }
    @Test func missingProviderUsageIsUnavailableAndFailureCountsOnce() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let traffic = SIWCTraffic(directory: directory), id = UUID()
        await traffic.gatewayRequest(id: id)
        await traffic.callStarted(id: id, role: "executor")
        await traffic.callFinished(id: id, role: "executor", started: Date(), usage: nil, failed: true)
        await traffic.gatewayFinished(id: id, started: Date(), failed: true)
        await traffic.gatewayFinished(id: id, started: Date(), failed: true)
        let snapshot = await traffic.snapshot()
        #expect(snapshot.requests == 1 && snapshot.modelCalls == 1 && snapshot.errors == 1)
        #expect(!snapshot.usageReported && snapshot.lastLatencyMilliseconds != nil)
    }
}
