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
