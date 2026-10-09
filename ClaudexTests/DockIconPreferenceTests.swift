import AppKit
import Testing
@testable import Claudex

@MainActor struct DockIconPreferenceTests {
    @Test func missingPreferenceShowsDockIconAtLaunch() {
        let defaults = UserDefaults(suiteName: "DockIconTests.\(UUID().uuidString)")!
        var policies: [NSApplication.ActivationPolicy] = []
        let preference = DockIconPreference(defaults: defaults, applyPolicy: { policies.append($0) }, captureForegroundWindow: { nil })
        #expect(preference.showDockIcon)
        #expect(policies.isEmpty)
        preference.apply()
        #expect(policies == [.regular])
    }

    @Test func changesApplyImmediatelyAndPersist() {
        let name = "DockIconTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var policies: [NSApplication.ActivationPolicy] = []
        let preference = DockIconPreference(defaults: defaults, applyPolicy: { policies.append($0) }, captureForegroundWindow: { nil })
        preference.showDockIcon = false
        #expect(policies == [.accessory])
        #expect(defaults.object(forKey: DockIconPreference.key) as? Bool == false)
        preference.showDockIcon = true
        #expect(policies == [.accessory, .regular])
        #expect(defaults.object(forKey: DockIconPreference.key) as? Bool == true)
    }

    @Test func savedHiddenPreferenceAppliesOnNextLaunch() {
        let name = "DockIconTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = DockIconPreference(defaults: defaults, applyPolicy: { _ in }, captureForegroundWindow: { nil })
        first.showDockIcon = false
        var policies: [NSApplication.ActivationPolicy] = []
        let relaunched = DockIconPreference(defaults: defaults, applyPolicy: { policies.append($0) }, captureForegroundWindow: { nil })
        #expect(!relaunched.showDockIcon)
        relaunched.apply()
        #expect(policies == [.accessory])
    }
    @Test func foregroundWindowIsCapturedBeforePolicyAndRestoredAfterBothTransitions() {
        let name = "DockIconTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var events: [String] = []
        let preference = DockIconPreference(defaults: defaults, applyPolicy: { policy in
            events.append(policy == .regular ? "regular" : "accessory")
        }, captureForegroundWindow: {
            events.append("capture")
            return { events.append("restore") }
        })
        preference.showDockIcon = false
        preference.showDockIcon = true
        #expect(events == ["capture", "accessory", "restore", "capture", "regular", "restore"])
    }
    @Test func backgroundTransitionNeverRestoresOrActivatesAWindow() {
        let name = "DockIconTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var applied: [NSApplication.ActivationPolicy] = []
        let preference = DockIconPreference(defaults: defaults, applyPolicy: { applied.append($0) }, captureForegroundWindow: { nil })
        preference.showDockIcon = false
        preference.showDockIcon = true
        #expect(applied == [.accessory, .regular])
    }

}
