import Foundation

public actor TraceLogger {
    public static let shared = TraceLogger()

    private let fileURL: URL

    public init(fileURL: URL = URL(fileURLWithPath: "/tmp/modelbridge-trace.jsonl")) {
        self.fileURL = fileURL
    }
    private let decoder = JSONDecoder()

    public var path: String {
        fileURL.path
    }

    public func log(_ payload: JSONObject) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload) else { return }
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

        for line in lines {
            guard let json = line.data(using: .utf8),
                  let object = try? decoder.decode(JSONObject.self, from: json) else {
                continue
            }

            if let stage = object.string("stage") {
                stageCounts[stage, default: 0] += 1
            }

            if let path = object.string("path"), object.string("stage") == "local_auth_reject" {
                rejectedPaths.append(path)
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

        return TraceDiagnostics(
            recentStageCounts: stageCounts,
            recentFunctionCallNames: uniquePreservingOrder(functionCallNames),
            recentConnectorNames: uniquePreservingOrder(connectorNames),
            recentRejectedPaths: uniquePreservingOrder(rejectedPaths)
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
}
