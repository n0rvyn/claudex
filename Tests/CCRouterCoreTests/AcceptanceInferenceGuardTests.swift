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
        defer { try? FileManager.default.removeItem(atPath: path) }
        let env = ["CC_ROUTER_ACCEPTANCE_LIMIT": "2", "CC_ROUTER_ACCEPTANCE_LEDGER": path]
        try await AcceptanceInferenceGuard(environment: env).reserve(payload: payload)
        let resumed = AcceptanceInferenceGuard(environment: env)
        try await resumed.reserve(payload: payload)
        await #expect(throws: SIWCError.self) { try await resumed.reserve(payload: payload) }
        #expect(try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: path)))["count"]?.intValue == 2)
    }
    @Test func modelEffortTierAndMalformedLedgerFailClosed() async throws {
        let path = "/tmp/claudex-guard-" + UUID().uuidString + ".json"
        defer { try? FileManager.default.removeItem(atPath: path) }
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
}
