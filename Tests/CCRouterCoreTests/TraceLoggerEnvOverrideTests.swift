import Foundation
@testable import CCRouterCore
import Testing

struct TraceLoggerEnvOverrideTests {
    @Test
    func envPathNilReturnsNoOverride() {
        let result = DaemonTraceOverrideResolver.resolve(envPath: nil)
        #expect(result == .noOverride)
    }

    @Test
    func envPathEmptyReturnsNoOverride() {
        let result = DaemonTraceOverrideResolver.resolve(envPath: "")
        #expect(result == .noOverride)
    }

    @Test
    func envPathRelativeReturnsInvalid() {
        let result = DaemonTraceOverrideResolver.resolve(envPath: "foo/bar")
        #expect(result == .invalid("must be absolute, got: foo/bar"))
    }

    @Test
    func envPathSystemPrefixEtcReturnsInvalid() {
        let result = DaemonTraceOverrideResolver.resolve(envPath: "/etc/trace.jsonl")
        #expect(result == .invalid("points to system path: /etc/trace.jsonl"))
    }

    @Test
    func envPathSystemPrefixSystemReturnsInvalid() {
        let result = DaemonTraceOverrideResolver.resolve(envPath: "/System/trace.jsonl")
        #expect(result == .invalid("points to system path: /System/trace.jsonl"))
    }

    @Test
    func envPathSystemPrefixLibraryReturnsInvalid() {
        let result = DaemonTraceOverrideResolver.resolve(envPath: "/Library/trace.jsonl")
        #expect(result == .invalid("points to system path: /Library/trace.jsonl"))
    }

    @Test
    func envPathValidAbsoluteReturnsOverride() {
        let result = DaemonTraceOverrideResolver.resolve(envPath: "/tmp/phase7/trace.jsonl")
        guard case .override(let url) = result else {
            fatalError("Expected .override, got \(result)")
        }
        #expect(url.path == "/tmp/phase7/trace.jsonl")
    }
}
