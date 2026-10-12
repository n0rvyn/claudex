import Foundation
import Testing
@testable import CCRouterCore

struct LogRefreshCorrectnessTests {
    private func encoded(_ snapshot: SIWCTrafficSnapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
    private func line(_ stage: String, _ time: Int, _ extra: String = "") -> String {
        "{\"stage\":\"\(stage)\",\"logged_at_unix_ms\":\(time)\(extra)}"
    }
    @Test func ledgerMatchesLegacyAcrossFileChangesAndClockChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("traffic.jsonl"), traffic = SIWCTraffic(directory: dir)
        let started = await traffic.startedAt
        func compare(_ seconds: Double = 1000) async throws {
            let now = Date(timeIntervalSince1970: seconds)
            let text = try? String(contentsOf: url, encoding: .utf8)
            let expected = legacySnapshot(text: text, startedAt: started, now: now)
            let actual = await traffic.snapshot(now: now)
            #expect(try encoded(actual) == encoded(expected))
        }
        try await compare() // Missing file.
        var text = [line("gateway_request", 600000), line("gateway_request", 700000),
                    line("gateway_request", 720000), line("model_call", 1100000), "invalid",
                    line("gateway_result", 990000, ",\"failed\":false,\"duration_ms\":27"),
                    line("gateway_result", 991000, ",\"failed\":true,\"duration_ms\":100"),
                    line("gateway_result", 992000, ",\"cancelled\":true"),
                    line("model_result", 991000, ",\"id\":\"a\",\"role\":\"advisor\",\"input_tokens\":12,\"output_tokens\":3"),
                    line("model_result", 992000, ",\"id\":\"a\",\"input_tokens\":900,\"output_tokens\":900"),
                    line("model_result", 993000, ",\"id\":\"b\""),
                    line("gateway_request", 994000, ",\"synthetic\":\"你好🧪\"")].joined(separator: "\n")
        try Data(text.utf8).write(to: url); try await compare(); try await compare()
        // External append and provisional valid JSON without newline.
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd()
        try h.write(contentsOf: Data(("\n" + line("gateway_request", 995000)).utf8)); try h.close()
        try await compare()
        // Partial JSON and partial multibyte UTF-8 are not permanently lost.
        let h2 = try FileHandle(forWritingTo: url); try h2.seekToEnd()
        let prefix = "\n{\"stage\":\"gateway_request\",\"logged_at_unix_ms\":996000,\"synthetic\":\""
        let unicode = Array("🧪".utf8)
        try h2.write(contentsOf: Data(prefix.utf8) + Data(unicode.prefix(2))); try await compare()
        try h2.write(contentsOf: Data(unicode.dropFirst(2)) + Data("\"}\n".utf8)); try h2.close()
        try await compare(); try await compare(1500); try await compare(1000) // Expiry and clock rollback.
        // Same-inode same-size overwrite, truncation, growing rewrite and atomic rotation.
        text = line("gateway_request", 990000) + "\n"
        try Data(text.utf8).write(to: url); try await compare()
        let changed = text.replacingOccurrences(of: "990000", with: "600000")
        let h3 = try FileHandle(forWritingTo: url); try h3.write(contentsOf: Data(changed.utf8)); try h3.close()
        try await compare()
        try Data((text + text + text).utf8).write(to: url); try await compare()
        try Data(text.utf8).write(to: url, options: .atomic); try await compare()
        try FileManager.default.removeItem(at: url); try await compare()
        try Data(text.utf8).write(to: url); try await compare()
        // Actor-owned append takes the incremental path, including after a trailing partial record.
        try Data("invalid-partial".utf8).write(to: url); try await compare()
        await traffic.logger.log(JSONObject.from(["stage": .string("gateway_request"), "logged_at_unix_ms": .number(997000)]))
        try await compare()
        try Data((text + "\n").utf8).write(to: url); try await compare()
        let initialBytes = await traffic.logger.bytesRead
        await traffic.logger.log(JSONObject.from(["stage": .string("gateway_request"), "logged_at_unix_ms": .number(998000)]))
        try await compare()
        let appendedBytes = await traffic.logger.bytesRead - initialBytes
        #expect(appendedBytes < 150)
        let stableBytes = await traffic.logger.bytesRead
        try await compare(); #expect(await traffic.logger.bytesRead == stableBytes)
        // Concurrent snapshots must not consume a cursor update before its predecessor applies it.
        let expected = try encoded(await traffic.snapshot(now: Date(timeIntervalSince1970: 1000)))
        let snapshots = await withTaskGroup(of: SIWCTrafficSnapshot.self) { group in
            for _ in 0..<30 { group.addTask { await traffic.snapshot(now: Date(timeIntervalSince1970: 1000)) } }
            var results: [SIWCTrafficSnapshot] = []; for await value in group { results.append(value) }; return results
        }
        for snapshot in snapshots { #expect(try encoded(snapshot) == expected) }
    }
    @Test func recorderWritesStayIncrementalAndPrivateAfterExternalRewrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = SIWCTraffic(directory: dir)
        let url = dir.appendingPathComponent("traffic.jsonl")
        let time = Int(Date().timeIntervalSince1970 * 1000) - 1000
        let history = String(repeating: line("gateway_request", time) + "\n", count: 5000)
        try Data(history.utf8).write(to: url)
        #expect(await traffic.snapshot().requests == 5000)
        let originalBytes = await traffic.logger.bytesRead
        let originalSize = try Data(contentsOf: url).count
        let requestID = UUID(), callID = UUID(), started = Date()
        await traffic.gatewayRequest(id: requestID)
        await traffic.callStarted(id: callID, role: "executor")
        await traffic.callFinished(id: callID, role: "executor", started: started,
                                   usage: JSONObject.from(["input_tokens": .number(2), "output_tokens": .number(3)]), failed: false)
        await traffic.gatewayFinished(id: requestID, started: started, failed: false)
        let now = Date()
        let actual = await traffic.snapshot(now: now)
        #expect(actual.requests == 5001 && actual.modelCalls == 1 && actual.successes == 1)
        #expect(actual.inputTokens == 2 && actual.outputTokens == 3)
        let appendedSize = try Data(contentsOf: url).count - originalSize
        #expect(await traffic.logger.bytesRead - originalBytes == UInt64(appendedSize))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let stableBytes = await traffic.logger.bytesRead
        #expect(try encoded(await traffic.snapshot(now: now)) == encoded(actual))
        #expect(await traffic.logger.bytesRead == stableBytes)
        // Preserve size and mtime: ctime must still detect a same-inode rewrite.
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        let rewrite = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "gateway_request", with: "ignored_request")
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(rewrite.utf8)); try handle.close()
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        #expect(await traffic.snapshot().requests == 0)
        #expect(await traffic.logger.bytesRead - stableBytes == UInt64(rewrite.utf8.count))
        let rewriteBytes = await traffic.logger.bytesRead
        await traffic.gatewayRequest()
        #expect(await traffic.snapshot().requests == 1)
        #expect(await traffic.logger.bytesRead - rewriteBytes < 200)
    }

    @Test func cancelledConcurrentSnapshotsLeaveRecorderUsable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = SIWCTraffic(directory: dir)
        await traffic.gatewayRequest()
        let tasks = (0..<40).map { _ in Task { await traffic.snapshot() } }
        for task in tasks { task.cancel() }
        // Snapshot is nonthrowing: cancelled callers still finish and release the gate.
        for task in tasks { #expect(await task.value.requests == 1) }
        await traffic.gatewayRequest()
        #expect(await traffic.snapshot().requests == 2)
    }

    @Test func unreadableLedgerPathRecoversWithoutStaleEvents() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = SIWCTraffic(directory: dir)
        let url = dir.appendingPathComponent("traffic.jsonl")
        await traffic.gatewayRequest()
        #expect(await traffic.snapshot().requests == 1)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await traffic.gatewayRequest() // The directory cannot accept a file append.
        #expect(await traffic.snapshot().requests == 0)
        #expect(await traffic.logger.recentLines(limit: 1).isEmpty)
        try FileManager.default.removeItem(at: url)
        await traffic.gatewayRequest()
        #expect(await traffic.snapshot().requests == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func timestampEdgesMatchLegacyWindowBucketing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = SIWCTraffic(directory: dir)
        let url = dir.appendingPathComponent("traffic.jsonl")
        let text = [line("gateway_request", -1), line("gateway_request", 700000),
                    line("gateway_request", 700001), line("gateway_request", 760000),
                    line("gateway_request", 1000000), line("gateway_request", 1000001),
                    line("gateway_request", Int.max),
                    "{\"stage\":\"gateway_request\",\"logged_at_unix_ms\":\"malformed\"}"].joined(separator: "\n")
        try Data(text.utf8).write(to: url)
        let started = await traffic.startedAt, now = Date(timeIntervalSince1970: 1000)
        let actual = await traffic.snapshot(now: now)
        #expect(try encoded(actual) == encoded(legacySnapshot(text: text, startedAt: started, now: now)))
        #expect(actual.requests == 3 && actual.buckets == [1, 1, 0, 0, 1])
    }

    @Test func tailMatchesLegacyAtByteAndUnicodeBoundaries() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("trace.jsonl"), logger = TraceLogger(fileURL: dir.appendingPathComponent("trace.jsonl"))
        for tail in ["", "\n", "终🧪", "终🧪\n", String(repeating: "🧪", count: 9000)] {
            let text = String(repeating: "first\n", count: 5000) + "\n" + tail
            try Data(text.utf8).write(to: url)
            for limit in [0, 1, 8, 64, 9000, Int.max] {
                let expected = Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)).map(String.init)
                #expect(await logger.recentLines(limit: limit) == expected)
            }
        }
        let small = String(repeating: "{\"stage\":\"synthetic\"}\n", count: 60000)
        try Data(small.utf8).write(to: url)
        _ = await logger.recentLines(limit: 64) // Warm UTF-8 validity cache.
        let before = await logger.bytesRead
        let combined = await logger.diagnosticSnapshot(tailLimit: 8, diagnosticLimit: 64)
        #expect(combined.lines.count == 8 && combined.diagnostics.recentStageCounts["synthetic"] == 64)
        #expect(await logger.bytesRead - before == 16384)
        // Corrupt UTF-8 outside the requested tail still retains old fail-closed behavior.
        try (Data([0xff]) + Data(small.utf8)).write(to: url)
        #expect(await logger.recentLines(limit: 8).isEmpty)
        try FileManager.default.removeItem(at: url)
        #expect(await logger.recentLines(limit: 8).isEmpty)
    }
    private func legacySnapshot(text: String?, startedAt: Date, now: Date) -> SIWCTrafficSnapshot {
        let lines = text?.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        var result = SIWCTrafficSnapshot(); result.startedAt = startedAt
        let end = now.timeIntervalSince1970 * 1000, start = end - 300_000
        var finished: Set<String> = []
        var latencies: [Int] = []
        for line in lines {
            guard let data = line.data(using: .utf8), let event = try? JSONDecoder().decode(JSONObject.self, from: data),
                  case .number(let time)? = event["logged_at_unix_ms"] else { continue }
            result.startedAt = min(result.startedAt, Date(timeIntervalSince1970: time / 1000))
            guard time > start, time <= end else { continue }
            switch event.string("stage") {
            case "gateway_request":
                result.requests += 1
                let index = min(4, max(0, Int((time - start) / 60_000))); result.buckets[index] += 1
            case "gateway_result":
                guard event["cancelled"] != .bool(true) else { continue }
                result.lastLatencyMilliseconds = event["duration_ms"]?.intValue
                if let latency = result.lastLatencyMilliseconds { latencies.append(latency) }
                if event["failed"] == .bool(true) {
                    result.errors += 1; result.lastError = "Gateway request failed"; result.lastOutcome = "Gateway request failed"
                } else { result.successes += 1; result.lastOutcome = "Last request completed" }
            case "model_call": result.modelCalls += 1
            case "model_result":
                guard let id = event.string("id"), finished.insert(id).inserted else { continue }

                if let input = event["input_tokens"]?.intValue, let output = event["output_tokens"]?.intValue {
                    result.usageReported = true; result.inputTokens += input; result.outputTokens += output
                    if event.string("role") == "advisor" { result.advisorTokens += input + output }
                } else { result.usageIncomplete = true }
            default: break
            }
        }
        latencies.sort()
        if !latencies.isEmpty {
            result.p50LatencyMilliseconds = latencies[Int((Double(latencies.count - 1) * 0.5).rounded())]
            result.p95LatencyMilliseconds = latencies[Int((Double(latencies.count - 1) * 0.95).rounded())]
        }
        return result
    }
}
