import Foundation
@testable import CCRouterCore
import Testing

struct ModelRoutingTests {
    private static func makeRoute(_ model: String) -> ModelRoute {
        ModelRoute(upstreamModel: model, reasoningEffort: "xhigh", textVerbosity: "low")
    }

    private static func makeTable() -> ModelRoutingTable {
        ModelRoutingTable(
            rules: [
                ModelRoutingRule(match: "opus",   route: makeRoute("gpt-5.4")),
                ModelRoutingRule(match: "sonnet", route: makeRoute("gpt-5.4")),
                ModelRoutingRule(match: "haiku",  route: makeRoute("gpt-5.3-codex")),
            ],
            fallback: makeRoute("gpt-5.4-fallback")
        )
    }

    @Test func claudeOpus47MatchesOpusRule() {
        let route = Self.makeTable().resolve(for: "claude-opus-4-7")
        #expect(route.upstreamModel == "gpt-5.4")
    }

    @Test func claudeSonnet46MatchesSonnetRule() {
        let route = Self.makeTable().resolve(for: "claude-sonnet-4-6")
        #expect(route.upstreamModel == "gpt-5.4")
    }

    @Test func claudeHaiku45MatchesHaikuRule() {
        let route = Self.makeTable().resolve(for: "claude-haiku-4-5-20251001")
        #expect(route.upstreamModel == "gpt-5.3-codex")
    }

    @Test func uppercaseMixedCaseStillMatches() {
        let route = Self.makeTable().resolve(for: "Claude-Opus-4-7")
        #expect(route.upstreamModel == "gpt-5.4")
    }

    @Test func noMatchFallsThroughToFallback() {
        let route = Self.makeTable().resolve(for: "some-unknown-model")
        #expect(route.upstreamModel == "gpt-5.4-fallback")
    }

    @Test func emptyRulesAlwaysReturnsFallback() {
        let table = ModelRoutingTable(rules: [], fallback: Self.makeRoute("only-fallback"))
        #expect(table.resolve(for: "opus").upstreamModel == "only-fallback")
    }

    @Test func firstRuleWinsWhenMultipleMatch() {
        // "opus" contains both "opus" and "us"; verify the first matching rule wins.
        let table = ModelRoutingTable(
            rules: [
                ModelRoutingRule(match: "opus", route: Self.makeRoute("first-wins")),
                ModelRoutingRule(match: "us",   route: Self.makeRoute("should-not-reach")),
            ],
            fallback: Self.makeRoute("fallback")
        )
        #expect(table.resolve(for: "claude-opus-4-7").upstreamModel == "first-wins")
    }

    @Test func defaultTableHasExpectedShape() {
        let table = ModelRoutingTable.defaultTable
        #expect(table.rules.count == 3)
        #expect(table.resolve(for: "claude-opus-4-7").upstreamModel == "gpt-5.4")
        #expect(table.resolve(for: "claude-haiku-4-5-20251001").upstreamModel == "gpt-5.3-codex-spark")
        #expect(table.fallback.upstreamModel == "gpt-5.4")
    }

    @Test func codableRoundTripPreservesTable() throws {
        let original = Self.makeTable()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelRoutingTable.self, from: data)
        #expect(decoded == original)
    }
}
