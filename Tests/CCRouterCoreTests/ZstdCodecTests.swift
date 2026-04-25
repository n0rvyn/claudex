import Foundation
import Testing

@testable import CCRouterCore

@Suite("ZstdCodec")
struct ZstdCodecTests {
    @Test("compress produces valid zstd frame decodable by system zstd")
    func compressProducesDecodableFrame() throws {
        let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
        let compressed = try ZstdCodec.compress(payload)

        #expect(compressed.count > 0)
        #expect(compressed.starts(with: [0x28, 0xB5, 0x2F, 0xFD]))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zstd-codec-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let compressedURL = tempDir.appendingPathComponent("payload.zst")
        let decompressedURL = tempDir.appendingPathComponent("payload.out")
        try compressed.write(to: compressedURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/zstd")
        if !FileManager.default.fileExists(atPath: process.executableURL!.path) {
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/zstd")
        }
        process.arguments = ["-d", compressedURL.path, "-o", decompressedURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let roundtrip = try Data(contentsOf: decompressedURL)
        #expect(roundtrip == payload)
    }

    @Test("compress handles empty input")
    func compressEmpty() throws {
        let compressed = try ZstdCodec.compress(Data())
        #expect(compressed.count > 0)
        #expect(compressed.starts(with: [0x28, 0xB5, 0x2F, 0xFD]))
    }

    @Test("compress handles large input")
    func compressLarge() throws {
        let payload = Data(repeating: 0x41, count: 256 * 1024)
        let compressed = try ZstdCodec.compress(payload)
        #expect(compressed.count > 0)
        #expect(compressed.count < payload.count)
    }
}
