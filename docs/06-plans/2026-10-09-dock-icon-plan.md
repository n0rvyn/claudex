---
type: plan
status: active
contract_version: 2
tags: [macos, dock, settings]
refs: []
---
# Dock icon preference

**Goal:** Add the user-approved Show Dock icon switch in Settings → General → Appearance beside Theme.
**Architecture:** One observable app-shell preference owns persistence and immediate AppKit activation policy changes. An application delegate applies the saved preference after launch. Both settings shortcuts retain the accessory policy when opening windows.
**Tech Stack:** SwiftUI, AppKit, UserDefaults, Swift Testing.
**Design doc:** none; user approved the proposed location and behavior with “agree. get this done.”
**Design analysis:** none
**Crystal file:** none
**Bug diagnosis:** not applicable
**Threat model:** not applicable
**Pre-flight risks:** Hidden-mode settings focus requires real app verification; do not copy the knowledge-base workaround that temporarily restores the Dock icon.
**Project context contract:** missing
**Project health:** yellow: large existing UI files; pre-existing untracked AGENTS.md. No unrelated restructuring.

## Impact Map
**User path:** General → Show Dock icon; menu bar → Settings / Activity.
**Data path:** persisted Boolean (absent = true) → shared observable preference → regular/accessory policy at launch and on every toggle.
**Shared surfaces:** shipping app shell only.
**Existing consumers:** ClaudexApp, GeneralSettingsTab, menu-bar settings shortcuts. New API, no old API renaming.
**Must remain unchanged:** menu panel layout, gateway runtime, sign-in, models, other settings, LSUIElement. No live inference; do not terminate the user's existing app.
**Regression checks:** default-on, toggle both ways, reload persistence, hidden-mode Settings/Activity and focus, close/reopen, relaunch; offline fixture only.

## Decisions
None. All user-visible choices were approved.

## Verification
- **Verdict:** Approved
- **Date:** 2026-10-09
- **Advisories:** Check saved-false launch application, nonzero xcresult test count, and keyboard focus of hidden windows including an obscured existing window.
- **User constraint:** “test with a new port incase 中断 the current running app's 流量。FYI。” Use 14317 for the test instance; preserve the live 4317 owner. Offline UI fixture does not start a listener.

<!-- section: task-1 keywords: DockIconPreference, ClaudexApp, SettingsView, AppKit -->
### Task 1: Persistent Dock visibility switch
**Depends on:** None
**Maps to Impact Map:** User path, Data path, Shared surfaces, Existing consumers, Must remain unchanged, Regression checks
**Files:**
- Create: `Claudex/DockIconPreference.swift`
- Modify: `Claudex/ClaudexApp.swift`
- Modify: `Claudex/SettingsView.swift`
- Modify if necessary for hidden-mode focus: `Claudex/ContentView.swift`
- Create: `ClaudexTests/DockIconPreferenceTests.swift`
**Expected outcome:** Native switch defaults on, immediately hides/restores Dock icon and persists across launches. Hidden windows remain usable without restoring the icon.
**Non-goals:** No gateway or menu panel changes.
**Touched surface:** app lifetime and General Appearance section.
**Regression shield:** Use injected UserDefaults and policy application in tests; an offline fixture app for GUI testing; preserve the user's app process and preferences.
**Task Contract:**
- Automated verify: compile and run focused DockIconPreferenceTests, covering absent/default, false/true policy transitions and reload.
- Expected behavior: Show Dock icon keeps the menu bar available and remembers the selected state; Settings and Activity still open while hidden.
- Real path verify: launch an isolated-bundle offline fixture, interact through the menu-bar shortcuts and native switch, inspect Dock application membership, capture each navigated window, relaunch and inspect persisted state.
- Manual/device verify: none unless GUI automation is denied.
**Steps:**
1. Add focused tests for absent preference = true, false → accessory, true → regular, and a second instance reading stored false. Run first to establish failing compilation before the new type exists.
2. Add a main-actor ObservableObject with an injected UserDefaults and policy closure; store `claudex.showDockIcon`, default true. Apply after applicationDidFinishLaunching and synchronously on changes.
3. Supply the shared preference to the Settings scene and add a labels-hidden native switch in an MBField labelled Show Dock icon with a note that the menu bar remains available.
4. Verify actual window activation in accessory mode. If needed, activate and front the existing Settings window without changing activation policy.
**Verify:**
Run: `xcodebuild test -project Claudex.xcodeproj -scheme Claudex -destination 'platform=macOS' -only-testing:ClaudexTests/DockIconPreferenceTests -derivedDataPath /tmp/ClaudexDockBuild -resultBundlePath /tmp/ClaudexDockTests.xcresult`
Expected: all preference tests pass; real app evidence demonstrates toggle, hidden window access and persisted startup.
<!-- /section -->

## October 9 repair completion evidence

The owner explicitly expanded the task to compaction replay, restart readiness and native Quit. Canonical verified facts and regression boundaries: [Align Claude gateway context and replay](../09-lessons-learned/2026-10-09-align-claude-gateway-context-and-replay.md). Safe owner activation is separately gated on an idle request check; the isolated fixture retains the original no-live-traffic verification constraint.
