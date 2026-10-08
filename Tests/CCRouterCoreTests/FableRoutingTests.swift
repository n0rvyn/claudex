import Foundation
import Testing
@testable import CCRouterCore

struct FableRoutingTests {
    let fallback = ModelRoute(upstreamModel: "luna", reasoningEffort: "low", textVerbosity: "low")
    let fable = ModelRoute(upstreamModel: "fable-target", reasoningEffort: "medium", textVerbosity: "low")

    @Test func aliasesAndVersionedIDsMatchWithoutCatchingUnrelatedNames() {
        let table = ModelRoutingTable(rules: [], fallback: fallback, fableRoute: fable)
        for name in ["fable", "FABLE", "fable[1m]", "claude-fable-5", "claude-fable-5-1", "claude-fable-5-1[1m]", "claude-fable-5-1-20260801"] {
            #expect(table.resolve(for: name) == fable)
            #expect(table.resolveWithMatch(for: name).matchLabel == "fable")
        }
        for name in ["best", "default", "opusplan", "not-fable", "my-fable-deployment", "claude-fable-bogus", "claude-fable-5-extra", "claude-sonnet-5-5", "unknown"] {
            #expect(table.resolve(for: name) == fallback)
            #expect(table.resolveWithMatch(for: name).matchLabel == "fallback")
        }
    }
    @Test func legacyMigrationUsesFallbackAndPreservesOrderedOverrides() throws {
        let custom = ModelRoute(upstreamModel: "custom", reasoningEffort: "high", textVerbosity: "medium")
        let rules = [ModelRoutingRule(match: "claude-fable-5", route: custom), ModelRoutingRule(match: "opus", route: custom)]
        let legacy = ModelRoutingTable(rules: rules, fallback: fallback)
        let restored = try JSONDecoder().decode(ModelRoutingTable.self, from: JSONEncoder().encode(legacy))
        #expect(restored.fableRoute == nil && restored.effectiveFableRoute == fallback)
        let explicit = ModelRoutingTable(rules: restored.rules, fallback: restored.fallback, fableRoute: restored.effectiveFableRoute)
        #expect(explicit.rules == rules)
        for name in ["fable", "claude-fable-5-1", "claude-opus-5-5", "my-fable-deployment", "unknown"] {
            #expect(explicit.resolve(for: name) == legacy.resolve(for: name))
        }
        #expect(explicit.resolve(for: "claude-fable-5-1") == custom)
        #expect(ModelRoutingTable(rules: rules, fallback: fallback, singleModelMode: true, fableRoute: fable).resolve(for: "fable") == fallback)
    }
    @Test func explicitMappingAndLegacyRulesSurviveActualConfigurationSaveReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RouterConfigurationStore(environment: ["CC_ROUTER_CONFIG_PATH": root.appendingPathComponent("config.json").path], homeDirectoryURL: root)
        let custom = ModelRoutingRule(match: "special", route: fallback)
        let table = ModelRoutingTable(rules: [custom], fallback: fallback, singleModelMode: false, allowClientEffort: true, fableRoute: fable)
        let config = RouterConfiguration(host: "127.0.0.1", port: 4317, healthPath: "/health", messagesPath: "/v1/messages", countTokensPath: "/v1/messages/count_tokens", responsesURL: "https://api.openai.com/v1/responses", routingTable: table, advisorRoute: fallback, gatewayAuthToken: "fixture-only", gatewayAuthHeader: "x-api-key", subscriptionAuthFilePath: root.appendingPathComponent("unused.json").path, configurationPath: root.appendingPathComponent("config.json").path, configurationWarning: nil)
        _ = try store.saveChecked(configuration: config)
        let restored = store.loadOrCreate().routingTable
        #expect(restored == table)
        #expect(restored.resolve(for: "claude-fable-5-1") == fable)
        #expect(restored.rules == [custom] && restored.allowClientEffort == true)
    }
}
