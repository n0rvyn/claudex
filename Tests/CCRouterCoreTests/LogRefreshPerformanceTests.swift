import Foundation
import Testing
@testable import CCRouterCore

struct LogRefreshPerformanceTests {
    @Test func benchmarkSyntheticLedgers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_000)
        let traceLine = "{\"stage\":\"synthetic\",\"padding\":\"" + String(repeating: "x", count: 256) + "\"}\n"
        let trace = String(repeating: traceLine, count: 5_300)
        let trafficLine = "{\"stage\":\"gateway_request\",\"logged_at_unix_ms\":990000}\n"
        let ledger = String(repeating: trafficLine, count: 5_020)
        try trace.write(to: dir.appendingPathComponent("trace.jsonl"), atomically: true, encoding: .utf8)
        try ledger.write(to: dir.appendingPathComponent("traffic.jsonl"), atomically: true, encoding: .utf8)
        let logger = TraceLogger(fileURL: dir.appendingPathComponent("trace.jsonl"))
        let traffic = SIWCTraffic(directory: dir)
        _ = await logger.diagnosticSnapshot(tailLimit: 8, diagnosticLimit: 64)
        #expect(await traffic.snapshot(now: now).requests == 5_020)
        let initialBytes = await logger.bytesRead + traffic.logger.bytesRead
        for _ in 0..<20 {
            _ = await logger.diagnosticSnapshot(tailLimit: 8, diagnosticLimit: 64)
            #expect(await traffic.snapshot(now: now).requests == 5_020)
        }
        let repeatBytes = await logger.bytesRead + traffic.logger.bytesRead - initialBytes
        // Twenty unchanged refreshes must read less than one whole synthetic log pair.
        // This catches repeated full-ledger reads without a timing-sensitive threshold.
        #expect(repeatBytes < UInt64(trace.utf8.count + ledger.utf8.count))
    }
}
