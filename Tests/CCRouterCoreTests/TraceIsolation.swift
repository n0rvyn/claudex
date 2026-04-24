import Foundation
@testable import CCRouterCore

// Note: The "production trace untouched" invariant is NOT asserted by runtime tests —
// TraceLogger.shared is process-global mutable state, and Swift Testing runs suites
// in parallel by default, so cross-suite setFileOverride races cannot be avoided.
// Trace hygiene is verified structurally instead: `grep -r "TraceLogger.shared.log"
// Tests/` returns zero direct calls; all paths that reach log() go through
// effectiveFileURL, which honors the TaskLocal or instance override set by the
// helpers below. Daemon set-once semantics are verified at mechanism level by
// Tests/CCRouterCoreTests/TraceLoggerEnvOverrideTests.swift (resolver logic).
enum TraceIsolation {
    static func isolatedTracePath(prefix: String = "phase7-test") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)-trace.jsonl")
    }

    /// Use for tests that call AnthropicBridge directly (no LocalHTTPServer).
    /// TaskLocal propagates through async/await and actor hops within the same task tree.
    static func withTaskLocalIsolation<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        let url = isolatedTracePath()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await TraceLogger.$overrideFileURL.withValue(url, operation: body)
    }

    /// Use for tests that start a real LocalHTTPServer (Task.detached breaks TaskLocal).
    /// Sets the actor-instance override, runs body, restores nil synchronously.
    /// Caller's suite MUST be `@Suite(.serialized)` — this mutates shared actor state.
    ///
    /// Cleanup must be synchronous (not `defer { Task { ... } }`) because Swift Testing
    /// may start the next test before a deferred detached Task runs, leaking the
    /// override into unrelated suites.
    static func withInstanceOverride<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        let url = isolatedTracePath(prefix: "phase7-test-detached")
        await TraceLogger.shared.setFileOverride(url)
        do {
            let result = try await body()
            await TraceLogger.shared.setFileOverride(nil)
            try? FileManager.default.removeItem(at: url)
            return result
        } catch {
            await TraceLogger.shared.setFileOverride(nil)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
