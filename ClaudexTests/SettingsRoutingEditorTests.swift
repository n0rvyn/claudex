import Foundation
@testable import CCRouterCore
@testable import Claudex
import Testing

@MainActor
struct SettingsRoutingEditorTests {
    // MARK: Add rule

    @Test
    func addRuleIncreasesDraftCount() {
        let model = AppModelTestHelper.makeSUT()
        let initialCount = model.routingRulesDraft.count
        model.addRoutingRule()
        #expect(model.routingRulesDraft.count == initialCount + 1)
    }

    @Test
    func addRuleAppendsBlankKeyword() {
        let model = AppModelTestHelper.makeSUT()
        model.addRoutingRule()
        let lastRule = model.routingRulesDraft.last!
        #expect(lastRule.keyword == "")
    }

    @Test
    func addRuleSetsDefaultUpstreamModel() {
        let model = AppModelTestHelper.makeSUT()
        model.addRoutingRule()
        let lastRule = model.routingRulesDraft.last!
        #expect(lastRule.upstreamModel == "gpt-5.4")
    }

    // MARK: Edit rule

    @Test
    func editRuleKeywordUpdatesDraft() {
        let model = AppModelTestHelper.makeSUT()
        model.addRoutingRule()
        let ruleID = model.routingRulesDraft.last!.id

        model.routingRulesDraft[0].keyword = "opus"
        #expect(model.routingRulesDraft.first?.keyword == "opus")
    }

    @Test
    func editRuleUpstreamModelUpdatesDraft() {
        let model = AppModelTestHelper.makeSUT()
        model.addRoutingRule()
        model.routingRulesDraft[0].upstreamModel = "gpt-5.4-mini"
        #expect(model.routingRulesDraft.first?.upstreamModel == "gpt-5.4-mini")
    }

    // MARK: Delete rule

    @Test
    func deleteRuleDecreasesDraftCount() {
        let model = AppModelTestHelper.makeSUT()
        model.addRoutingRule()
        model.addRoutingRule()
        let idToDelete = model.routingRulesDraft[0].id
        let countAfterAdd = model.routingRulesDraft.count
        model.removeRoutingRule(id: idToDelete)
        #expect(model.routingRulesDraft.count == countAfterAdd - 1)
    }

    @Test
    func deleteRuleRemovesCorrectRule() {
        let model = AppModelTestHelper.makeSUT()
        model.addRoutingRule()
        model.routingRulesDraft[0].keyword = "target-keyword"
        let idToDelete = model.routingRulesDraft[0].id
        model.removeRoutingRule(id: idToDelete)
        #expect(model.routingRulesDraft.contains { $0.keyword == "target-keyword" } == false)
    }

    // MARK: Move rule

    @Test
    func moveRuleReordersDraftArray() {
        let model = AppModelTestHelper.makeSUT()
        model.addRoutingRule()
        model.addRoutingRule()
        model.routingRulesDraft[0].keyword = "first"
        model.routingRulesDraft[1].keyword = "second"

        model.moveRoutingRule(from: IndexSet(integer: 1), to: 0)

        #expect(model.routingRulesDraft[0].keyword == "second")
        #expect(model.routingRulesDraft[1].keyword == "first")
    }

    // MARK: Fallback route draft

    @Test
    func fallbackRouteDraftStartsFromConfiguration() {
        let model = AppModelTestHelper.makeSUT()
        let fallback = model.fallbackRouteDraft
        #expect(fallback.upstreamModel == "gpt-5.4")
    }

    @Test
    func editFallbackRouteDraftUpdatesPublishedValue() {
        let model = AppModelTestHelper.makeSUT()
        model.fallbackRouteDraft.upstreamModel = "gpt-5.4-mini"
        #expect(model.fallbackRouteDraft.upstreamModel == "gpt-5.4-mini")
    }

    // MARK: Advisor route draft

    @Test
    func advisorRouteDraftStartsFromConfiguration() {
        let model = AppModelTestHelper.makeSUT()
        let advisor = model.advisorRouteDraft
        #expect(advisor.upstreamModel == "gpt-5.4")
    }

    @Test
    func editAdvisorRouteDraftUpdatesPublishedValue() {
        let model = AppModelTestHelper.makeSUT()
        model.advisorRouteDraft.effort = "low"
        #expect(model.advisorRouteDraft.effort == "low")
    }

    // MARK: saveRoutingAndApply integration

    @Test
    func saveRoutingAndApplyInvokesStoreAndRoutingApplier() async {
        let store = InMemoryConfigurationStore(initial: .defaultTestConfig())
        let recorder = RoutingApplierRecorder()

        let model = AppModel(
            configurationStore: store,
            routingUpdateApplier: { [recorder] table, advisor in
                await recorder.record(table: table, advisor: advisor)
            }
        )

        model.addRoutingRule()
        model.routingRulesDraft[0].keyword = "opus"
        model.routingRulesDraft[0].upstreamModel = "gpt-5.4"
        model.fallbackRouteDraft.upstreamModel = "gpt-5.4-mini"
        model.advisorRouteDraft.upstreamModel = "gpt-5.4-mini"

        await model.saveRoutingAndApply()

        #expect(store.saveCallCount == 1)
        let lastApplied = await recorder.lastApplied
        #expect(lastApplied != nil)
        #expect(lastApplied?.table.rules.count == 1)
        #expect(lastApplied?.table.rules.first?.match == "opus")
        #expect(lastApplied?.table.rules.first?.route.upstreamModel == "gpt-5.4")
        #expect(lastApplied?.table.fallback.upstreamModel == "gpt-5.4-mini")
        #expect(lastApplied?.advisor.upstreamModel == "gpt-5.4-mini")
        #expect(model.routingSaveError == nil)
    }

    @Test
    func saveRoutingAndApplyRejectsEmptyKeyword() async {
        let store = InMemoryConfigurationStore(initial: .defaultTestConfig())
        let recorder = RoutingApplierRecorder()

        let model = AppModel(
            configurationStore: store,
            routingUpdateApplier: { [recorder] table, advisor in
                await recorder.record(table: table, advisor: advisor)
            }
        )

        model.addRoutingRule()
        // keyword stays empty (default)

        await model.saveRoutingAndApply()

        #expect(model.routingSaveError != nil)
        #expect(store.saveCallCount == 0)
        let lastApplied = await recorder.lastApplied
        #expect(lastApplied == nil)
    }
}

// MARK: - Test helper

@MainActor
enum AppModelTestHelper {
    static func makeSUT() -> AppModel {
        AppModel()
    }
}

// MARK: - Test doubles for save integration

private extension RouterConfiguration {
    static func defaultTestConfig() -> RouterConfiguration {
        let fallback = ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "medium", textVerbosity: "medium")
        let advisor = ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "medium", textVerbosity: "medium")
        return RouterConfiguration(
            host: "127.0.0.1",
            port: 4317,
            healthPath: "/health",
            messagesPath: "/v1/messages",
            countTokensPath: "/v1/messages/count_tokens",
            responsesURL: "https://example.invalid/v1/responses",
            routingTable: ModelRoutingTable(rules: [], fallback: fallback),
            advisorRoute: advisor,
            pendingToolTurnTTLSeconds: 300,
            advisorContextMessageLimit: 8,
            gatewayAuthToken: "test-token",
            gatewayAuthHeader: "x-mb-token",
            subscriptionAuthFilePath: "/tmp/does-not-exist.json",
            subscriptionAuthBookmarkData: nil,
            configurationPath: "/tmp/mb-test-config.json",
            configurationWarning: nil
        )
    }
}

final class InMemoryConfigurationStore: ConfigurationStoring {
    private(set) var current: RouterConfiguration
    private(set) var saveCallCount = 0

    init(initial: RouterConfiguration) {
        self.current = initial
    }

    func loadOrCreate() -> RouterConfiguration {
        current
    }

    @discardableResult
    func save(configuration: RouterConfiguration) -> RouterConfiguration {
        saveCallCount += 1
        current = configuration
        return configuration
    }

    func regenerateGatewayToken(from configuration: RouterConfiguration) -> RouterConfiguration {
        current
    }
}

actor RoutingApplierRecorder {
    struct AppliedUpdate {
        let table: ModelRoutingTable
        let advisor: ModelRoute
    }

    private(set) var lastApplied: AppliedUpdate?

    func record(table: ModelRoutingTable, advisor: ModelRoute) {
        lastApplied = AppliedUpdate(table: table, advisor: advisor)
    }
}
