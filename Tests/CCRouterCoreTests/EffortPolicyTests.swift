import Foundation
import Testing
@testable import CCRouterCore

struct EffortPolicyTests {
    let route = ModelRoute(upstreamModel: "fixture", reasoningEffort: "high", textVerbosity: "low")
    func catalog(_ efforts: [String] = ["low", "medium", "high"], account: String = "a", date: Date = Date()) -> SIWCModelCatalogSnapshot {
        SIWCModelCatalogSnapshot(accountID: account, fetchedAt: date, models: [SIWCModelSummary(id: "fixture", label: "Fixture", accountID: account, details: JSONObject.from(["default_reasoning_level": .string("high"), "supported_reasoning_levels": .array(efforts.map { .object(JSONObject.from(["effort": .string($0)])) })]))])
    }
    @Test(arguments: ["low", "medium", "high"])
    func supportedExplicitIntentSurvivesWithoutCap(_ request: String) throws {
        let result = try EffortPolicy.resolve(route: route, requested: request, thinking: nil, catalog: catalog(), accountID: "a")
        #expect(result.reasoningEffort == request)
        #expect(result.upstreamModel == route.upstreamModel)
    }
    @Test func missingUsesExplicitDefault() throws {
        #expect(try EffortPolicy.resolve(route: route, requested: nil, thinking: nil, catalog: catalog(), accountID: "a") == route)
    }
    @Test func unsupportedLevelClampsDownNeverUp() throws {
        #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: route, requested: "medium", thinking: nil, catalog: catalog(["low", "high"]), accountID: "a") }
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
    @Test func nativeEffortWithTextDoesNotRequireSeparateSystemBeta() throws {
        let value = try input(#"[{"role":"user","content":"one"},{"role":"system","content":[{"type":"text","text":"Retain this instruction"}],"output_config":{"effort":"low"}}]"#)
        #expect(try EffortPolicy.clientEffort(value, headers: ["anthropic-beta": EffortPolicy.claudeCodeMessageBeta]) == "low")
        #expect(try SIWCBridge.payload(value, route: route).array("input")?.count == 2)
    }
    @Test func staleVerifiedCapabilitiesRetainOrdinalEffortCeiling() throws {
        let result = try EffortPolicy.resolve(route: route, requested: "low", thinking: nil,
            catalog: catalog(date: Date().addingTimeInterval(-3601)), accountID: "a")
        #expect(result.reasoningEffort == "low")
    }

    @Test func exhaustiveSupportedIntentAndExplicitCaps() throws {
        let all = EffortPolicy.levels
        for fixed in all {
            let uncapped = ModelRoute(upstreamModel: "fixture", reasoningEffort: fixed, textVerbosity: "low")
            for requested in all {
                #expect(try EffortPolicy.resolve(route: uncapped, requested: requested, thinking: nil, catalog: catalog(all), accountID: "a").reasoningEffort == requested)
                for cap in all {
                    let capped = ModelRoute(upstreamModel: "fixture", reasoningEffort: fixed, textVerbosity: "low", maxAllowedEffort: cap)
                    if all.firstIndex(of: requested)! <= all.firstIndex(of: cap)! {
                        #expect(try EffortPolicy.resolve(route: capped, requested: requested, thinking: nil, catalog: catalog(all), accountID: "a").reasoningEffort == requested)
                    } else {
                        #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: capped, requested: requested, thinking: nil, catalog: catalog(all), accountID: "a") }
                    }
                }
            }
        }
    }

    @Test func absentAndAutoUseVerifiedTargetDefaultOrExplicitFallback() throws {
        for requested in [nil, "auto"] as [String?] {
            let fixedLow = ModelRoute(upstreamModel: "fixture", reasoningEffort: "low", textVerbosity: "low")
            #expect(try EffortPolicy.resolve(route: fixedLow, requested: requested, thinking: nil, catalog: catalog(), accountID: "a").reasoningEffort == "high")
            let fallback = ModelRoute(upstreamModel: "fixture", reasoningEffort: "low", textVerbosity: "low", defaultClientEffort: "medium")
            #expect(try EffortPolicy.resolve(route: fallback, requested: requested, thinking: nil, catalog: catalog(), accountID: "a").reasoningEffort == "medium")
            let capped = ModelRoute(upstreamModel: "fixture", reasoningEffort: "low", textVerbosity: "low", maxAllowedEffort: "low")
            #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: capped, requested: requested, thinking: nil, catalog: catalog(), accountID: "a") }
        }
    }

    @Test func unknownDefaultAndInvalidPolicyRejectExplicitly() throws {
        let unknown = SIWCModelCatalogSnapshot(accountID: "a", fetchedAt: Date(), models: [SIWCModelSummary(id: "fixture", label: "Fixture", accountID: "a", details: JSONObject.from(["supported_reasoning_levels": .array([.object(JSONObject.from(["effort": .string("low")]))])]))])
        #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: route, requested: nil, thinking: nil, catalog: unknown, accountID: "a") }
        #expect(try EffortPolicy.resolve(route: route, requested: "low", thinking: nil, catalog: unknown, accountID: "a").reasoningEffort == "low")
        for cap in ["ultra", "", "HIGH"] {
            let invalid = ModelRoute(upstreamModel: "fixture", reasoningEffort: "low", textVerbosity: "low", maxAllowedEffort: cap)
            #expect(throws: SIWCError.self) { try EffortPolicy.resolve(route: invalid, requested: "low", thinking: nil, catalog: catalog(), accountID: "a") }
        }
    }

    @Test func supportedCapabilityIsCheckedBeforeCapAndNeverDowngraded() throws {
        let capped = ModelRoute(upstreamModel: "fixture", reasoningEffort: "low", textVerbosity: "low", maxAllowedEffort: "low")
        do {
            _ = try EffortPolicy.resolve(route: capped, requested: "xhigh", thinking: nil, catalog: catalog(), accountID: "a")
            Issue.record("unsupported target intent was accepted")
        } catch SIWCError.unsupported(let reason) { #expect(reason.hasPrefix("effort_target_unsupported:")) }
    }

    @Test func legacyFollowMigrationPreservesEveryRouteLimitAndDefault() throws {
        let json = #"{"rules":[{"match":"opus","route":{"upstreamModel":"fixture","reasoningEffort":"low","textVerbosity":"high"}}],"fallback":{"upstreamModel":"fixture","reasoningEffort":"medium","textVerbosity":"low"},"fableRoute":{"upstreamModel":"fixture","reasoningEffort":"high","textVerbosity":"low"},"allowClientEffort":true}"#
        let table = try JSONDecoder().decode(ModelRoutingTable.self, from: Data(json.utf8))
        for route in table.rules.map(\.route) + [table.fallback, table.effectiveFableRoute] {
            #expect(route.maxAllowedEffort == route.reasoningEffort)
            #expect(route.defaultClientEffort == route.reasoningEffort)
        }
        #expect(table.effortPolicyVersion == 2)
        #expect(try JSONDecoder().decode(ModelRoutingTable.self, from: JSONEncoder().encode(table)) == table)
    }

    @Test func versionTwoNullAndAbsentCapsRemainUncapped() throws {
        for field in ["", ",\"maxAllowedEffort\":null"] {
            let json = "{\"effortPolicyVersion\":2,\"allowClientEffort\":true,\"rules\":[],\"fallback\":{\"upstreamModel\":\"fixture\",\"reasoningEffort\":\"low\",\"textVerbosity\":\"low\"" + field + "}}"
            let table = try JSONDecoder().decode(ModelRoutingTable.self, from: Data(json.utf8))
            #expect(table.fallback.maxAllowedEffort == nil)
            #expect(table.fallback.defaultClientEffort == nil)
            #expect(try JSONDecoder().decode(ModelRoutingTable.self, from: JSONEncoder().encode(table)).fallback.maxAllowedEffort == nil)
        }
    }

    @Test func everyTargetCapabilitySubsetRejectsRatherThanNormalizes() throws {
        let all = EffortPolicy.levels
        for mask in 1..<(1 << all.count) {
            let supported = all.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil }
            for requested in all {
                for cap in [nil] + all.map(Optional.some) {
                    let candidate = ModelRoute(upstreamModel: "fixture", reasoningEffort: "low", textVerbosity: "low", maxAllowedEffort: cap)
                    let underCap = cap.map { all.firstIndex(of: requested)! <= all.firstIndex(of: $0)! } ?? true
                    if supported.contains(requested) && underCap {
                        #expect(try EffortPolicy.resolve(route: candidate, requested: requested, thinking: nil, catalog: catalog(supported), accountID: "a").reasoningEffort == requested)
                    } else {
                        do {
                            _ = try EffortPolicy.resolve(route: candidate, requested: requested, thinking: nil, catalog: catalog(supported), accountID: "a")
                            Issue.record("unsupported intent or cap violation was accepted")
                        } catch SIWCError.unsupported(let reason) {
                            #expect(reason.hasPrefix(supported.contains(requested) ? "effort_cap_exceeded:" : "effort_target_unsupported:"))
                        }
                    }
                }
            }
        }
    }

}
