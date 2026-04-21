import Foundation

public actor TraceLogger {
    public static let shared = TraceLogger()

    private let fileURL: URL
    private let timestampKey = "logged_at_unix_ms"

    public init(fileURL: URL = URL(fileURLWithPath: "/tmp/modelbridge-trace.jsonl")) {
        self.fileURL = fileURL
    }
    private let decoder = JSONDecoder()

    public var path: String {
        fileURL.path
    }

    public func log(_ payload: JSONObject) {
        let encoder = JSONEncoder()
        var enriched = payload
        if enriched.values[timestampKey] == nil {
            enriched[timestampKey] = .number(Date().timeIntervalSince1970 * 1000)
        }
        guard let data = try? encoder.encode(enriched) else { return }
        guard let line = String(data: data, encoding: .utf8) else { return }
        let output = line + "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(output.utf8))
    }

    public func recentLines(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .map(String.init)
    }

    public func diagnostics(limit: Int) -> TraceDiagnostics {
        guard limit > 0 else { return .empty }
        let lines = recentLines(limit: limit)
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

        for line in lines {
            guard let json = line.data(using: .utf8),
                  let object = try? decoder.decode(JSONObject.self, from: json) else {
                continue
            }

            if let stage = object.string("stage") {
                stageCounts[stage, default: 0] += 1
            }

            let timestamp = object.values[timestampKey]?.intValue

            if object.string("stage") == "anthropic_in", let timestamp {
                requestTimestamps.append(timestamp)
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
                if statusCode >= 400 {
                    failureCount += 1
                    if let message = object.string("error_message") {
                        recentErrorReasons.append(message)
                    } else if let errorType = object.string("error_type") {
                        recentErrorReasons.append(errorType)
                    } else if let outcome {
                        recentErrorReasons.append(outcome)
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
            recentErrorReasons: uniquePreservingOrder(recentErrorReasons)
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
