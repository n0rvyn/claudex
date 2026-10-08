# Model mapping and bounded effort validation

Status: implemented locally; no push, release, OAuth changes or additional inference.

Account & model presents independent Opus/Sonnet/Haiku mappings, with optional same-model mode and custom source aliases. Fixed effort is the default. Allow Claude to adjust uses each selected explicit effort as default and ceiling; missing/auto uses that default, supported scalar requests resolve downward, and unsupported controls or budget translation fail explicitly. Tool continuations retain their original model and effective effort.

Mapping edits validate and auto-save after a 350 ms debounce using atomic persistence. Invalid drafts and write failures retain the last valid runtime mapping; pending saves cancel on account switch. Auto-save does not start the gateway or sign in. Start/Pause remains on Gateway and the menu bar. A compact global status/version footer remains.

Verification:
- Full core suite: 291 tests in 39 suites passed.
- Required offline gateway smoke: 42 tests in 6 suites passed.
- Offline actual AppModel harness: rapid edit coherence, invalid model, unsupported effort, write failure, account-switch cancellation and persisted reload passed.
- macOS build-for-testing succeeded. App-host tests compiled; they were not executed.
- Native minimum content viewport 680×520 (window 680×548 including title bar) retained the same frame through mapping/effort changes and expanded metadata/Activity. Right content scrolls; sidebar remains stable. Long raw metadata wraps. Light and dark captures reviewed. Mapping picker focus is accepted and final focus handlers scroll its row into view.
- Physical mouse resize and complete Tab traversal were not conclusively verified by automation; Full Keyboard Access was off. The native window is configured resizable and programmatic content sizing was verified.
- Final production bundle: /tmp/ClaudexUIXcode/Build/Products/Debug/Claudex.app, PID 79685. Allowlisted UI inspection confirmed selected account connected, low effort and gateway paused. Saved routing projection retains Luna/low for all three source routes and fallback; adjustment flag absent means fixed.

Evidence logs: /tmp/claudex-effort/tests-verified.log, smoke-final.log, autosave-harness.log and build-final.log. Screenshots: native-roles-light.png, native-roles-dark.png, native-details-light.png, native-activity-light.png (same directory). These fixture images contain no real account credentials.

Remaining limits: live Claude Code compatibility remains unverified; live request budget was exhausted before this revision. max_tokens/output-limit handling is separate and unchanged. No claims of cross-model compute equivalence.

## Follow-up hierarchy and disclosure review

Only SettingsView changed in this follow-up. One aligned header now reads Claude Code → OpenAI model → Fixed effort / Effort limit. Opus, Sonnet and Haiku are compact mapping rows; Other fallback is separated. Selected-model effort/capability hints are deduplicated. Custom keyword rules remain intact under Advanced routing. Answer detail explicitly identifies its shared-model or Other-fallback scope; it retains the existing text.verbosity field. Original raw model JSON moved to Activity → Model catalog diagnostics.

A common disclosure style makes the entire header clickable, shows keyboard focus, preserves native accessible disclosure role and numeric expanded state, and handles Space/Return. Nested diagnostic disclosures explicitly inherit the same style. Physical title clicks away from the arrow passed for all eight fixture disclosures: Advanced routing, Answer detail, Optional connection check, Request details, Trace log, Model catalog diagnostics, and both model Raw metadata headers. Each header reported a 453-point clickable width at the minimum viewport. Accessible press/state assertions passed for all eight; focused Answer detail passed actual Space and Return transitions. Content controls remain outside the header button.

Final follow-up build-for-testing passed. Core and auto-save logic were unchanged from the preceding 291-test / 42-smoke-test and six-check AppModel milestone. Actual light/dark rendered mapping screenshots were reviewed; 680×548 window frame stayed stable. Final production PID is 80521, same bundle path, connected account, low effort, gateway paused. No inference or saved-account/mapping changes were performed in production.

The user-provided Library screenshot could not be materialized locally (HTTP 403); parent inspected its actual pixels. This worker used its own native fixture pixels and the parent's concrete screenshot findings, not the Library caption. Latest fixture images saved in Library: mapping light libfile_9e24eb683cd08191864f72b357d18f37; mapping dark libfile_61c16bb874c48191b999480846962421; answer preferences libfile_fe54eb0fff108191bfe1c8d02f8d8ec1. Interaction evidence: /tmp/claudex-effort/disclosures-verified.log and disclosure-title-clicks.log; the scripts' final count label says seven but the eight named cases individually passed.
