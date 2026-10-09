---
category: platform-constraints
keywords: [claude-code, claudex, compaction, replay, context-window, model-catalog]
date: 2026-10-09
verified_on: Claude Code 2.1.295 / Claudex working tree based on faaed5b
source_project: Claudex
---
# Align Claude gateway context and replay

## Scope and sources

This is the canonical record for the October 9 repair, not a claim that a new paid-model acceptance run passed. No global Claude Code settings or shell profile were inspected or edited. The prior classifier repair remains documented separately in `docs/06-plans/2026-10-08-classifier-diagnostics.md`.

### Official facts, checked October 9

`ANTHROPIC_BASE_URL` changes routing; recognized Claude IDs retain Claude's assumed model window. Claude Code cannot discover a smaller upstream limit from that URL. A gateway `/v1/models` discovery entry supplies picker identity/display information, not a documented context-capacity advertisement.

Use `CLAUDE_CODE_AUTO_COMPACT_WINDOW` for an earlier working boundary. Its integer value is bounded by 100K–1M and the model window. It overrides the CLI flag and settings. It changes compaction behavior, not necessarily the displayed model capacity. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` has model-ID-dependent semantics and can require disabling compaction for recognized Claude IDs; do not use that workaround here. Existing sessions need a restart to inherit new exports.

Sources: [Model configuration](https://code.claude.com/docs/en/model-config#context-window-and-auto-compaction), [Environment variables](https://code.claude.com/docs/en/env-vars).

Claude's context recovery recognizes specific too-long errors. A rewritten gateway error can prevent recovery. Normalize only a genuine upstream context-limit code; HTTP 413 alone can mean byte-size rejection. No documented response header synchronizes upstream pressure or compaction state with Claude's history.

Sources: [Gateway troubleshooting](https://code.claude.com/docs/en/llm-gateway-connect#troubleshoot-gateway-errors), [Upstream error messages](https://code.claude.com/docs/en/claude-apps-gateway-config#upstream-error-messages).

### Local observations

- Installed `~/.local/bin/claude` resolves to native binary version **2.1.295**. Help exposes `--autocompact` and `--bare`; no inference was invoked to inspect it.
- Executed the installed binary's extracted pure error recognizer: four positive/negative fixtures passed. Executed its extracted environment-window and output-reserve functions: seven fixtures passed, covering the 100K minimum, 1M maximum, recognized-model cap, and reserve `min(maxOutputTokens, 20000)`. The numeric parser helper was stubbed with `Number.parseInt`; these are function-level checks, not an end-to-end Claude session acceptance test.
- Its gateway discovery row validator retains only `id`, `display_name`, `description` and strips other fields. This confirms ordinary discovery cannot set context capacity in this installed version.
- The existing protected account model catalog was inspected through a strict metadata projection only. Seven listed models advertise normal `context_window=272000`, `max_context_window=872000`, and null `auto_compact_token_limit`. Some advertise experimental-context support. The larger maximum is not proof that this request path enabled that mode.
- Previously captured boundary metadata showed Claude's automatic compaction at 01:50:01.558 UTC, followed by the replay error at 01:50:01.977 UTC. The continuation summary used Claude's native prefix sentence. Client-reported pre/post token counts are estimates, not proof of an upstream capacity or exact proactive threshold.

### Confirmed code mechanisms and changes

`SIWCBridge` replay previously required an account/session/full-prefix hash. A native compaction summary changes that prefix. Its continuation guard therefore reported a cache miss as an unsupported capability before contacting the model.

Recovery now requires the native summary format signal, a complete exact retained assistant fingerprint including tool IDs/names/arguments/block order, same account/session scope, and a unique originating replay record. Ordinary changed semantic prefixes still fail. Thinking/cache annotations retain existing normalization rules; temporary `clear_at` boundaries prohibit fallback. Raw Responses items, including opaque reasoning and function item IDs, and executor/Advisor routes stay original. No removed prefix is invented or restored into the client history. Legacy plain text/client-tool records can be reconstructed for matching; legacy Advisor/native items that cannot be safely reconstructed fail closed. Duplicate emissions across distinct branches fail closed. The bounded protected-file scan runs only after an exact-prefix miss at a compaction signal.

Runtime Start no longer requires fresh discovery. Verified stale capability metadata remains available for ordinal effort selection and restart. Transport failures preserve the verified cache; explicit authorization/identity/account-mismatch failures invalidate it. Current upstream model rejection remains authoritative; cached metadata is not a promise of entitlement. New routing edits still require a fresh matching-account catalog.

Copied connection exports now add the smallest verified **normal** context window across saved executor routes. Advisor is independent and is not included in that client-history calculation. Unknown/missing/mismatched metadata, or a limit below Claude's supported 100K minimum, generates no invented export. For the locally observed catalog, the new supported export is `CLAUDE_CODE_AUTO_COMPACT_WINDOW=272000`; the app previously generated no compaction-window export. No claim is made about an existing user's shell value. Recopy exports and restart Claude Code after route/model changes. The gateway remains startable without this metadata.

Only explicit upstream `context_length_exceeded` / `prompt_too_long` codes become an Anthropic `invalid_request_error` with recognized `prompt is too long` wording. The same recognized envelope is emitted as an SSE error if the genuine failure arrives after stream commitment; there is no success `message_stop`. Arbitrary 413, schema errors and replay misses remain distinct. The local CL100K estimate now includes functions inside namespaced tool declarations. It remains an estimate rather than a tokenizer guarantee for the upstream model; successful provider usage remains the measured source.

The native Quit lifecycle awaits gateway shutdown before AppKit termination. General → Appearance → Show Dock icon uses persisted default-on activation policy; toggles immediately and hidden-mode Settings/Activity retain accessory policy.

## Regression evidence

- Core: 347 tests / 45 suites pass, including restart/compaction route preservation, opaque item preservation, account/session/changed-argument/branch isolation, legacy matching, ambiguity rejection, cache/offline/auth boundaries, ordinal effort ceilings, window minimum/unknown/mixed routes, error normalization and tool-schema counting.
- macOS: 35 unit tests passed; tests include default-on/immediate/persisted Dock behavior, stale/missing catalog Start/Stop/Start, and exported-window account boundaries.
- Final offline smoke: 74 tests / 7 suites passed. Signed shipping app build and strict code-sign verification passed.
- Offline GUI fixture bundle `com.90percent.Claudex.DockQA` has no gateway listener. Both toggle directions applied regular/accessory policy. Settings and Activity opened focused while hidden, hidden preference remained accessory after relaunch, and the Quit action exited only that fixture. Evidence is stored in the task workspace `claudex-repair-evidence/`.

## Practical limits

Claude Code owns client-history compaction. Claudex does not invoke backend compaction or advertise invented synchronization headers. A copied launch export does not update a running Claude process. The 872K maximum remains unverified for the current Responses path. No additional paid-model call or full real-session post-compaction acceptance was authorized or run during this repair.

## Activation outcome

The final signed build was activated only after an Idle check. Old PID 50463 terminated normally through the new awaited gateway-stop lifecycle; final PID 51251 was started via the native Start control. Direct no-proxy loopback health reports running; sole listener is 127.0.0.1:4317. No model request was sent. No commits or pushes were made.

## Follow-up: foreground Dock transition (2026-10-09)

The owner reproduced a distinct regression: changing regular to accessory policy while Settings was foreground caused delayed AppKit deactivation. Earlier hidden-window opening checks did not exercise this transaction. Immediate activation and next-main-queue activation before resignation both failed the native event regression.

The repair captures only an already active, visible regular-policy window and its original responder. It observes AppKit resignation before requesting foreground activation with the supported NSApplication activate(ignoringOtherApps:) API, then restores key/main/responder state on activation. Observers are cancelled on completion, a subsequent preference application, or window closure. Background transitions install no restoration; there is no timed retry or delay. The installed SDK marks this NSApplication API for future deprecation; the distinct NSRunningApplication ignoringOtherApps option is already ineffective and is not used.

Validation: five focused Dock preference tests pass; the isolated bundled AppKit harness pumps actual native events and passes eight foreground Settings/Activity transitions with the same window and responder, plus both background transitions without activation or window creation. The actual QA Settings window passed two on/off cycles with active/key/main retained. Signed owner build and strict codesign verification pass. Restart preserves accessory policy and hidden-mode Settings opens active. New owner PID 52764 replaced idle PID 51251 through normal termination, native Start reports Idle, direct loopback health reports running, and the sole listener remains 127.0.0.1:4317. No model call, commit, push, or new permission was used. Native regression log: task workspace claudex-repair-evidence/dock-focus-native-harness.log.
