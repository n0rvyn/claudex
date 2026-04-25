---
type: plan
status: active
tags: [settings, ui, swiftui, design-system, claudex]
refs: []
---

# General Settings Tab Redesign Plan

**Goal:** Eliminate triple-status duplication, surface a state-aware Launch-at-login remediation banner, raise the plaintext-credentials warning, and re-balance row alignment on the General tab — without changing existing functional behavior on Gateway / Claude Code / Upstream / Diagnostics tabs.

**Architecture:** Pure SwiftUI/AppKit refactor inside the Xcode app target. Three small additions to the shared design system (`MBBanner` component, optional chip slot on `MBField`, middle-truncation flag on `MBReadOnlyField`); one targeted fix to `MBToggleStyle` so toggles hug their content; one new `@Published` property on `AppModel` that mirrors `SMAppService.Status`. No daemon, routing, or network code is touched.

**Tech Stack:** SwiftUI, AppKit (`SMAppService` from `ServiceManagement`), Swift Testing.

**Design doc:** none (findings + ASCII mockup captured in this plan and the conversation that produced it).

**Design analysis:** none.

**Crystal file:** none.

**Threat model:** not applicable. The plan adds UI text and layout changes only — the "Plaintext" chip merely surfaces an existing fact about `config.json` storage; it does not change auth, token, or credential handling.

**Recommended additions (now in scope per DP-003):** an "About" section on the General tab — Version (with Copy), four public-page link buttons (Privacy Policy, Terms of Use, Support, Marketing) all backed by real Notion URLs, and Quit Claudex.

---

## Decisions

### [DP-001] Drop the status pill from the hero `AppInfoCard`? (recommended)

**Context:** `AppInfoCard` (`Claudex/SettingsView.swift:183-215`) currently renders an `MBPill` showing `Paused` / `Running` / `Needs auth`. The persistent `SettingsFooter` (`Claudex/SettingsView.swift:45-78`) already shows the same fact via `MBDot` + status text. Two surfaces, one signal.
**Options:**
- A: Drop the pill from the hero card; let the footer remain the single source of truth — eliminates duplication, hero becomes a calm identity card.
- B: Keep the hero pill; drop the dot+text from the footer — moves the status anchor to a less-visible location during scroll.
**Chosen:** A

### [DP-002] Where should "Reload config" live? (recommended)

**Context:** `Reload config` appears on both General (`Claudex/SettingsView.swift:170-172`) and Upstream (`Claudex/SettingsView.swift:541-545`). It is a developer-class escape hatch that re-reads `config.json` from disk, useful when the file is edited externally; ordinary users should not encounter it on the landing tab.
**Options:**
- A: Remove the General-tab button only; leave the existing Upstream-tab button as the developer entry point.
- B: Remove from General and add a fresh button to Diagnostics → Trace section header.
**Chosen:** A

### [DP-003] Add an "About" section now or defer? (recommended)

**Context:** The redesign mockup proposed an "About" block (Send feedback / Acknowledgements / Quit Claudex). The codebase has no existing "Send feedback" destination (no homepage URL, no feedback Linear/GitHub link committed) and no Acknowledgements asset.
**Options:**
- A: Defer — leave the General tab without an About section; add later once feedback URL + acknowledgements list are decided.
- B: Add now with placeholder URLs (`#`) and a standard `NSApplication.terminate` Quit button.
**Chosen:** B (refined) — Add the About section now; instead of placeholder URLs, link to **real Notion pages** created under `Apple App Pages → Claudex`. The set of pages is scoped to App Store Connect submission requirements (Privacy Policy, Support URL, Terms of Use). This converts the deferred risk (placeholder URLs shipping to users) into a concrete pre-submission task that also unblocks ASC submission.

---

<!-- section: task-1 keywords: launch-at-login, sm-app-service, app-model -->
### Task 1: Expose granular launch-at-login status on `AppModel`

**Files:**
- Modify: `Claudex/Item.swift:11-13` (add `var status` getter)
- Modify: `Claudex/ContentView.swift:92-93` (add new `@Published` property)
- Modify: `Claudex/ContentView.swift:889-892` (write the new property in `refreshLaunchAtLogin()`)

**Steps:**
1. In `Claudex/Item.swift`, add a public getter on `LaunchAtLoginController` so the view can switch on the raw status (the existing `isEnabled` and `statusText` derive from the same source but lose the discriminator):
   ```swift
   var status: SMAppService.Status { service.status }
   ```
   Place it directly above the existing `var isEnabled` (around line 11).
2. In `Claudex/ContentView.swift`, add a new published property to `AppModel` immediately after the existing `launchAtLoginEnabled` declaration (around line 93):
   ```swift
   @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
   ```
   Add `import ServiceManagement` at the top of the file if it is not already imported (it is not — `Item.swift` is the only current consumer).
3. Update `refreshLaunchAtLogin()` (around line 889) to also assign the raw status:
   ```swift
   private func refreshLaunchAtLogin() {
       launchAtLoginEnabled = launchAtLoginController.isEnabled
       launchAtLoginText = launchAtLoginController.statusText
       launchAtLoginStatus = launchAtLoginController.status
   }
   ```

**Verify:**
Run: `grep -n "launchAtLoginStatus" Claudex/ContentView.swift Claudex/Item.swift`
Expected: at least three matches — declaration in `ContentView.swift`, assignment in `refreshLaunchAtLogin()`, and the new `var status` getter in `Item.swift`. Run `grep -n "import ServiceManagement" Claudex/ContentView.swift` and expect exactly one match.

⚠️ No test: pure pass-through to a system framework (`SMAppService.status`); a unit test would re-assert what `SMAppService` already guarantees. Behavior is exercised by Task 5's banner + manual launch.
<!-- /section -->

<!-- section: task-2 keywords: mb-banner, design-system, swiftui -->
### Task 2: Add `MBBanner` component to `DesignSystem.swift`

**Files:**
- Modify: `Claudex/DesignSystem.swift` (append a new component, placed after `MBCard`, before `MBSectionHeader`)

**Steps:**
1. Append the following component to `Claudex/DesignSystem.swift`. Keep the surrounding palette references (`MBColor.warnSoft`, `.warnInk`, `.warn`, `.live`, `.brand`) consistent with the existing `MBPill.Tone` mapping so banners and pills feel of one family:
   ```swift
   // MARK: - Banner

   struct MBBanner<Actions: View>: View {
       enum Tone { case warn, info, success }

       let tone: Tone
       let title: String
       var body: String? = nil
       @ViewBuilder var actions: Actions

       init(
           tone: Tone,
           title: String,
           body: String? = nil,
           @ViewBuilder actions: () -> Actions = { EmptyView() }
       ) {
           self.tone = tone
           self.title = title
           self.body = body
           self.actions = actions()
       }

       var body: some View {
           HStack(alignment: .top, spacing: 10) {
               Image(systemName: iconName)
                   .font(.system(size: 14, weight: .semibold))
                   .foregroundStyle(accentForeground)
                   .frame(width: 18, alignment: .center)
               VStack(alignment: .leading, spacing: 6) {
                   Text(title)
                       .font(.system(size: 12, weight: .semibold))
                       .foregroundStyle(MBColor.ink)
                   if let body {
                       Text(body)
                           .font(.system(size: 11))
                           .foregroundStyle(MBColor.inkMid)
                           .fixedSize(horizontal: false, vertical: true)
                           .textSelection(.enabled)
                   }
                   actions
               }
               Spacer(minLength: 0)
           }
           .padding(12)
           .frame(maxWidth: .infinity, alignment: .leading)
           .background(
               RoundedRectangle(cornerRadius: 8, style: .continuous)
                   .fill(background)
           )
           .overlay(
               RoundedRectangle(cornerRadius: 8, style: .continuous)
                   .stroke(border, lineWidth: 0.5)
           )
       }

       private var iconName: String {
           switch tone {
           case .warn:    return "exclamationmark.triangle.fill"
           case .info:    return "info.circle.fill"
           case .success: return "checkmark.seal.fill"
           }
       }

       private var background: Color {
           switch tone {
           case .warn:    return MBColor.warnSoft
           case .info:    return MBColor.brandSoft
           case .success: return MBColor.liveSoft
           }
       }

       private var border: Color {
           switch tone {
           case .warn:    return MBColor.warn.opacity(0.35)
           case .info:    return MBColor.brand.opacity(0.35)
           case .success: return MBColor.live.opacity(0.35)
           }
       }

       private var accentForeground: Color {
           switch tone {
           case .warn:    return MBColor.warnInk
           case .info:    return MBColor.brand
           case .success: return MBColor.liveInk
           }
       }
   }
   ```

**Verify:**
Run: `grep -n "struct MBBanner" Claudex/DesignSystem.swift`
Expected: exactly one match. Then `grep -n "MBColor.warnSoft\|MBColor.brandSoft\|MBColor.liveSoft" Claudex/DesignSystem.swift` returns the existing palette entries plus the new banner references.

⚠️ No test: style-only SwiftUI component (no conditional logic beyond a 3-case enum switch on `tone`); rendered output is verified by Task 5's banner usage and visual inspection.
<!-- /section -->

<!-- section: task-3 keywords: mb-field, mb-readonly, chip, truncate -->
### Task 3: Add chip slot to `MBField` and middle-truncation to `MBReadOnlyField`

**Files:**
- Modify: `Claudex/DesignSystem.swift:265-312` (extend `MBField`)
- Modify: `Claudex/DesignSystem.swift:342-363` (extend `MBReadOnlyField`)

**Steps:**
1. Extend `MBField` with two optional parameters: `chipText` (the chip's text) and `chipTone` (one of `MBPill.Tone`). Render the chip immediately to the right of the label text in both the inline and stacked variants. Replace the existing `MBField` with:
   ```swift
   struct MBField<Content: View>: View {
       let label: String
       var help: String? = nil
       var stacked: Bool = false
       var chipText: String? = nil
       var chipTone: MBPill.Tone = .neutral
       @ViewBuilder let content: Content

       var body: some View {
           if stacked {
               VStack(alignment: .leading, spacing: 6) {
                   labelRow(font: MBFont.labelB)
                   content
                   if let help {
                       Text(help)
                           .font(.system(size: 11))
                           .foregroundStyle(MBColor.inkDim)
                   }
               }
               .padding(.vertical, 8)
           } else {
               HStack(alignment: .firstTextBaseline, spacing: 18) {
                   VStack(alignment: .leading, spacing: 3) {
                       labelRow(font: MBFont.label)
                       if let help {
                           Text(help)
                               .font(.system(size: 11))
                               .foregroundStyle(MBColor.inkDim)
                               .fixedSize(horizontal: false, vertical: true)
                       }
                   }
                   .frame(width: 200, alignment: .leading)

                   content
                       .frame(maxWidth: .infinity, alignment: .leading)
               }
               .padding(.vertical, 10)
               .overlay(
                   Rectangle()
                       .fill(MBColor.ruleSoft)
                       .frame(height: 0.5)
                       .frame(maxHeight: .infinity, alignment: .bottom)
               )
           }
       }

       @ViewBuilder
       private func labelRow(font: Font) -> some View {
           HStack(alignment: .firstTextBaseline, spacing: 6) {
               Text(label)
                   .font(font)
                   .foregroundStyle(MBColor.ink)
               if let chipText {
                   MBPill(text: chipText, tone: chipTone)
               }
           }
       }
   }
   ```
   This preserves all existing call sites — `chipText` defaults to `nil` and adds nothing visually until populated.
2. Extend `MBReadOnlyField` with a `truncateMiddle` flag. Replace lines 342-363 with:
   ```swift
   struct MBReadOnlyField: View {
       let value: String
       var mono: Bool = true
       var truncateMiddle: Bool = false

       var body: some View {
           Group {
               if truncateMiddle {
                   Text(value)
                       .lineLimit(1)
                       .truncationMode(.middle)
                       .help(value)
               } else {
                   Text(value)
               }
           }
           .font(mono ? MBFont.mono : MBFont.ui)
           .foregroundStyle(MBColor.ink)
           .textSelection(.enabled)
           .frame(maxWidth: .infinity, alignment: .leading)
           .padding(.horizontal, 10)
           .padding(.vertical, 6)
           .background(
               RoundedRectangle(cornerRadius: 6, style: .continuous)
                   .fill(MBColor.paperAlt)
           )
           .overlay(
               RoundedRectangle(cornerRadius: 6, style: .continuous)
                   .stroke(MBColor.rule, lineWidth: 0.5)
           )
       }
   }
   ```
   The `.help(value)` modifier exposes the full path on hover when truncated. Existing call sites that omit `truncateMiddle` are untouched.

**Verify:**
Run: `grep -n "var chipText\|truncateMiddle\|truncationMode(.middle)" Claudex/DesignSystem.swift`
Expected: at least four matches (chipText param, chipTone param, truncateMiddle param, truncationMode call). Run: `grep -rn "MBField(" Claudex/SettingsView.swift | wc -l` — confirm match count is unchanged after refactor (no regressions in MBField call sites yet).

⚠️ No test: API additions are optional parameters with safe defaults; consumed only by Task 5; rendering is style-only.
<!-- /section -->

<!-- section: task-4 keywords: toggle-style, hug-content, layout -->
### Task 4: Fix `MBToggleStyle` so the toggle hugs its content

**Files:**
- Modify: `Claudex/DesignSystem.swift:599-620` (replace `MBToggleStyle.makeBody`)

**Steps:**
1. The current `MBToggleStyle` puts a `Spacer(minLength: 0)` between the label and the toggle visual, then sits inside a `Toggle("")` that fills `maxWidth: .infinity` of the `MBField` content column. Result: the visual is pushed to the far right of the 760pt-wide `SettingsShell`, ~500pt from its label. Rebuild the toggle without the `Spacer` and add `.fixedSize()` so it hugs its content. Replace the body of `MBToggleStyle` with:
   ```swift
   func makeBody(configuration: Configuration) -> some View {
       HStack(spacing: 8) {
           configuration.label
           ZStack(alignment: configuration.isOn ? .trailing : .leading) {
               Capsule()
                   .fill(configuration.isOn ? tint : MBColor.rule)
                   .frame(width: 30, height: 18)
               Circle()
                   .fill(.white)
                   .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                   .frame(width: 14, height: 14)
                   .padding(2)
           }
           .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
           .onTapGesture { configuration.isOn.toggle() }
       }
       .fixedSize()
   }
   ```
2. There are two call sites today: `Claudex/SettingsView.swift:133` (the Launch-at-login toggle on the General tab — the visual we are tightening) and `Claudex/ContentView.swift:1027` (the master daemon toggle in the menu bar popover). Both use `.labelsHidden()`, so `configuration.label` is empty. The popover at `ContentView.swift:1023-1029` already wraps the toggle in an external `HStack` with `Spacer(minLength: 0)` (line 1022) and an external `.fixedSize()` (line 1029), which keeps the popover capsule pinned to its trailing edge regardless of internal layout. The new `makeBody` (no internal `Spacer`, inner `.fixedSize()`) preserves popover behavior; only the General-tab toggle visibly moves leftward into its label column.

**Verify:**
Run: `grep -n "Spacer(minLength: 0)" Claudex/DesignSystem.swift`
Expected: zero matches inside `MBToggleStyle` (other `Spacer` usages elsewhere in the file are fine). Run: `grep -n "MBToggleStyle()" Claudex/SettingsView.swift Claudex/ContentView.swift` and confirm exactly two call sites — `SettingsView.swift:133` (General tab) and `ContentView.swift:1027` (popover, behavior preserved by external scaffolding). No Diagnostics/Gateway/Upstream call sites.

**Quality markers:**
- After the change, the Launch-at-login toggle visual sits within ~10pt of the row's `MBField` content leading edge (not at the right margin).
- All existing `MBField` call sites continue to render — the change is internal to `MBToggleStyle.makeBody`.

⚠️ No test: SwiftUI ToggleStyle layout — verified visually in Task 5's manual launch step. The pure-logic part (none here) is trivial.
<!-- /section -->

<!-- section: task-5 keywords: settings-view, general-tab, hero, banner -->
### Task 5: Restructure the General settings tab

**Files:**
- Modify: `Claudex/SettingsView.swift:106-181` (rewrite `GeneralSettingsTab`)
- Modify: `Claudex/SettingsView.swift:183-215` (adjust `AppInfoCard` to drop the status pill per DP-001)

**Steps:**
1. **Hero on top, identity-only.** Replace `AppInfoCard` so it renders identity without the status pill (DP-001 chosen value). Replace lines 183-215 with:
   ```swift
   private struct AppInfoCard: View {
       @ObservedObject var model: AppModel

       var body: some View {
           HStack(alignment: .center, spacing: 14) {
               MBBridgeBadge(size: 40, cornerRadius: 9)
               VStack(alignment: .leading, spacing: 2) {
                   Text("Claudex")
                       .font(MBFont.labelB)
                       .foregroundStyle(MBColor.ink)
                   Text("Local Anthropic ↔ Codex bridge · \(model.appVersion)")
                       .font(.system(size: 11))
                       .foregroundStyle(MBColor.inkDim)
               }
               Spacer(minLength: 0)
           }
           .padding(14)
           .background(MBColor.paperDim)
           .overlay(
               RoundedRectangle(cornerRadius: 10, style: .continuous)
                   .stroke(MBColor.ruleSoft, lineWidth: 0.5)
           )
           .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
       }
   }
   ```
   Status (`headerStatusText`) is removed from this card; the `SettingsFooter` is now the single source of truth for live state per DP-001.
2. **Rewrite `GeneralSettingsTab` body** so the hero sits at the top, the Startup section gains the state-aware banner, the Storage section uses the new chip + truncated path + Copy button + the renamed labels, and the Reload-config button is removed (DP-002 chosen value):
   ```swift
   private struct GeneralSettingsTab: View {
       @ObservedObject var model: AppModel
       @AppStorage("claudex.appearance") private var appearanceRaw: Int = 0

       var body: some View {
           SettingsShell {
               AppInfoCard(model: model)
                   .padding(.bottom, 14)

               MBSection(title: "Appearance") {
                   MBField(
                       label: "Theme",
                       help: "Menu bar popover and settings window adapt to this."
                   ) {
                       MBSeg(
                           value: $appearanceRaw,
                           options: [(0, "Auto"), (1, "Light"), (2, "Dark")]
                       )
                   }
               }

               MBSection(title: "Startup") {
                   MBField(
                       label: "Launch at login",
                       help: "Start Claudex and bind the local gateway when you log in."
                   ) {
                       Toggle("", isOn: Binding(
                           get: { model.launchAtLoginEnabled },
                           set: { _ in model.toggleLaunchAtLogin() }
                       ))
                       .toggleStyle(MBToggleStyle())
                       .labelsHidden()
                   }
                   launchAtLoginStatusView
               }

               MBSection(title: "Storage") {
                   MBField(
                       label: "Config file",
                       help: "Edited by the app as you change settings.",
                       stacked: true,
                       chipText: "Plaintext",
                       chipTone: .warn
                   ) {
                       HStack(spacing: 6) {
                           MBReadOnlyField(value: model.configurationPath, truncateMiddle: true)
                           Button(action: { model.openConfigurationLocation() }) {
                               Label("Reveal", systemImage: "folder")
                           }
                           Button(action: { copyConfigPath() }) {
                               Label("Copy", systemImage: "doc.on.doc")
                           }
                       }
                   }

                   MBField(
                       label: "App data folder",
                       help: "Trace logs and auxiliary state.",
                       stacked: true
                   ) {
                       Button(action: { model.openApplicationSupportDirectory() }) {
                           Label("Reveal in Finder", systemImage: "folder.badge.gearshape")
                       }
                   }
               }

               AboutSection(model: model)
           }
       }

       @ViewBuilder
       private var launchAtLoginStatusView: some View {
           switch model.launchAtLoginStatus {
           case .notFound:
               MBBanner(
                   tone: .warn,
                   title: "Launch at login needs the packaged app bundle.",
                   body: "Run \"bash scripts/build_app_bundle.sh\" in the Claudex repo to produce dist/Claudex.app, then move it into /Applications."
               ) {
                   Button(action: { revealApplicationsFolder() }) {
                       Label("Open /Applications", systemImage: "app.gift")
                   }
               }
               .padding(.top, 4)

           case .requiresApproval:
               MBBanner(
                   tone: .warn,
                   title: "Login Items needs your approval.",
                   body: "macOS hasn't authorized Claudex to start at login yet."
               ) {
                   Button(action: { openLoginItemsSettings() }) {
                       Label("Open Login Items", systemImage: "gear")
                   }
               }
               .padding(.top, 4)

           case .enabled:
               HStack(spacing: 6) {
                   MBDot(state: .live, size: 8)
                   Text("Will start automatically at login.")
                       .font(.system(size: 12))
                       .foregroundStyle(MBColor.inkMid)
               }
               .padding(.top, 6)

           case .notRegistered:
               EmptyView()

           @unknown default:
               EmptyView()
           }
       }

       private func copyConfigPath() {
           let pasteboard = NSPasteboard.general
           pasteboard.clearContents()
           pasteboard.setString(model.configurationPath, forType: .string)
       }

       private func revealApplicationsFolder() {
           NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
       }

       private func openLoginItemsSettings() {
           if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
               NSWorkspace.shared.open(url)
           }
       }
   }
   ```
3. The original General tab placed `AppInfoCard(model: model).padding(.top, 4)` at the bottom — remove that line; the hero is now positioned at the top via the rewrite above. Confirm `AppInfoCard` is still defined exactly once in the file (the struct used to live below `GeneralSettingsTab`; keep it where it is — only the call site moved).

   **Sequencing note:** the body of `GeneralSettingsTab.body` calls `AboutSection(model: model)`, which is defined in Task 6. Apply Task 5 and Task 6 in the same build cycle (or swap the execution order so Task 6 lands first) — the file will not compile if Task 5 is committed alone.
4. The `Reload config` button (previously at line 170-172 with action `model.reloadPersistedConfiguration()`) is removed from the General tab per DP-002. The action remains available on the Upstream tab (`Claudex/SettingsView.swift:541-545`) — confirm that call site is unchanged after the edit.
5. The "Status" `MBField` row (previously at lines 137-144) is replaced by `launchAtLoginStatusView`, which renders nothing for `.notRegistered`, an inline confirmation row for `.enabled`, and a `MBBanner` for `.notFound` / `.requiresApproval`.

**Design ref:** the ASCII mockup in the conversation that produced this plan (preserved here for reference):
```
[badge]  Claudex                              v1.0 (1)
         Local Anthropic ↔ Codex bridge

APPEARANCE
Theme    [ Auto | Light | Dark ]

STARTUP
Launch at login   ●━━○            ← toggle hugs its label
Start Claudex and bind the local gateway when you log in.
⚠ Launch at login needs the packaged app bundle.   ← shown when .notFound
  ...                                                only

STORAGE
Config file   [Plaintext]                             ← warn-tone chip on label
/Users/.../config.json   [Reveal] [Copy]              ← truncate-middle on path

App data folder
Trace logs and auxiliary state.    [Reveal in Finder]
─────────────────────────────────────────────────────
● Gateway paused                                v1.0 (1)   ← footer is single status source
```

**Expected values:**
- Hero subtitle text: `Local Anthropic ↔ Codex bridge · <appVersion>`
- Banner title for `.notFound`: `Launch at login needs the packaged app bundle.`
- Banner title for `.requiresApproval`: `Login Items needs your approval.`
- Storage section title: `Storage` (was `Data location`)
- Config file label text: `Config file` with chip text `Plaintext` (tone `.warn`)
- App data folder label text: `App data folder` (was `Application support folder`)

**Replaces:**
- Bottom `AppInfoCard` placement → top hero
- "Status" `MBField` row with bare text → conditional banner + inline confirmation
- Plain helper text "API keys are stored in plaintext here." → `MBPill(.warn)` chip on the Config file label
- Plain `MBReadOnlyField(value: model.configurationPath)` → `truncateMiddle: true`
- General-tab "Reload config" button → removed (Upstream tab keeps its copy)

**User interaction:**
- On opening Settings → General with `.notRegistered`: user sees identity hero, theme picker, an unconstrained Launch-at-login toggle, and Storage section with chipped Config file row.
- On `.notFound` (current state shown in screenshot): user sees the warn banner with the literal command in the body (`bash scripts/build_app_bundle.sh`) and a single action button; clicking "Open /Applications" opens the Applications folder so the user can drop `dist/Claudex.app` into it.
- On `.requiresApproval`: user sees a warn banner with an "Open Login Items" button that deep-links into System Settings.
- On `.enabled`: user sees a small green-dot row "Will start automatically at login." beneath the toggle.

**Verify:**
Run:
```
grep -n "Local Anthropic ↔ Codex bridge\|App data folder\|Will start automatically at login\|Login Items needs your approval\|needs the packaged app bundle" Claudex/SettingsView.swift
```
Expected: five matches (one per string). Then verify the General tab's section list explicitly:
```
grep -nE 'MBSection\(title: "(Appearance|Startup|Storage|About)"\)' Claudex/SettingsView.swift
```
Expected: 4 matches — one for each of Appearance, Startup, Storage (renamed from "Data location"), and About (added by Task 6). Then:
```
grep -n "Reload config" Claudex/SettingsView.swift
```
Expected: exactly one match (the surviving Upstream-tab button at line ~542).

**Quality markers:**
- AppInfoCard appears exactly once in the General tab and at the top of the page (above Appearance).
- The Storage section renders no Reload-config button.
- The Status `MBField` row no longer exists; the Launch-at-login banner appears only when status is `.notFound` or `.requiresApproval`.
- `MBPill(text: "Plaintext", tone: .warn)` is rendered to the right of the "Config file" label.
- The config path renders on a single line with middle truncation; hovering shows the full path.

**Verify after:**
After implementing, manually launch the app and confirm:
- Page opens with the hero at top, no status pill on the hero card.
- Toggle for Launch at login is adjacent to its label, not pushed to the right margin.
- Banner appears under the toggle (current dev environment is `.notFound` — packaged bundle not installed; banner with two buttons should render).
- Footer continues to show `Gateway paused · v1.0 (1)`.

⚠️ No test: composition + style-only SwiftUI changes. The only conditional logic (`launchAtLoginStatusView` switch) is a 4-case dispatch on a system-framework enum; trivial. Behavior is verified by the manual launch step above plus Task 1's grep on the published property.
<!-- /section -->

<!-- section: task-6 keywords: about-section, notion, app-store-connect -->
### Task 6: Add `AboutSection` with App Store Connect submission links

**Files:**
- Modify: `Claudex/SettingsView.swift` (append a new `private struct AboutSection` after `AppInfoCard`)

**Steps:**
1. The four Notion pages and their resolved public URLs (provided by the user; tracking parameter `?source=copy_link` stripped to keep canonical URLs):

   | Slot | Notion page title | Public URL |
   |---|---|---|
   | Privacy Policy | `Claudex Privacy Policy` | `https://prickly-pentagon-3b6.notion.site/Privacy-Policy-34dd945c7a9b814e87b6ea016d49a747` |
   | Terms of Use | `Claudex Terms of Use` | `https://prickly-pentagon-3b6.notion.site/Terms-of-Use-34dd945c7a9b81acb4b7e1cae6deb37d` |
   | Support | `Claudex Support` | `https://prickly-pentagon-3b6.notion.site/Support-34dd945c7a9b810ba78cc1bce08a6a8e` |
   | Marketing | `Market Claudex` | `https://prickly-pentagon-3b6.notion.site/Market-Claudex-34dd945c7a9b8193a7bbe8d5b4a439bf` |

2. Append the following struct to `Claudex/SettingsView.swift` (after `AppInfoCard`):
   ```swift
   private struct AboutSection: View {
       @ObservedObject var model: AppModel

       private let privacyURL   = URL(string: "https://prickly-pentagon-3b6.notion.site/Privacy-Policy-34dd945c7a9b814e87b6ea016d49a747")
       private let termsURL     = URL(string: "https://prickly-pentagon-3b6.notion.site/Terms-of-Use-34dd945c7a9b81acb4b7e1cae6deb37d")
       private let supportURL   = URL(string: "https://prickly-pentagon-3b6.notion.site/Support-34dd945c7a9b810ba78cc1bce08a6a8e")
       private let marketingURL = URL(string: "https://prickly-pentagon-3b6.notion.site/Market-Claudex-34dd945c7a9b8193a7bbe8d5b4a439bf")

       var body: some View {
           MBSection(title: "About") {
               MBField(label: "Version") {
                   HStack(spacing: 6) {
                       Text(model.appVersion)
                           .font(MBFont.mono)
                           .foregroundStyle(MBColor.inkMid)
                           .textSelection(.enabled)
                       Button(action: { copyVersion() }) {
                           Label("Copy", systemImage: "doc.on.doc")
                       }
                   }
               }
               MBField(label: "Public pages", help: "Linked from the App Store Connect submission.") {
                   HStack(spacing: 12) {
                       linkButton(title: "Privacy Policy", url: privacyURL)
                       linkButton(title: "Terms of Use",   url: termsURL)
                       linkButton(title: "Support",        url: supportURL)
                       linkButton(title: "Marketing",      url: marketingURL)
                   }
               }
               MBField(label: "Quit") {
                   Button(role: .destructive, action: { NSApplication.shared.terminate(nil) }) {
                       Label("Quit Claudex", systemImage: "power")
                   }
               }
           }
       }

       @ViewBuilder
       private func linkButton(title: String, url: URL?) -> some View {
           if let url {
               Button(action: { NSWorkspace.shared.open(url) }) {
                   Label(title, systemImage: "arrow.up.right.square")
               }
               .buttonStyle(.link)
           } else {
               Text(title)
                   .font(.system(size: 12))
                   .foregroundStyle(MBColor.inkFaint)
                   .help("URL not configured")
           }
       }

       private func copyVersion() {
           let pasteboard = NSPasteboard.general
           pasteboard.clearContents()
           pasteboard.setString(model.appVersion, forType: .string)
       }
   }
   ```
   All four URLs are non-nil; the `if let url { ... } else { ... }` branch is defensive in case a future edit accidentally clears one.
3. The `AboutSection(model: model)` invocation is already added to `GeneralSettingsTab.body` in Task 5's snippet; no further wiring needed here.

**User interaction:**
- User opens Settings → General, scrolls to bottom; sees Version (with Copy), four link buttons (Privacy Policy / Terms of Use / Support / Marketing) that open the corresponding Notion pages in the default browser, and a destructive-styled Quit Claudex button.

**Verify:**
Run:
```
grep -n "PRIVACY_POLICY_URL\|SUPPORT_URL\|TERMS_URL\|MARKETING_URL" Claudex/SettingsView.swift
```
Expected: zero matches (all placeholders replaced — only literal Notion URLs remain). Then:
```
grep -n "struct AboutSection\|AboutSection(model:" Claudex/SettingsView.swift
```
Expected: two matches (one for the type definition, one for the call site in `GeneralSettingsTab`). Then:
```
grep -c "prickly-pentagon-3b6.notion.site" Claudex/SettingsView.swift
```
Expected: 4 matches (one per Notion URL constant).

**Quality markers:**
- All four URLs in `AboutSection` are real, resolvable public Notion URLs (verified by the user when copied from Notion's Share → Publish to web flow).
- The Quit button uses `role: .destructive` and matches macOS native styling.
- A user clicking each link button is taken to the corresponding Notion page in their default browser.

**Verify after:**
After implementing, manually launch the app and click each link; confirm the browser opens the correct Notion page. Confirm the version Copy button writes the version string to the clipboard (paste into TextEdit to check).

⚠️ No test: pure UI composition; the only logic is a `URL?` nil-check rendered as conditional `Button` vs. `Text`. Behavior is verified by the manual launch step.
<!-- /section -->

---

## Pre-execution Notion checklist (DP-003 follow-up) — RESOLVED

Four Notion pages were created under `Apple App Pages → Claudex` and published to web. URLs were provided by the user on 2026-04-25 and embedded directly in Task 6. Pre-execution gate satisfied — no `<*_URL>` placeholders remain in the plan body.

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-04-25
- **Cycles:** 2 (initial → must-revise → approved)
- **Reports:**
  - cycle-1 (must-revise): `.claude/reviews/plan-verifier-2026-04-25-095701.md`
  - cycle-2 (approved): `.claude/reviews/plan-verifier-2026-04-25-100648.md`
- **Decisions resolved in-flight:** DP-001 A · DP-002 A · DP-003 B (refined) · DP-004 A
- **Advisory items addressed in revisions (non-blocking):**
  - Task 5 sequencing note: must apply with Task 6 atomically (calls `AboutSection`).
  - `MBBanner` body now `.textSelection(.enabled)` so the user can copy `bash scripts/build_app_bundle.sh` from the `.notFound` banner.
- **Pre-execution gate:** RESOLVED 2026-04-25. Four Notion URLs (Privacy Policy / Terms of Use / Support / Marketing) embedded directly in Task 6 step 2. Marketing slot added in addition to the original three because the user provided the page; total link slots = 4.
