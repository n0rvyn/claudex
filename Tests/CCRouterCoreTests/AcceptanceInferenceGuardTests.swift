import Foundation
import Testing
@testable import CCRouterCore
struct AcceptanceInferenceGuardTests {
    let payload = JSONObject.from(["model": .string("gpt-6-luna"), "reasoning": .object(JSONObject.from(["effort": .string("low")]))])
    @Test func disabledGuardDoesNotRestrictNormalTraffic() async throws {
        try await AcceptanceInferenceGuard(environment: [:]).reserve(payload: JSONObject.from(["model": .string("other")]))
    }
    @Test func capPersistsAcrossInstancesAndBlocksBeforeNetwork() async throws {
        let path = "/tmp/claudex-guard-" + UUID().uuidString + ".json"
        defer { for suffix in ["", ".lock", ".ingress.jsonl", ".replay.jsonl"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let env = ["CC_ROUTER_ACCEPTANCE_LIMIT": "2", "CC_ROUTER_ACCEPTANCE_LEDGER": path]
        try await AcceptanceInferenceGuard(environment: env).reserve(payload: payload)
        let resumed = AcceptanceInferenceGuard(environment: env)
        try await resumed.reserve(payload: payload)
        await #expect(throws: SIWCError.self) { try await resumed.reserve(payload: payload) }
        #expect(try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: path)))["count"]?.intValue == 2)
    }
    @Test func modelEffortTierAndMalformedLedgerFailClosed() async throws {
        let path = "/tmp/claudex-guard-" + UUID().uuidString + ".json"
        defer { for suffix in ["", ".lock", ".ingress.jsonl", ".replay.jsonl"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let guardValue = AcceptanceInferenceGuard(environment: ["CC_ROUTER_ACCEPTANCE_LIMIT": "8", "CC_ROUTER_ACCEPTANCE_LEDGER": path])
        for key in ["model", "reasoning", "service_tier"] {
            var bad = payload
            bad[key] = key == "reasoning" ? .object(JSONObject.from(["effort": .string("high")])) : .string("priority")
            await #expect(throws: SIWCError.self) { try await guardValue.reserve(payload: bad) }
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        try Data("invalid ledger".utf8).write(to: URL(fileURLWithPath: path))
        await #expect(throws: (any Error).self) { try await guardValue.reserve(payload: payload) }
    }
    @Test func partialAcceptanceConfigurationAndObserveOnlyBlockReservation() async throws {
        let path = "/tmp/claudex-guard-" + UUID().uuidString + ".json"
        defer { for suffix in ["", ".lock", ".ingress.jsonl", ".replay.jsonl"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        for env in [
            ["CC_ROUTER_ACCEPTANCE_OBSERVE_ONLY": "1"],
            ["CC_ROUTER_ACCEPTANCE_LEDGER": path],
            ["CC_ROUTER_ACCEPTANCE_LIMIT": "8"],
            ["CC_ROUTER_ACCEPTANCE_LIMIT": "8", "CC_ROUTER_ACCEPTANCE_LEDGER": path, "CC_ROUTER_ACCEPTANCE_OBSERVE_ONLY": "bad"],
            ["CC_ROUTER_ACCEPTANCE_LIMIT": "8", "CC_ROUTER_ACCEPTANCE_LEDGER": path, "CC_ROUTER_ACCEPTANCE_OBSERVE_ONLY": "1"]
        ] {
            await #expect(throws: SIWCError.self) { try await AcceptanceInferenceGuard(environment: env).reserve(payload: payload) }
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
    @Test func concurrentIndependentGuardsShareOneRemainingReservation() async throws {
        let path = "/tmp/claudex-guard-" + UUID().uuidString + ".json"
        defer { for suffix in ["", ".lock", ".ingress.jsonl", ".replay.jsonl"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let env = ["CC_ROUTER_ACCEPTANCE_LIMIT": "1", "CC_ROUTER_ACCEPTANCE_LEDGER": path]
        let payload = self.payload
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do { try await AcceptanceInferenceGuard(environment: env).reserve(payload: payload); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        #expect(successes == 1)
        #expect(try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: path)))["count"]?.intValue == 1)
    }
    @Test func observeOnlyCaptureExcludesArbitraryDiagnosticValues() async throws {
        let path = "/tmp/claudex-guard-" + UUID().uuidString + ".json"
        defer { for suffix in ["", ".lock", ".ingress.jsonl", ".replay.jsonl"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let sentinel = "PRIVATE_SENTINEL_NEVER_LOG"
        let input = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: Data(#"{"model":"PRIVATE_SENTINEL_NEVER_LOG","thinking":{"type":"adaptive","display":"PRIVATE_SENTINEL_NEVER_LOG","private":"PRIVATE_SENTINEL_NEVER_LOG"},"output_config":{"effort":"low","private":"PRIVATE_SENTINEL_NEVER_LOG"},"messages":[{"role":"system","content":[],"output_config":{"effort":"low","private":"PRIVATE_SENTINEL_NEVER_LOG"}},{"role":"user","content":[{"type":"text","text":"PRIVATE_SENTINEL_NEVER_LOG","cache_control":{"type":"ephemeral","ttl":"PRIVATE_SENTINEL_NEVER_LOG","private":"PRIVATE_SENTINEL_NEVER_LOG"}}]}]}"#.utf8))
        let guardValue = AcceptanceInferenceGuard(environment: ["CC_ROUTER_ACCEPTANCE_LIMIT": "8", "CC_ROUTER_ACCEPTANCE_LEDGER": path, "CC_ROUTER_ACCEPTANCE_OBSERVE_ONLY": "1"])
        await #expect(throws: SIWCError.self) { try await guardValue.observeIngress(input, headers: ["anthropic-beta": sentinel, "x-app-version": sentinel]) }
        let capture = try String(contentsOfFile: path + ".ingress.jsonl", encoding: .utf8)
        #expect(!capture.contains(sentinel))
        #expect(capture.contains("ephemeral"))
        #expect(capture.contains("adaptive"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }
    @Test func reservationWaitsForOtherProcessBeforeReadingCount() async throws {
        let path = "/tmp/claudex-guard-process-" + UUID().uuidString + ".json"
        let worker = Process(), input = Pipe(), output = Pipe()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        worker.arguments = ["-c", """
import os,sys,json,fcntl
path=sys.argv[1]
fd=os.open(path+'.lock',os.O_CREAT|os.O_RDWR,0o600)
fcntl.flock(fd,fcntl.LOCK_EX)
with open(path,'w') as f: json.dump({'limit':1,'count':0,'requests':[]},f)
print('ready',flush=True)
sys.stdin.readline()
with open(path,'w') as f: json.dump({'limit':1,'count':1,'requests':[]},f)
fcntl.flock(fd,fcntl.LOCK_UN)
os.close(fd)
""", path]
        worker.standardInput = input; worker.standardOutput = output; worker.standardError = FileHandle.nullDevice
        defer {
            if worker.isRunning { worker.terminate(); worker.waitUntilExit() }
            for suffix in ["", ".lock", ".ingress.jsonl", ".replay.jsonl"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        try worker.run()
        #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
        let guardValue = AcceptanceInferenceGuard(environment: ["CC_ROUTER_ACCEPTANCE_LIMIT": "1", "CC_ROUTER_ACCEPTANCE_LEDGER": path])
        let payload = self.payload
        let reservation = Task { () -> Bool in
            do { try await guardValue.reserve(payload: payload); return true }
            catch { return false }
        }
        // The child holds the ledger lock while its count is still zero. Once
        // released it publishes exhaustion; a reservation must read that count.
        try await Task.sleep(for: .milliseconds(100))
        try input.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
        #expect(await reservation.value == false)
        worker.waitUntilExit()
        #expect(worker.terminationStatus == 0)
        #expect(try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: path)))["count"]?.intValue == 1)
    }
    @Test func replayObservationContainsDigestsWithoutPrivateValues() async throws {
        let path = "/tmp/claudex-guard-replay-" + UUID().uuidString + ".json"
        defer { for suffix in ["", ".lock", ".ingress.jsonl", ".replay.jsonl"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let sentinel = "PRIVATE_SENTINEL_NEVER_LOG"
        let messages = [AnthropicMessage(role: "user", content: [JSONObject.from(["type": .string("text"), "text": .string(sentinel)])]),
                        AnthropicMessage(role: "system", content: [], output_config: JSONObject.from(["effort": .string("low"), "private": .string(sentinel)]))]
        let guardValue = AcceptanceInferenceGuard(environment: ["CC_ROUTER_ACCEPTANCE_LIMIT": "8", "CC_ROUTER_ACCEPTANCE_LEDGER": path])
        try await guardValue.observeReplay(messages, scope: sentinel, stage: sentinel, cacheHit: false)
        let capture = try String(contentsOfFile: path + ".replay.jsonl", encoding: .utf8)
        #expect(!capture.contains(sentinel))
        let record = try JSONDecoder().decode(JSONObject.self, from: Data(capture.utf8))
        #expect(record.bool("cache_hit") == false)
        #expect(record.string("canonical_prefix_hash") == SIWCBridge.fingerprint(messages))
        #expect(record.array("messages")?.count == 2)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
