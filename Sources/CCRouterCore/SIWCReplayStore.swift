import Foundation
import CryptoKit
import Darwin

struct SIWCReplayRecord: Codable, Sendable {
    let key: String
    let output: [JSONValue]
    let route: ModelRoute
    var advisorRoute: ModelRoute? = nil
    var assistantFingerprint: String? = nil
}
/// Transcript-prefix sidecars retain raw Responses items, including phase and opaque reasoning.
/// Files are hashed by account + session + prefix; they never appear in diagnostics.
public struct SIWCReplayStore: Sendable {
    let directory: URL
    public init(directory: URL = SIWCStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Replay")) { self.directory = directory }
    private func location(_ key: String) -> URL {
        let name = Data(SHA256.hash(data: Data(key.utf8))).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    func load(_ key: String) throws -> SIWCReplayRecord? {
        if FileManager.default.fileExists(atPath: directory.path) { try SIWCStore.validateDirectory(directory) }
        let path = location(key)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        var info = stat()
        guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw SIWCError.storage }
        let record = try JSONDecoder().decode(SIWCReplayRecord.self, from: Data(contentsOf: path))
        guard record.key == key else { throw SIWCError.storage }
        return record
    }
    /// Compaction recovery is scoped and exact: never match only a call ID.
    /// Ambiguous emissions across branches fail closed, including legacy records.
    func compactedReplay(scope: String, assistant: AnthropicMessage) throws -> SIWCReplayRecord? {
        guard assistant.content.contains(where: { $0.string("type") == "tool_use" }),
              assistant.clear_at == nil else { return nil }
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try SIWCStore.validateDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "traffic.jsonl" }
        guard files.count <= 20_000 else { throw SIWCError.remote("replay_recovery_scan_limit") }
        let wanted = SIWCBridge.fingerprint([assistant])
        var match: SIWCReplayRecord?
        for path in files {
            var info = stat()
            guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_size <= 8 * 1024 * 1024 else { throw SIWCError.storage }
            // traffic/catalog files in a shared fixture directory are not replay records.
            guard let record = try? JSONDecoder().decode(SIWCReplayRecord.self, from: Data(contentsOf: path)),
                  record.key.hasPrefix(scope + ":"), location(record.key).lastPathComponent == path.lastPathComponent else { continue }
            let fingerprint = record.assistantFingerprint ?? legacyAssistantFingerprint(record.output)
            guard fingerprint == wanted else { continue }
            guard match == nil || match?.key == record.key else {
                throw SIWCError.remote("tool_continuation_replay_ambiguous")
            }
            match = record
        }
        return match
    }
    private func legacyAssistantFingerprint(_ output: [JSONValue]) -> String? {
        var blocks: [JSONObject] = []
        for value in output {
            guard let item = value.objectValue else { return nil }
            switch item.string("type") {
            case "reasoning": continue // Opaque items are retained in output, never decoded.
            case "function_call":
                guard item.string("namespace") == "claude", let id = item.string("call_id"),
                      let name = item.string("name"), let arguments = item.string("arguments"),
                      let input = try? JSONDecoder().decode(JSONObject.self, from: Data(arguments.utf8)) else { return nil }
                blocks.append(JSONObject.from(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": .object(input)]))
            case "message":
                let text = (item.array("content") ?? []).compactMap { $0.objectValue?.string("text") ?? $0.objectValue?.string("refusal") }.joined()
                if !text.isEmpty { blocks.append(JSONObject.from(["type": .string("text"), "text": .string(text)])) }
            default: return nil // Legacy Advisor/native items cannot be reconstructed safely.
            }
        }
        return SIWCBridge.fingerprint([AnthropicMessage(role: "assistant", content: blocks)])
    }
    func save(_ record: SIWCReplayRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SIWCStore.validateDirectory(directory)
        let temp = directory.appendingPathComponent(".replay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SIWCError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try file.write(contentsOf: JSONEncoder().encode(record)); try file.synchronize(); try file.close() }
        catch { try? file.close(); throw SIWCError.storage }
        guard rename(temp.path, location(record.key).path) == 0 else { throw SIWCError.storage }
    }
}
