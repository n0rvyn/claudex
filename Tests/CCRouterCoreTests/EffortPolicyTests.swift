import Foundation
import Testing
@testable import CCRouterCore

struct EffortPolicyTests {
    let route = ModelRoute(upstreamModel: "fixture", reasoningEffort: "high", textVerbosity: "low")
    func catalog(_ efforts: [String] = ["low", "medium", "high"], account: String = "a", date: Date = Date()) -> SIWCModelCatalogSnapshot {
        SIWCModelCatalogSnapshot(accountID: account, fetchedAt: date, models: [SIWCModelSummary(id: "fixture", label: "Fixture", accountID: account, details: JSONObject.from(["supported_reasoning_levels": .array(efforts.map { .object(JSONObject.from(["effort": .string($0)])) })]))])
    }
    @Test(arguments: ["low", "medium", "high", "xhigh", "max", "auto"])
    func boundsAndDefault(_ request: String) throws {
        let result = try EffortPolicy.resolve(route: route, requested: request, thinking: nil, catalog: catalog(), accountID: "a")
        #expect(result.reasoningEffort == (["low", "medium"].contains(request) ? request : "high"))
        #expect(result.upstreamModel == route.upstreamModel)
    }
    @Test func missingUsesExplicitDefault() throws {
        #expect(try EffortPolicy.resolve(route: route, requested: nil, thinking: nil, catalog: catalog(), accountID: "a") == route)
    }
    @Test func unsupportedLevelClampsDownNeverUp() throws {
        #expect(try EffortPolicy.resolve(route: route, requested: "medium", thinking: nil, catalog: catalog(["low", "high"]), accountID: "a").reasoningEffort == "low")
        #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: route, requested: "low", thinking: nil, catalog: catalog(["high"]), accountID: "a") }
    }
    @Test(arguments: ["ultra", "none", "minimal", "adaptive", "mystery"])
    func unknownAndNonScalarEffortsRejected(_ request: String) {
        #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: route, requested: request, thinking: nil, catalog: catalog(), accountID: "a") }
    }
    @Test func budgetAndDisabledThinkingHaveNoOrdinalEquivalent() throws {
        for value in [JSONObject.from(["type": .string("enabled"), "budget_tokens": .number(4096)]), JSONObject.from(["type": .string("disabled")])] {
            #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: route, requested: "low", thinking: value, catalog: catalog(), accountID: "a") }
        }
        #expect(try EffortPolicy.resolve(route: route, requested: "low", thinking: JSONObject.from(["type": .string("adaptive")]), catalog: catalog(), accountID: "a").reasoningEffort == "low")
    }
    @Test func accountAndMissingMetadataFailClosed() {
        for value in [catalog(account: "b"), catalog([])] {
            #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: route, requested: "low", thinking: nil, catalog: value, accountID: "a") }
        }
        let switched = ModelRoute(upstreamModel: "other", reasoningEffort: "high", textVerbosity: "low")
        #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: switched, requested: "low", thinking: nil, catalog: catalog(), accountID: "a") }
    }
    func input(_ messages: String, top: String = "high") throws -> AnthropicMessagesRequest {
        try JSONDecoder().decode(AnthropicMessagesRequest.self, from: Data(("{\"model\":\"claude\",\"output_config\":{\"effort\":\"" + top + "\"},\"messages\":" + messages + "}").utf8))
    }
    @Test func latestMessageEffortOverridesTopAtNextUserAndPersists() throws {
        let messages = #"[{"role":"system","content":[],"output_config":{"effort":"low"}},{"role":"user","content":"one"},{"role":"assistant","content":"answer"},{"role":"system","content":[],"output_config":{"effort":"medium"}},{"role":"user","content":"two"},{"role":"assistant","content":"answer"},{"role":"system","content":[],"output_config":{"effort":"max"}}]"#
        let value = try input(messages)
        #expect(try EffortPolicy.clientEffort(value, headers: ["anthropic-beta": EffortPolicy.messageBeta]) == "medium")
        #expect(throws: SIWCError.self) { try EffortPolicy.clientEffort(value, headers: [:]) }
        #expect(try SIWCBridge.payload(value, route: route).array("input")?.count == 4)
    }
    @Test func malformedMessageControlsReject() throws {
        for message in [#"[{"role":"user","content":"x","output_config":{"effort":"low"}}]"#, #"[{"role":"system","content":"prompt","output_config":{"effort":"low"}}]"#, #"[{"role":"system","content":[],"output_config":{"effort":"low","other":true}}]"#] {
            let value = try input(message)
            #expect(throws: SIWCError.self) { try EffortPolicy.clientEffort(value, headers: ["anthropic-beta": EffortPolicy.messageBeta]) }
        }
    }
    @Test func routingPolicyRoundTripsAndLegacyIsFixed() throws {
        let table = ModelRoutingTable(rules: [], fallback: route, singleModelMode: true, allowClientEffort: true)
        #expect(try JSONDecoder().decode(ModelRoutingTable.self, from: JSONEncoder().encode(table)) == table)
        #expect(ModelRoutingTable(rules: [], fallback: route).allowClientEffort != true)
    }
    @Test func installedClaudeCodePerTurnBetaKeepsStrictEffortControlSemantics() throws {
        let value = try input(#"[{"role":"system","content":[],"output_config":{"effort":"low"}},{"role":"user","content":"TEXT_OK"}]"#)
        let observed = "claude-code-20250219,mid-conversation-system-2026-04-07,per-turn-control-2026-07-01,effort-2025-11-24"
        #expect(try EffortPolicy.clientEffort(value, headers: ["anthropic-beta": observed]) == "low")
        #expect(try EffortPolicy.resolve(route: route, requested: EffortPolicy.clientEffort(value, headers: ["anthropic-beta": observed]), thinking: JSONObject.from(["type": .string("adaptive"), "display": .string("updates")]), catalog: catalog(), accountID: "a").reasoningEffort == "low")
        #expect(throws: SIWCError.self) { try EffortPolicy.clientEffort(value, headers: ["anthropic-beta": "effort-2025-11-24"]) }
        let malformed = try input(#"[{"role":"user","content":"not empty","output_config":{"effort":"low"}},{"role":"user","content":"x"}]"#)
        #expect(throws: SIWCError.self) { try EffortPolicy.clientEffort(malformed, headers: ["anthropic-beta": observed]) }
    }

    @Test func nativeTailEffortAppliesToCurrentUserWhilePublicControlWaits() throws {
        let value = try input(#"[{"role":"user","content":"one"},{"role":"system","content":[],"output_config":{"effort":"low"}}]"#)
        #expect(try EffortPolicy.clientEffort(value, headers: ["anthropic-beta": EffortPolicy.claudeCodeMessageBeta]) == "low")
        #expect(try EffortPolicy.clientEffort(value, headers: ["anthropic-beta": EffortPolicy.messageBeta]) == "high")
    }
    @Test func staleVerifiedCapabilitiesRetainOrdinalEffortCeiling() throws {
        let result = try EffortPolicy.resolve(route: route, requested: "low", thinking: nil,
            catalog: catalog(date: Date().addingTimeInterval(-3601)), accountID: "a")
        #expect(result.reasoningEffort == "low")
    }

}
