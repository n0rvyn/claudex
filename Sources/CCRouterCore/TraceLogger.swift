import Foundation
import Darwin

public actor TraceLogger {
    public static let shared = TraceLogger()

    /// Task-local override — scoped to current Task tree. Propagates through
    /// structured concurrency (async/await, async let, TaskGroup) but NOT
    /// through `Task.detached`. Suitable for per-test isolation.
    @TaskLocal public static var overrideFileURL: URL?

    private let defaultFileURL: URL

    /// Actor-instance override — persists across Task boundaries including
    /// `Task.detached`. Set once at daemon startup via `setFileOverride(_:)`;
    /// reading it from detached connection handlers
    /// (LocalHTTPServer.swift:216) correctly observes the current value
    /// via actor serialization.
    private var instanceOverrideFileURL: URL?

    public init(
        fileURL: URL = URL(
            fileURLWithPath: UserHomeResolver.defaultTraceLogFilePath()
        )
    ) {
        self.defaultFileURL = fileURL
    }

    /// Sets the instance-level override. Pass nil to clear.
    /// Intended for daemon startup (CC_ROUTER_TRACE_PATH) and serialized
    /// test suites that spawn `Task.detached` (e.g. LocalHTTPServerStreamingErrorTests).
    public func setFileOverride(_ url: URL?) {
        self.instanceOverrideFileURL = url
    }

    private var effectiveFileURL: URL {
        // TaskLocal wins (test per-test isolation overrides daemon's long-lived setting)
        if let taskLocal = Self.overrideFileURL { return taskLocal }
        if let instance = instanceOverrideFileURL { return instance }
        return defaultFileURL
    }

    private let timestampKey = "logged_at_unix_ms"
    private let decoder = JSONDecoder()

    public var path: String {
        effectiveFileURL.path
    }

    public func log(_ payload: JSONObject) {
        append(payload, permissions: nil)
    }

    /// Keep permission changes and append stamps in one actor-isolated operation.
    /// The public trace API retains its existing permission behavior.
    func log(_ payload: JSONObject, permissions: Int) {
        append(payload, permissions: permissions)
    }

    private func append(_ payload: JSONObject, permissions: Int?) {
        let fileURL = effectiveFileURL
        let encoder = JSONEncoder()
        var enriched = payload
        if enriched.values[timestampKey] == nil {
            enriched[timestampKey] = .number(Date().timeIntervalSince1970 * 1000)
        }
        guard let data = try? encoder.encode(enriched) else { return }
        guard let line = String(data: data, encoding: .utf8) else { return }
        let output = line + "\n"

        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                           attributes: permissions.map { [.posixPermissions: $0] })
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        let before = FileStamp(handle)
        // Compare against the pre-permission stamp, then capture the final stamp
        // after both chmod and write. Use the open descriptor, not a raced path.
        if let permissions, fchmod(handle.fileDescriptor, mode_t(permissions)) != 0 {
            traceStamp = nil; ledgerStamp = nil
            return
        }
        do {
            _ = try handle.seekToEnd()
            let bytes = Data(output.utf8)
            try handle.write(contentsOf: bytes)
            if fileURL == traceURL, before == traceStamp, let before,
               let after = FileStamp(handle), after.device == before.device,
               after.inode == before.inode, after.size == before.size + Int64(bytes.count) {
                traceStamp = after
            } else { traceStamp = nil }
            if fileURL == ledgerURL, before == ledgerStamp, let before,
               let after = FileStamp(handle), after.device == before.device,
               after.inode == before.inode, after.size == before.size + Int64(bytes.count) {
                ledgerStamp = after
            } else { ledgerStamp = nil }
        } catch { traceStamp = nil; ledgerStamp = nil }
    }

    // Counts actual bytes returned by file reads; internal verification only.
    private(set) var bytesRead: UInt64 = 0
    private var traceURL: URL?
    private var traceStamp: FileStamp?
    private var traceValidUTF8 = true

    public func recentLines(limit: Int) -> [String] {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: effectiveFileURL) else { return [] }
        defer { try? handle.close() }
        guard let before = FileStamp(handle) else { return [] }
        do {
            // Preserve the old whole-file UTF-8 failure semantics. Validation is
            // cached; only an unknown external change requires this cold read.
            if traceURL != effectiveFileURL || traceStamp != before {
                let contents = try handle.readToEnd() ?? Data()
                bytesRead += UInt64(contents.count)
                guard before == FileStamp(handle) else { traceStamp = nil; return [] }
                traceURL = effectiveFileURL; traceStamp = before
                traceValidUTF8 = String(data: contents, encoding: .utf8) != nil
            }
            guard traceValidUTF8 else { return [] }
            var position = try handle.seekToEnd()
            var bytes = Data()
            while position > 0 {
                let count = min(position, 16_384)
                position -= count
                try handle.seek(toOffset: position)
                let chunk = try handle.read(upToCount: Int(count)) ?? Data()
                bytesRead += UInt64(chunk.count)
                bytes.insert(contentsOf: chunk, at: 0)
                // Drop the first fragment when this read starts inside a line.
                // Split bytes before decoding so a chunk boundary never splits UTF-8.
                let pieces = bytes.split(separator: 10, omittingEmptySubsequences: true)
                let usable = position == 0 ? pieces[...] : pieces.dropFirst()
                if usable.count >= limit || position == 0 {
                    var lines: [String] = []
                    for piece in usable.suffix(limit) {
                        guard let line = String(data: Data(piece), encoding: .utf8) else { return [] }
                        lines.append(line)
                    }
                    guard before == FileStamp(handle) else { return [] }
                    return lines
                }
            }
        } catch { return [] }
        return []
    }

    /// One read supplies both visible tail and diagnostics for a daemon refresh.
    public func diagnosticSnapshot(tailLimit: Int, diagnosticLimit: Int) -> (lines: [String], diagnostics: TraceDiagnostics) {
        let lines = recentLines(limit: max(tailLimit, diagnosticLimit))
        return (Array(lines.suffix(max(0, tailLimit))), diagnostics(lines: Array(lines.suffix(max(0, diagnosticLimit)))))
    }

    struct LedgerUpdate: Sendable {
        var reset: Bool
        var validUTF8: Bool
        var completeLines: [String]
        var trailingLine: String?
    }

    private struct FileStamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init?(_ handle: FileHandle) {
            var value = stat()
            guard fstat(handle.fileDescriptor, &value) == 0 else { return nil }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    private var ledgerURL: URL?
    private var ledgerStamp: FileStamp?
    private var ledgerOffset: UInt64 = 0
    private var ledgerEnd: UInt64 = 0
    private var ledgerTail: String?
    private var ledgerValidUTF8 = true

    /// Only appends performed by this actor may advance the expected stamp.
    /// An external change (even a growing rewrite) invalidates the cursor and
    /// rebuilds from disk, rather than assuming every size increase is append-only.
    func ledgerUpdate(forceReset: Bool = false) -> LedgerUpdate {
        let url = effectiveFileURL
        guard let handle = try? FileHandle(forReadingFrom: url), let before = FileStamp(handle) else {
            ledgerURL = nil; ledgerStamp = nil; ledgerOffset = 0; ledgerEnd = 0; ledgerTail = nil
            return LedgerUpdate(reset: true, validUTF8: true, completeLines: [], trailingLine: nil)
        }
        defer { try? handle.close() }
        let reset = forceReset || url != ledgerURL || before != ledgerStamp
        if reset { ledgerOffset = 0; ledgerEnd = 0; ledgerTail = nil; ledgerValidUTF8 = true }
        if !reset, UInt64(before.size) == ledgerEnd {
            return LedgerUpdate(reset: false, validUTF8: ledgerValidUTF8, completeLines: [], trailingLine: ledgerTail)
        }
        do {
            try handle.seek(toOffset: ledgerOffset)
            let bytes = try handle.readToEnd() ?? Data()
            bytesRead += UInt64(bytes.count)
            // A concurrent writer must not make a partially observed read cacheable.
            guard let after = FileStamp(handle), before == after else {
                ledgerStamp = nil
                return LedgerUpdate(reset: true, validUTF8: false, completeLines: [], trailingLine: nil)
            }
            ledgerURL = url; ledgerStamp = after; ledgerEnd = UInt64(after.size)
            guard String(data: bytes, encoding: .utf8) != nil else {
                ledgerValidUTF8 = false
                return LedgerUpdate(reset: reset, validUTF8: false, completeLines: [], trailingLine: nil)
            }
            ledgerValidUTF8 = true
            let boundary = bytes.lastIndex(of: 10).map { bytes.distance(from: bytes.startIndex, to: $0) + 1 } ?? 0
            let complete = String(decoding: bytes.prefix(boundary), as: UTF8.self)
            ledgerOffset += UInt64(boundary)
            let tailBytes = bytes.dropFirst(boundary)
            ledgerTail = tailBytes.isEmpty ? nil : String(data: Data(tailBytes), encoding: .utf8)
            return LedgerUpdate(reset: reset, validUTF8: true,
                completeLines: complete.split(separator: "\n", omittingEmptySubsequences: true).map(String.init), trailingLine: ledgerTail)
        } catch {
            ledgerStamp = nil
            return LedgerUpdate(reset: true, validUTF8: false, completeLines: [], trailingLine: nil)
        }
    }

    /// Resets the trace log file for testing. Only for use in test targets.
    public func resetForTesting() {
        let fileURL = effectiveFileURL
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data().write(to: fileURL)
    }

    public func diagnostics(limit: Int) -> TraceDiagnostics {
        guard limit > 0 else { return .empty }
        return diagnostics(lines: recentLines(limit: limit))
    }

    private func diagnostics(lines: [String]) -> TraceDiagnostics {
        guard !lines.isEmpty else { return .empty }

        var stageCounts: [String: Int] = [:]
        var functionCallNames: [String] = []
        var connectorNames: [String] = []
        var rejectedPaths: [String] = []
        var requestTimestamps: [Int] = []
        var latencies: [Int] = []
        var recentErrorReasons: [String] = []
        var successCount = 0
        var failureCount = 0
        var lastRequestOutcome: String?
        var lastLatencyMilliseconds: Int?

        // Per-Claude-model aggregation state.
        var claudeModelLookup: [String: String] = [:]   // sessionID -> claude_model
        var perModelState: [String: (latencies: [Int], success: Int, failure: Int, lastUpstream: String?, errors: [String])] = [:]

        for line in lines {
            guard let json = line.data(using: .utf8),
                  let object = try? decoder.decode(JSONObject.self, from: json) else {
                continue
            }

            if let stage = object.string("stage") {
                stageCounts[stage, default: 0] += 1
            }

            let timestamp = object.values[timestampKey]?.intValue

            if object.string("stage") == "anthropic_in" {
                if let timestamp {
                    requestTimestamps.append(timestamp)
                }
                // Record claude_model for this session so anthropic_out can look it up.
                if let sessionID = object.string("session_id"),
                   let claudeModel = object.string("claude_model") {
                    claudeModelLookup[sessionID] = claudeModel
                }
            }

            if let path = object.string("path"), object.string("stage") == "local_auth_reject" {
                rejectedPaths.append(path)
                failureCount += 1
                lastRequestOutcome = "auth_rejected"
                recentErrorReasons.append("Local auth rejected: \(path)")
            }

            if object.string("stage") == "anthropic_out" {
                let statusCode = object.values["status_code"]?.intValue ?? 0
                let outcome = object.string("result")
                lastRequestOutcome = outcome
                if let duration = object.values["duration_ms"]?.intValue {
                    latencies.append(duration)
                    lastLatencyMilliseconds = duration
                }

                // Per-Claude-model aggregation: look up model from session_id.
                if let sessionID = object.string("session_id"),
                   let claudeModel = claudeModelLookup[sessionID] ?? object.string("claude_model") {
                    var state = perModelState[claudeModel] ?? ([], 0, 0, nil, [])
                    if let duration = object.values["duration_ms"]?.intValue {
                        state.latencies.append(duration)
                    }
                    if statusCode >= 400 {
                        state.failure += 1
                        if let message = object.string("error_message") {
                            state.errors.append(message)
                        } else if let errorType = object.string("error_type") {
                            state.errors.append(errorType)
                        } else if let outcome {
                            state.errors.append(outcome)
                        }
                    } else {
                        state.success += 1
                    }
                    if let upstream = object.string("upstream_model") {
                        state.lastUpstream = upstream
                    }
                    perModelState[claudeModel] = state
                }

                if statusCode >= 400 {
                    failureCount += 1
                    if recentErrorReasons.count < 10 {
                        if let message = object.string("error_message") {
                            recentErrorReasons.append(message)
                        } else if let errorType = object.string("error_type") {
                            recentErrorReasons.append(errorType)
                        } else if let outcome {
                            recentErrorReasons.append(outcome)
                        }
                    }
                } else {
                    successCount += 1
                }
            }

            if let calls = object.array("function_calls") {
                for value in calls {
                    guard let call = value.objectValue,
                          let name = call.string("name") else { continue }
                    functionCallNames.append(name)
                    if name.hasPrefix("mcp__") || name.contains("__authenticate") {
                        connectorNames.append(name)
                    }
                }
            }

            if let toolNames = object.array("tool_names") {
                for value in toolNames {
                    guard let name = value.stringValue else { continue }
                    if name.hasPrefix("mcp__") {
                        connectorNames.append(name)
                    }
                }
            }
        }

        let requestsPerMinute = computeRequestsPerMinute(from: requestTimestamps)

        // Build per-Claude-model metrics.
        let perClaudeMetrics: [String: ClaudeModelMetrics] = Dictionary(uniqueKeysWithValues: perModelState.map { key, state in
            let sorted = state.latencies.sorted()
            let p50 = sorted.isEmpty ? nil : sorted[sorted.count / 2]
            let p95idx = Int((Double(sorted.count - 1) * 0.95).rounded())
            let p95 = sorted.isEmpty ? nil : sorted[max(0, min(p95idx, sorted.count - 1))]
            let metrics = ClaudeModelMetrics(
                requestCount: state.success + state.failure,
                successCount: state.success,
                failureCount: state.failure,
                p50LatencyMilliseconds: p50,
                p95LatencyMilliseconds: p95,
                lastUpstreamModel: state.lastUpstream,
                recentErrorReasons: Array(state.errors.prefix(5))
            )
            return (key, metrics)
        })

        return TraceDiagnostics(
            recentStageCounts: stageCounts,
            recentFunctionCallNames: uniquePreservingOrder(functionCallNames),
            recentConnectorNames: uniquePreservingOrder(connectorNames),
            recentRejectedPaths: uniquePreservingOrder(rejectedPaths),
            recentRequestCount: requestTimestamps.count,
            recentSuccessCount: successCount,
            recentFailureCount: failureCount,
            requestsPerMinute: requestsPerMinute,
            lastRequestOutcome: lastRequestOutcome,
            lastLatencyMilliseconds: lastLatencyMilliseconds,
            p50LatencyMilliseconds: percentile(latencies, percentile: 0.5),
            p95LatencyMilliseconds: percentile(latencies, percentile: 0.95),
            recentErrorReasons: uniquePreservingOrder(recentErrorReasons),
            perClaudeModelMetrics: perClaudeMetrics
        )
    }

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            ordered.append(value)
        }
        return ordered
    }

    private func computeRequestsPerMinute(from timestamps: [Int]) -> Double {
        guard let latestTimestamp = timestamps.max() else { return 0 }
        let fiveMinutesInMilliseconds = 5 * 60 * 1000
        let recentCount = timestamps.filter { latestTimestamp - $0 <= fiveMinutesInMilliseconds }.count
        return Double(recentCount) / 5.0
    }

    private func percentile(_ values: [Int], percentile: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded())
        return sorted[max(0, min(index, sorted.count - 1))]
    }
}
