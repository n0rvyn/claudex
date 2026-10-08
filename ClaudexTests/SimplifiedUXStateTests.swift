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
        model.routingRulesDraft = [RoutingRuleDraft(keyword:"opus",upstreamModel:"retired-advanced",effort:"high",verbosity:"low")]
        await model.saveRoutingAndApply()
        #expect(model.routingSaveError == nil)
        #expect(model.currentConfiguration.routingTable.singleModelMode == true)
        #expect(model.currentConfiguration.routingTable.rules.count == 1)
        model.useAdvancedRouting = true
        await model.saveRoutingAndApply()
        #expect(model.routingSaveError != nil)
    }
}
