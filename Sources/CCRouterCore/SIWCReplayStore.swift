import Foundation
import CryptoKit
import Darwin

struct SIWCReplayRecord: Codable, Sendable {
    let key: String
    let output: [JSONValue]
    let route: ModelRoute
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
