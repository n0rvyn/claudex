import Foundation
import Testing
@testable import Claudex
@testable import CCRouterCore

@MainActor struct SimplifiedUXStateTests {
    @Test func invalidOnboardingStatesBlockStart() {
        for state in ["signedOut", "signingIn", "authError", "loading", "catalogError", "switched", "retired", "unsupported"] {
            let model = AppModel.visualFixture(state)
            #expect(!model.canStartDaemon)
            model.startDaemon()
            #expect(!model.daemonIsRunning)
        }
    }
    @Test func interruptionAndGatewayTransitionsRemainLocal() {
        let interrupted = AppModel.visualFixture("signingIn")
        interrupted.cancelChatGPTSignIn()
        #expect(!interrupted.isSigningIn)
        interrupted.beginChatGPTSignIn()
        #expect(interrupted.isSigningIn)
        let ready = AppModel.visualFixture("ready")
        ready.startDaemon()
        #expect(ready.daemonIsRunning && ready.showConnectionInstructions)
        ready.stopDaemon()
        #expect(!ready.daemonIsRunning)
        ready.selectChatGPTAccount("different-account")
        #expect(!ready.canStartDaemon && !ready.modelCatalogUsable)
    }
    @Test func simpleModeRetainsRulesAndReactivationValidatesThem() async {
        let model = AppModel.visualFixture("ready")
        model.useAdvancedRouting = false
        model.routingRulesDraft = [RoutingRuleDraft(keyword:"opus",upstreamModel:"retired-advanced",effort:"high",verbosity:"low")]
        await model.saveRoutingAndApply()
        #expect(model.routingSaveError == nil)
        #expect(model.currentConfiguration.routingTable.singleModelMode == true)
        #expect(model.currentConfiguration.routingTable.rules.count == 1)
        model.useAdvancedRouting = true
        await model.saveRoutingAndApply()
        #expect(model.routingSaveError != nil)
    }
    @Test func modelMappingsAndEffortAuthorityPersistWithoutStarting() async {
        let model = AppModel.visualFixture("ready")
        model.useAdvancedRouting = true
        model.prepareClaudeModelRows()
        #expect(model.routingRulesDraft.map(\.keyword) == ["opus", "sonnet", "haiku"])
        model.routingRulesDraft[0].upstreamModel = "gpt-6-sol"
        model.routingRulesDraft[0].effort = "medium"
        model.allowClaudeAdjustment = true
        await model.saveRoutingAndApply()
        #expect(model.routingSaveError == nil && !model.daemonIsRunning)
        let table = model.currentConfiguration.routingTable
        #expect(table.allowClientEffort == true && table.singleModelMode == false)
        #expect(table.resolve(for: "claude-opus").reasoningEffort == "medium")
        #expect(table.resolve(for: "claude-sonnet").upstreamModel == "gpt-6-luna")
        model.useAdvancedRouting = false
        model.allowClaudeAdjustment = false
        await model.saveRoutingAndApply()
        #expect(model.currentConfiguration.routingTable.rules == table.rules)
        #expect(model.currentConfiguration.routingTable.allowClientEffort == false)
        #expect(model.currentConfiguration.routingTable.resolve(for: "claude-opus").upstreamModel == "gpt-6-luna")
    }

    @Test func automaticSaveDebouncesAndInvalidEditsKeepLastValidMapping() async throws {
        var store: MappingRecordingStore!
        let model = AppModel.visualFixture("ready", storeFactory: { store = MappingRecordingStore($0); return store })
        model.enableMappingAutosave()
        model.fallbackRouteDraft.effort = "medium"
        model.fallbackRouteDraft.effort = "high"
        model.allowClaudeAdjustment = true
        try await Task.sleep(for: .milliseconds(650))
        #expect(store.writes == 1 && !model.daemonIsRunning)
        #expect(model.mappingSaveStatus == "Saved" && model.currentConfiguration.routingTable.allowClientEffort == true)
        let valid = model.currentConfiguration.routingTable
        model.fallbackRouteDraft.upstreamModel = "unavailable-model"
        try await Task.sleep(for: .milliseconds(650))
        #expect(model.currentConfiguration.routingTable == valid && store.writes == 1)
        #expect(model.fallbackRouteDraft.upstreamModel == "unavailable-model" && model.routingSaveError != nil)
        model.reloadPersistedConfiguration()
        #expect(model.currentConfiguration.routingTable == valid && model.routingSaveError == nil)
    }
    @Test func failedSaveAndAccountSwitchDoNotApplyOrStart() async throws {
        var store: MappingRecordingStore!
        let model = AppModel.visualFixture("ready", storeFactory: { store = MappingRecordingStore($0); return store })
        model.enableMappingAutosave(); store.failWrites = true
        let valid = model.currentConfiguration.routingTable
        model.fallbackRouteDraft.effort = "high"
        try await Task.sleep(for: .milliseconds(650))
        #expect(model.routingSaveError != nil && model.currentConfiguration.routingTable == valid)
        #expect(model.fallbackRouteDraft.effort == "high" && !model.daemonIsRunning)
        store.failWrites = false
        model.fallbackRouteDraft.effort = "medium"
        model.selectChatGPTAccount("different-account")
        try await Task.sleep(for: .milliseconds(650))
        #expect(model.currentConfiguration.routingTable == valid && !model.daemonIsRunning)
    }

}


@MainActor private final class MappingRecordingStore: ConfigurationStoring {
    var value: RouterConfiguration
    var writes = 0
    var failWrites = false
    init(_ value: RouterConfiguration) { self.value = value }
    func loadOrCreate() -> RouterConfiguration { value }
    func save(configuration: RouterConfiguration) -> RouterConfiguration {
        writes += 1
        if !failWrites { value = configuration }
        return configuration
    }
    func regenerateGatewayToken(from configuration: RouterConfiguration) -> RouterConfiguration { value }
}
