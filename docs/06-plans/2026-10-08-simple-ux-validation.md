# Claudex simplified UX validation · 2026-10-08

## Behavior

Primary path: Connect ChatGPT → choose an account-reported model and reasoning effort → Save & start. Advanced contains per-role routing, response detail, account metadata and Save without starting. The persistent `routingTable.singleModelMode` flag bypasses matching rules without deleting them. Nil keeps legacy routing semantics. Fresh installs use single-model mode; existing divergent routes remain advanced until the user explicitly switches. Missing models and unsupported efforts are preserved and block saving/starting.

The menu offers one Start/Pause control. Starting reveals the necessary connection exports once per start, with Copy and Done; the Claude Code page keeps them available. Copy uses the actual local token; visible snippets show a placeholder. Gateway tokens are fully masked until explicitly revealed. No automatic account grants or hidden inference.

Navigation is one list: Account & model, Claude Code, Gateway, Activity, General. General originally had a deliberate bottom placement; user feedback prompted removing that separation. Controls remain Appearance (Auto/Light/Dark), Launch at login, Storage (config path Reveal/Copy, app folder Reveal), and About (version Copy and public/support links).

## Verification

- SwiftPM: 278 tests in 38 suites passed; includes single-model aliases, rules surviving Codable round trip, advanced reactivation and legacy JSON behavior.
- Xcode macOS build-for-testing succeeded. App and app-host tests compile; app-host/XCUITest suites were not executed.
- The isolated native harness compiled actual AppModel, SettingsView and DesignSystem with the production core. Offline assertions passed for signed out, browser sign-in/cancel/retry, auth interruption, model loading, catalog unavailable, account changed, retired model, unsupported effort, connected-ready, started, paused, gateway failure presentation and preserved advanced rules/fail-closed reactivation. These are fixture state/transition checks, not another live OAuth grant or gateway inference test.
- Native window captures cover all five settings pages and menu content in light/dark, 820-point normal settings width, 680-point constrained width, loading/error and running/paused fixtures. Existing screen/accessibility privileges were used; only own fixture windows were captured.
- Read-only visual critique identified light-terminal contrast, truncated effort error and duplicate retired-model errors; these were fixed and renders repeated.
- Fixture hooks are DEBUG-only. Their in-memory configuration and fake account/catalog suppress startup monitoring, auth, login-item and model calls. Fixture catalog Refresh throws an offline error. Production settings and account storage remain in their existing locations.

Live inference remains exhausted at 3/3 from the earlier bounded smoke. This UX work made zero further inference calls. Full Claude Code interactive sessions, tool permission UX and compaction remain unverified. No publishing or permission changes.

Evidence: /tmp/claudex-ui/{tests.log,final-build.log,offline-states.log,render.log}; native images in the same directory. Final handoff includes Library screenshot identifiers and the verified running bundle/PID.

## Final handoff

Final production bundle `/tmp/ClaudexUIXcode/Build/Products/Debug/Claudex.app`, verified process 74861. Native AX verification confirmed all five navigation choices, connected selected account, low effort, enabled Save & start, and Gateway paused. The app was safely relaunched from the previous verified PID; fixture processes were closed. Existing login and routing config were not rewritten during the UI redesign. Native fixture Gateway text fields accepted AX focus; keyboard events targeted only that fixture. System keyboard-navigation preferences were not changed; a comprehensive button-by-button keyboard traversal was not established.

Library screenshots (fake accounts/catalog only):
- upstream-ready-dark-820.png — libfile_4558bd04814c8191b21088386a484492; file_00000000e0dc81f6af296d077dd909e7
- upstream-ready-light-820.png — libfile_4ad16c0c69e08191b57c645d933863e6; file_00000000c46081f9a27b7cc0cd0b9d83
- general-ready-dark-820.png — libfile_c2cab5f5d9f8819190043beb80b1d7b6; file_00000000e3f881f9b818cb6ceb58b20c
- popover-ready-dark-400.png — libfile_d8b425465aec8191a56cee6ba3e7f268; file_00000000b4c881f68b1f0f4f14dfe0af
- claudeCode-ready-light-820.png — libfile_c7ee1aa81aac81919f82c240e67539f1; file_00000000744481f6889679cb58f15da0

Library create succeeded for all five images and the official helper applied each returned metadata set and Library ID to its local PNG. These are native captures of actual SwiftUI views in isolated fixture windows, not design mockups. The popover image captures its content in a fixture NSWindow; the final real menu retains the distinct terminal.fill icon.
