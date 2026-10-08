import Foundation
import Testing
@testable import CCRouterCore

struct SimpleRoutingModeTests {
    let selected = ModelRoute(upstreamModel: "selected-model", reasoningEffort: "low", textVerbosity: "low")
    let advanced = ModelRoute(upstreamModel: "advanced-model", reasoningEffort: "high", textVerbosity: "medium")

    @Test func aliasesUseExplicitModelAndAdvancedRulesSurviveRoundTrip() throws {
        let table = ModelRoutingTable(rules: [ModelRoutingRule(match: "opus", route: advanced)], fallback: selected, singleModelMode: true)
        let restored = try JSONDecoder().decode(ModelRoutingTable.self, from: JSONEncoder().encode(table))
        for alias in ["claude-opus", "claude-sonnet", "claude-haiku", "arbitrary-model"] {
            #expect(restored.resolve(for: alias) == selected)
            #expect(restored.resolveWithMatch(for: alias).route == selected)
        }
        #expect(restored.rules == table.rules)
        let reenabled = ModelRoutingTable(rules: restored.rules, fallback: restored.fallback, singleModelMode: false)
        #expect(reenabled.resolve(for: "claude-opus") == advanced)
        #expect(reenabled.resolve(for: "claude-haiku") == selected)
    }
    @Test func legacyJSONKeepsOrderedRouting() throws {
        let data = Data(#"{"rules":[{"match":"opus","route":{"upstreamModel":"advanced-model","reasoningEffort":"high","textVerbosity":"medium"}}],"fallback":{"upstreamModel":"selected-model","reasoningEffort":"low","textVerbosity":"low"}}"#.utf8)
        let table = try JSONDecoder().decode(ModelRoutingTable.self, from: data)
        #expect(table.singleModelMode == nil)
        #expect(table.resolve(for: "claude-opus") == advanced)
    }
}
