## Dev-Guide Verification Summary
**Status:** complete
**Dev-guide:** /Users/norvyn/Code/Projects/ModelBridge/docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
**Started:** 2026-04-22-091732

---

### V1. Feature Coverage (Gap Analysis → Phases)

This is a refactoring dev-guide; the "design input" is the in-session gap analysis grounded in scheme3 docs. Verified each gap maps to a phase.

Gaps extracted from scheme3 + code evidence:

| Gap (source) | Mapped to | Scope item | Status |
|---|---|---|---|
| Upstream SSE events are buffered end-to-end, not streamed (ResponsesClient.swift:38 `session.data(for:)`; LocalHTTPServer.swift:199-213 Content-Length+close) | Phase 1 | "ResponsesClient.perform切到 URLSession.bytes" + chunked transfer | mapped |
| Typed IR absent; JSONObject ad-hoc (AnthropicBridge.swift:345-355, 690-713, 859-864) | Phase 1 | "新增 Sources/CCRouterCore/IR/" | mapped |
| Claude `model` field never drives upstream routing (AnthropicBridge.swift:295-329 hard-uses configuration.executorModel) | Phase 2 | ModelRoutingTable + buildInitialPayload改签名 | mapped |
| reasoning.effort/verbosity hardcoded (AnthropicBridge.swift:770,776) | Phase 2 | ModelRoute 字段 + probe tasks | mapped |
| User-requested model IDs `gpt-4.5`/`gpt-5.3-codex-spark` not in whitelist (scheme3/10 §7.8) | Phase 2 + DP-001 | probe task + blocking decision | mapped |
| Image/document content blocks silently dropped (convertContentBlocks:345-355) | Phase 3a | 多模态翻译 | mapped |
| `thinking` field parsed but never surfaced (AnthropicProtocol.swift:9; buildAnthropicSSE:503-663 `default: continue`) | Phase 3b | reasoning item → thinking SSE | mapped |
| Assistant-history `tool_use` blocks dropped on replay (convertMessages:331-343 via convertContentBlocks text-only) | Phase 3c | tool_use / tool_result → function_call items | mapped |
| prompt_cache_key random per request (AnthropicBridge.swift:775) | Phase 4 | stable hash by session id | mapped |
| pendingToolTurns无TTL (AnthropicBridge.swift:8) | Phase 4 | lastAccessedAt + eviction | mapped |
| advisor subcall has no context (runAdvisorSubcall:715-735) | Phase 4 | 历史 N messages | mapped |
| Token refresh absent (SubscriptionSession.swift:103-123 only reads access/account) | Phase 5 | 401 → refresh_token flow | mapped |
| count_tokens heuristic `body.count/4` (GatewayDaemon.swift:128) | Phase 5 | BPE tokenization | mapped |
| Routing/Advisor UI + token-status UI missing (ContentView.swift, SettingsView.swift) | Phase 6 | Routing editor + Advisor tab + Token status | mapped |
| E2E verification across all phases | Phase 7 | smoke scripts + acceptance report | mapped |

Scope-bloat check (Phase scope items with no gap origin): none found.

- Features in gap analysis: 15
- Mapped: 15
- Unmapped: 0
- Scope bloat: 0

---

### V2. Dependency Graph Semantics

Declared graph:
- Phase 1: None
- Phase 2: Phase 1
- Phase 3: Phase 1
- Phase 4: Phase 1, Phase 3 (advisor context needs 3c replay)
- Phase 5: None (parallel)
- Phase 6: Phase 2, Phase 4, Phase 5
- Phase 7: all

Analysis:

- Phase 2 → Phase 1: Phase 2 rewrites `buildInitialPayload`/`makeResponsesPayload` signatures and adds `ModelRoute` to `PendingToolTurn`. Phase 1 introduces IR refactor that touches `PendingToolTurn`. Coupling is justified — if done in reverse, both phases would fight over the same struct. Declared dep is correct. [C:90]
- Phase 3 → Phase 1: Phase 3 depends on IR (`IRBlock.image`, `.thinking`, `.toolUse`) introduced in Phase 1 to avoid JSONObject churn. Correct. [C:95]
- Phase 4 declares Phase 1 + Phase 3 deps. Phase 3c dependency for advisor context is cited. Correct. [C:90]
- Phase 5: declares None. Scope touches `SubscriptionSession.swift` + `GatewayDaemon.swift:128` — neither is modified by Phase 1-4. Genuinely parallel. [C:95]
- Phase 6: declares Phase 2/4/5. Scope reads routing fields (Phase 2), cache hit rate display (Phase 4), token status UI (Phase 5). Correct. [C:95]
- Phase 7: depends on everything; correct for acceptance. [C:100]

Over-linear / missing dep findings: none with C ≥ 80.

- Phases: 7
- Over-linear: 0
- Missing: 0

---

### V3. Cross-Phase Data Flow Connectivity

Concepts tracked:

| Concept | Produced by | Consumed by | Connected | Notes |
|---|---|---|---|---|
| Typed IR (`IRBlock.text/.image/.toolUse/.toolResult/.thinking/.serverToolUse/.advisorToolResult`) | Phase 1 | Phase 3 (image, thinking, tool_use replay), Phase 4 (advisor context needs IR-native history) | ✅ | IR enumeration in Phase 1 scope explicitly lists the variants Phase 3 and Phase 4 need |
| `PendingToolTurn` IR-native | Phase 1 | Phase 2 (adds `resolvedRoute`), Phase 4 (adds `lastAccessedAt`) | ✅ | chain holds |
| streaming SSE pipeline | Phase 1 | Phase 6 (trace per event) | ✅ | Phase 6 scope references new trace fields from Phase 1 |
| `ModelRoute` / `ModelRoutingTable` | Phase 2 | Phase 6 (Settings editor), Phase 4 (advisor route) | ✅ | Phase 6 `Upstream tab` editor pulls from Phase 2 types |
| probe whitelist results | Phase 2 (verification task) | Phase 6 (UI dropdown options) + DP-001 resolution | ✅ | acceptance explicitly gates UI options on probe |
| image `input_image` vs `view_image` decision | Phase 3a (verification) | Phase 3a impl | ✅ | self-contained within phase |
| reasoning / thinking surface | Phase 3b | Phase 6 (Dashboard trace feed thinking indicator — implicit) | ⚠️ partial | see finding below |
| assistant-history replay items | Phase 3c | Phase 4 (advisor context uses recent N messages which need to include replayed tool_use) | ✅ | Phase 4 explicitly names Phase 3c dep |
| prompt_cache_key stable hash | Phase 4 | Phase 6 (cache hit rate UI) | ✅ | Phase 6 "Dashboard 可以显示 cache 命中率" |
| refresh_token flow + DoctorSnapshot.pendingToolTurnsCount | Phase 4/5 | Phase 6 (Token status card, pending count visibility) | ✅ | Phase 6 scope names these |
| count_tokens BPE accuracy | Phase 5 | (no downstream in guide) | ⚠️ orphaned | count_tokens is a leaf endpoint; consumer is Claude CLI externally. Guide is correct to leave orphaned |

Findings:

- [V3 - Orphaned] [C:75] count_tokens BPE output is not consumed by any later Phase. Expected behavior (endpoint is Claude-CLI-facing). Listed as low-confidence orphan since it's an intentional leaf. No action required. (Below threshold; in appendix.)
- [V3 - Interface under-specified] [C:82] Phase 3b "reasoning item → thinking SSE" does not specify the IR shape for `.thinking` in the Phase 1 IR section. Phase 1 scope lists `.thinking(String)` but Phase 3b discusses `reasoning` items with `summary` + `encrypted_content`. The IR variant `.thinking(String)` may be too narrow — an `encrypted_content` passthrough + optional `summary` string is two fields, not one. Action: either widen Phase 1 IR to `.thinking(summary: String?, encryptedContent: String?)` or have Phase 3b explicitly extend the IR. The guide already acknowledges an architecture-decision (Phase 3 DP about `reasoning.summary` inclusion), so this is close to resolved but the IR shape is not nailed down.

- Concepts tracked: 11
- Connected: 10
- Disconnected: 0
- Orphaned: 1 (intentional)
- Under-specified: 1

---

### V4. Existing Code Overlap

Spot-checked every file:line reference in the guide:

| Guide claim | Verified against code | Result |
|---|---|---|
| `ResponsesClient.swift:38` is `session.data(for:)` integer-buffered download | Line 38 confirmed: `let (data, response) = try await session.data(for: request)` | ✅ [C:100] |
| `LocalHTTPServer.swift:203` only supports Content-Length + Connection:close | Line 203 inside `send()`, matches `"Content-Length": "\(response.body.count)"`, line 204 `"Connection": "close"` | ✅ [C:100] |
| `AnthropicBridge.swift:162-292` finalizeResponse batches events before emit | Verified: finalizeResponse runs after `responsesClient.perform` returns full array | ✅ [C:100] |
| `AnthropicBridge.swift:345-355` convertContentBlocks only handles `"text"` | Verified: `switch block.string("type") { case "text": ... default: return nil }` | ✅ [C:100] |
| `AnthropicBridge.swift:690-713` stringifyToolResultContent stringifies all content | Verified exactly at those lines | ✅ [C:100] |
| `AnthropicBridge.swift:859-864` PendingToolTurn holds [JSONValue] replayItems | Verified: struct at 859-864 matches | ✅ [C:100] |
| `AnthropicBridge.swift:295-310` buildInitialPayload uses configuration.executorModel | Verified line 301 `model: configuration.executorModel` | ✅ [C:100] |
| `AnthropicBridge.swift:312-329` buildContinuationPayload also hard-uses executorModel | Verified line 323 | ✅ [C:100] |
| `AnthropicBridge.swift:756-783` makeResponsesPayload hardcodes reasoning.effort=xhigh and text.verbosity=low | Verified lines 770, 776 | ✅ [C:100] |
| `AnthropicBridge.swift:775` prompt_cache_key = UUID().uuidString.lowercased() per request | Verified | ✅ [C:100] |
| `AnthropicBridge.swift:8` pendingToolTurns is `[String: PendingToolTurn]` no TTL | Verified | ✅ [C:100] |
| `AnthropicBridge.swift:715-735` runAdvisorSubcall sends fixed string | Verified line 725 exact string "Provide concise strategic guidance for the current task." | ✅ [C:100] |
| `AnthropicBridge.swift:773` `include: ["reasoning.encrypted_content"]` present | Verified | ✅ [C:100] |
| `AnthropicBridge.swift:503-663` buildAnthropicSSE's `default: continue` at :639 drops unknown items | Verified line 639-640 | ✅ [C:100] |
| `AnthropicProtocol.swift:9` `thinking: JSONObject?` exists but unused | Verified line 9; no consumer of `request.thinking` in AnthropicBridge | ✅ [C:100] |
| `SubscriptionSession.swift:103-123` loadCurrent only reads access_token + account_id | Verified: only reads `tokens?.access_token` + `tokens?.account_id`; ignores `refresh_token` in auth.json which I confirmed exists (`~/.codex/auth.json` line 6 has `refresh_token`) | ✅ [C:100] |
| `GatewayDaemon.swift:128` `max(1, request.body.count / 4)` | Verified exactly | ✅ [C:100] |
| `AnthropicBridge.swift` grew 303 → 865 lines (DP-004 context) | Actual: 864 lines; claim is ±1, effectively correct | ✅ [C:95] |

Findings: no over-claims. Every asserted defect is real.

- Scope items checked: 15 load-bearing file:line claims
- Full overlap (rebuilds existing): 0
- Partial overlap (enhances existing): 15 — all correctly framed as enhance/fix/refactor, not "build new"
- No overlap: 0

---

### V5. Term Definitions

Domain-specific terms in the guide:

| Term | Defined? | Source |
|---|---|---|
| typed IR (`IRBlock`) | ✅ Phase 1 Scope enumerates variants: `.text(String)`, `.image(data, mediaType)`, `.toolUse(id, name, input)`, `.toolResult(id, content: [IRBlock])`, `.thinking(String)`, `.serverToolUse`, `.advisorToolResult` | Phase 1 scope |
| ModelRoute / ModelRoutingTable | ✅ Phase 2 Scope defines structure: `upstreamModel`, `reasoningEffort`, `textVerbosity`; `ModelRoutingRule.match` = "对 Claude model 小写 substring 匹配" | Phase 2 scope |
| fallback route | ✅ "`routingTable.fallback`"; migration text explains behavior | Phase 2 scope |
| prompt cache key | ✅ defined implicitly by "基于 x-claude-code-session-id 稳定哈希 (或 header 缺失时 fallback sha256(instructions + stable prefix of input))" | Phase 4 scope |
| pending tool turn TTL | ⚠️ partially — scope says "30 分钟无活动即清" as default, DP defers TTL length choice but never pins the eviction trigger semantics (last_accessed_at vs created_at) | Phase 4 scope + DP |
| refresh_token (Codex) | ✅ sourced to `~/.codex/auth.json` real schema (verified by me); Phase 5 scope says "用 refresh_token 发刷新请求 → 成功则写回 auth.json" | Phase 5 scope |
| Upstream model whitelist | ✅ scheme3/10 §7.8 (cited & verified) | Global Constraints |
| `reasoning.encrypted_content`, `reasoning.summary` | ✅ scheme3/09 §3.2 and §4.2 (cited & verified — §4.2 lines 120-125) | Phase 3 decisions |
| advisor subcall | ✅ scheme3/11 + AnthropicBridge.swift:715 (real impl) | Phase 4 scope |
| resolved_route_match (trace field) | ⚠️ new trace field introduced in Phase 6 but its semantics (which rule ID matched, or the match string) not specified | Phase 6 scope |

Metrics in acceptance criteria:

| Metric | Formula? | Status |
|---|---|---|
| "第一个 content_block_delta 在 response.output_text.delta 到达后 50ms 内读到" | ✅ concrete (observable, wall-clock) | pass |
| "偏差均 ≤10%" (count_tokens accuracy) | ✅ concrete — BPE output vs `usage.input_tokens` ground truth, 10% relative error | pass |
| "至少 2 个不同 upstream_model 值" (routing分流 proof) | ✅ concrete, `jq` pipeline given | pass |
| "cache 命中率" (Dashboard) | ⚠️ Phase 4 acceptance uses "同一 session 连续 3 条请求 prompt_cache_key sort -u 仅 1 值" as the real check — concrete. But the Dashboard display "cache 命中率" in Phase 6 scope is not given a formula. | partial |
| "p50 / p95" (TraceDiagnostics per upstream_model) | ⚠️ introduced in Phase 6 scope; assumed standard percentile, no window specified | partial |

Findings:

- [V5 - Undefined trace field semantic] [C:82] Phase 6 introduces trace field `resolved_route_match` but does not define what value is logged (rule index, rule `match` string, matched substring, or the Claude model that matched). Action: specify in Phase 6 scope, e.g. `resolved_route_match: string` = the substring keyword that matched, or `"fallback"` when no rule matched.
- [V5 - Undefined metric: cache hit rate display] [C:82] Phase 6 scope says "Dashboard 可以显示 cache 命中率" but no formula for what counts as a hit. Action: define, e.g. "hit := upstream usage.cached_tokens > 0 when cache_key stable" — or defer the UI element to a later phase.
- [V5 - Under-specified: pending tool turn eviction trigger] [C:80] Phase 4 scope adds `lastAccessedAt` and says "30 分钟无活动即清" but DP-decision says TTL is not yet fixed. Eviction-trigger semantics (access bumps lastAccessedAt, or only create time) should be pinned or made a DP option.

- New terms found: 10
- Defined: 7
- Under-specified: 3

---

### V6. Acceptance Criteria Quality

Examined all `- [ ]` items under `**Acceptance criteria:**`:

Phase 1 (7 criteria):
- All command-verifiable or observably concrete (`swift test` return, SSE 50ms delta, trace file keys). pass.

Phase 2 (7 criteria):
- All concrete. Probe report is a file-existence + content check. pass.

Phase 3 (7 criteria):
- "CLI 输出里能看到 thinking 指示器而不是空转" — slightly weaker: what exact string indicates success? Suggested sharpening: "the CLI emits at least one `thinking` content block with `text` non-empty, observable by `jq '.type=="content_block_start" and .content_block.type=="thinking"'`".
- "3a/3b/3c 各自独立的 verification task 报告写入 docs/research/" — concrete (file exists + contains probe results).

Phase 4 (6 criteria):
- All concrete. `tail /tmp/modelbridge-trace.jsonl | jq ... sort -u` output 1 value — command-verifiable. pass.

Phase 5 (5 criteria):
- ≤10% deviation — concrete.
- "daemon 自动 refresh" — concrete via trace field.

Phase 6 (6 criteria):
- "`grep upstream_model /tmp/modelbridge-trace.jsonl | jq -r .upstream_model | sort -u`输出至少2个不同值" — concrete.
- "Routing insights 能看到3条独立行" — UI-observable, listed under /ui-review.
- "Token status 卡片可见" — concrete.

Phase 7 (8 criteria):
- "至少 1 小时的真实交互使用 session 无未恢复错误" — subjective boundary ("unrecovered error" not defined). Minor.

Findings:

- [V6 - Slightly Vague] [C:78] Phase 3 criterion "CLI 输出里能看到 thinking 指示器" — "thinking 指示器" presumes a specific UI affordance. Suggested: "trace file contains at least one `content_block_start` event where `content_block.type == "thinking"` during a request with `thinking: enabled`". (Low-confidence; not blocking.)
- [V6 - Subjective boundary] [C:72] Phase 7 "1 小时真实使用无未恢复错误" — "unrecovered error" not defined. Suggested: "no `daemon` trace entries with `result == "responses_http_error"` sustained > 2 consecutive requests". (Low-confidence; not blocking.)

- Criteria checked: 46 total
- Fully specific: 43
- Slightly vague (improvement opportunities): 2
- Untestable: 0

---

### V7. Structural Integrity

YAML frontmatter: present. All fields populated:
- `type: dev-guide` ✅
- `status: active` ✅
- `tags: [modelbridge, refactoring, anthropic-bridge, routing, streaming, multimodal]` ✅ (6 tags; slightly above the 2-5 guideline)
- `refs:` ✅ (6 entries, includes project brief + scheme3 sources)
- `current: true` ✅

Phase sections: each `## Phase N:` has:
- `**Goal:**` ✅
- `**Depends on:**` ✅
- `**Scope:**` ✅
- `**用户可见的变化:**` ✅
- `**Architecture decisions:**` ✅
- `**Acceptance criteria:**` ✅
- `**Review checklist:**` ✅

Section markers: all 7 phases have correctly paired `<!-- section: phase-N keywords: ... -->` ... `<!-- /section -->` with 3-5 keywords per section.

Review checklist consistency:
- Phase 1-5: have `/execution-review` + domain-specific items (architecture review, long-run regression, etc.). No UI scope → no /ui-review needed. ✅
- Phase 3: has UI-observable behavior (screenshot input, thinking indicator) — has `/feature-review` but not `/ui-review`. Phase 3 does not touch SwiftUI views so /ui-review is not required. ✅
- Phase 6: has heavy UI work — has `/ui-review` + `/feature-review`. ✅
- Phase 7: has `/feature-review` + `/submission-preview`. ✅

Findings:

- [V7 - Minor] [C:90] Tags array has 6 entries; the dev-workflow contract says 2-5. Trim `anthropic-bridge` (redundant with `modelbridge`) or merge.

- Issues: 1 minor

---

### Low-Confidence Appendix (C < 80)

- [C:75] count_tokens BPE is produced by Phase 5 and not consumed by any later phase — intentional leaf (Claude CLI is the external consumer). No action. Low confidence because "orphan" in the V3 sense doesn't strictly apply to endpoints.
- [C:78] Phase 3 "thinking 指示器" criterion could be sharpened to a command-verifiable form. Improvement only.
- [C:72] Phase 7 "无未恢复错误" subjective boundary. Improvement only.

---

## Decisions

### [DP-V1] Phase 1 IR `.thinking` variant shape (recommended)

**Context:** Phase 1 Scope defines `.thinking(String)`. Phase 3b scope discusses `reasoning` items with two relevant payloads: `encrypted_content` (for context replay across turns — `docs/scheme3/09 §3.2` L96) and optional `summary` (upstream returns `summary` in reasoning items — `docs/scheme3/09 §4.2` L125). Collapsing both into a single `String` loses information the later phases need. Phase 4 advisor-context phase depends on replaying history, which requires `encrypted_content` passthrough.

**Options:**
- A: Widen Phase 1 IR to `.thinking(summary: String?, encryptedContent: String?)` now — cost: Phase 1 IR touches one more case.
- B: Leave Phase 1 `.thinking(String)`, extend IR in Phase 3b — cost: Phase 3b modifies Phase 1 artifact, violates IR-stability promise made in DP-004.
- C: Defer: Phase 1 only models what's needed for Phase 1 tests (text surface), Phase 3b adds the multi-field variant as a net-new IR case — cost: two variants of the same concept in IR.

**Recommendation:** A — IR stability is the explicit value proposition in DP-004 (Phase 1 gets it right once). scheme3/09 §4.2 L120-125 shows upstream reasoning items already have both fields; the typed shape must reflect that. Cost of Option A is one additional field in one enum case.

### [DP-V2] Phase 6 `resolved_route_match` trace field semantics (recommended)

**Context:** Phase 6 scope adds trace field `resolved_route_match` alongside `claude_model` / `upstream_model` / `reasoning_effort` / `text_verbosity`. The value logged is not specified.

**Options:**
- A: Log the matched rule's `match` substring (or `"fallback"`) — cheap, debuggable, human-readable.
- B: Log rule index into `routingTable.rules` — stable across renames, but opaque.
- C: Log both as separate fields (`resolved_rule_index` + `resolved_rule_match`) — most info, slight trace bloat.

**Recommendation:** A — Phase 6 Dashboard needs to display "哪条规则命中" to users; a rule index does not survive rule reordering in UI edits. Matches the Dashboard scope text "当前路由 → `<upstream model>` · `<effort>`".

### [DP-V3] Phase 4 pendingToolTurns eviction trigger semantics (recommended)

**Context:** Phase 4 scope adds `lastAccessedAt: Date` with "30 分钟无活动即清" default, but the DP section leaves TTL length open and does not specify when `lastAccessedAt` is bumped. If only the store time is tracked, a long multi-step tool turn could be evicted mid-turn.

**Options:**
- A: Bump `lastAccessedAt` on every read AND write of the entry — tool turns of arbitrary duration survive as long as Claude CLI keeps pinging.
- B: Bump only on write (continuation store) — predictable but kills legitimate long tool turns.
- C: Use a separate `createdAt` + `lastAccessedAt` where eviction uses the max of (now - lastAccessed > 30m) and hard cap (now - createdAt > 2h) — safer against zombie turns.

**Recommendation:** A — most tool turns are bounded-latency; the load-bearing value is preventing zombie accumulation when Claude CLI disconnects. A hard cap can be added later if real traces show zombie turns that keep getting polled.

### [DP-V4] Phase 5 / Phase 6 cache hit rate metric definition (recommended)

**Context:** Phase 6 scope mentions displaying "cache 命中率" in the Dashboard but never defines what a hit is. Upstream `/responses` returns `usage.cached_tokens` (scheme3/08 §4.3 area). Without a formula, the UI element is under-specified.

**Options:**
- A: `hit_rate = count(requests where usage.cached_tokens > 0) / count(total requests)` over a sliding window.
- B: `token_hit_rate = sum(cached_tokens) / sum(input_tokens)` — richer but harder to explain.
- C: Defer the UI element to a post-Phase-6 follow-up.

**Recommendation:** A — simplest to compute, matches user intent ("was this request cached?"); `cached_tokens` field presence is already validated in scheme3 §4.3 field list.

---

## Verdict

**must-revise** — 0 blocking findings (no V1 unmapped / V2 missing-dep / V3 disconnected / V4 full-overlap / V5 undefined metric in acceptance / V7 missing field). However, **4 recommended decisions (DP-V1..V4)** surface before the guide is ready to run.

Given the rubric:
- V3 has 1 interface under-specification (IR `.thinking` shape) — C:82, which is ≥ threshold but is classified as "under-specified interface", not "disconnected"; this is the DP-V1 decision rather than a hard blocker.
- V5 has 3 under-specified terms, two of which affect Phase 6 acceptance shape. These are DP-V2 and DP-V4.
- V7 has 1 minor (tag count).

Per rubric: none of the 5 strict must-revise triggers (V1/V2/V3-disconnected/V4-full/V5-undefined-metric-in-acceptance/V7-missing) fire with C ≥ 80. Formal verdict is:

**approved** with 4 recommended decisions to confirm before Phase 1 start.
