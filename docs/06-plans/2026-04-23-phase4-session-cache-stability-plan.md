---
type: plan
status: active
tags: [modelbridge, cache-key, pending-tool-turn, advisor-context, ttl, eviction]
refs:
  - docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
  - docs/scheme3/08-responses-http-contract.md
  - docs/scheme3/11-advisor-bridge.md
---

# Phase 4: Session State & Cache Stability Implementation Plan

**Goal:** Make prompt cache actually hit on same session; bound `pendingToolTurns` growth with TTL eviction; give advisor sub-call real session context instead of the fixed guidance string.

**Architecture:** Derive `prompt_cache_key` deterministically from `x-claude-code-session-id` (with SHA-256 fallback on header absence). Track `lastAccessedAt` per `PendingToolTurn` + sweep on each request using the existing actor's serialization for safety (no extra timer). Thread current `instructions` + `requestIR` through `handleOutputBlocks` into `runAdvisorSubcall`, truncated to last N user/assistant messages.

**Tech Stack:** Swift 6 actor concurrency, Foundation CommonCrypto (SHA-256), Swift Testing (`@Test` / `#expect`).

**Design doc:** `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md` § Phase 4

**Design analysis:** none

**Crystal file:** none (visual expectations are covered by dev-guide § Phase 4 `用户可见的变化`)

**Threat model:** included (scope keywords: `token`, `auth`, `credential`, `validate`, `hash`)

---

## Threat Model

### Attack surface

- `x-claude-code-session-id` header: user-controllable via any client the gateway auth accepts. Attack class: cache-key collision (attacker picks same session ID as another user → upstream cache entries could be shared). Mitigation: cache key is already namespaced by OAuth `account_id` at upstream (each ChatGPT subscription has a separate cache pool). Within a single installation the gateway is bound to one subscription's `account_id` (`SubscriptionCredentials.accountID`), so cross-user collisions require compromising the local auth token first.
- Fallback SHA-256 input (instructions + first message): plaintext contents of user's Claude Code CLI prompt. Attack class: accidental logging. Mitigation: only the hashed key (opaque 64-hex string) is written to traces or payloads; raw inputs are not.

### Failure modes

- PromptCacheKey SHA-256 computation is total — Swift `String.utf8` view cannot fail, and `SHA256.finalize()` is infallible. No runtime failure path to design for.
- TTL eviction sweep throwing: sweep wraps `defer` cleanup in a non-throwing closure; actor isolation prevents partial-map corruption. Fall-back: entry stays, evicted on next sweep.
- Advisor context serialization failure (message body contains non-UTF-8): skip that message, continue with the rest. Advisor must not block the main turn.

### Resource lifecycle

- `pendingToolTurns` map entries: created in `handleOutputBlocks` (tool-use branch), cleaned on (a) success — next continuation's `handleOutputBlocks` removes via explicit `removeValue` (existing behavior), (b) error — `catch` block calls `removeValue` (existing behavior, AnthropicBridge.swift:244, :338, :652), (c) TTL sweep on any new request (new in this phase). Cleanup on daemon SIGTERM: not applicable — map is in-memory, entire process dies.
- No new file handles, sockets, or child processes introduced.

### Input validation requirements

- `x-claude-code-session-id` header value: validate length ≤ 512 bytes and UTF-8 parseable before using as key basis; longer/invalid values fall through to the SHA-256 fallback branch. Enforced in `PromptCacheKey.stable(...)`.
- Advisor history message text: no embedding in structured format beyond JSON strings (handled by Foundation JSONEncoder).

---

## Decisions

### [DP-001-P4] TTL length for pendingToolTurn eviction (recommended)

**Context:** dev-guide § Phase 4 Architecture decisions lists `pending tool turn TTL 长度（30min / 10min / 可配置）` as open. Interactive Claude CLI sessions frequently pause 5–15 minutes between tool calls (user reviewing output before providing next tool result).

**Options:**
- A: Fixed 30 minutes — simple, covers typical interactive lull.
- B: Fixed 10 minutes — aggressive cleanup; risks stale-detect on slow users reviewing long traces.
- C: Configurable via `RouterConfiguration.pendingToolTurnTTLSeconds` (default 1800, i.e. 30 min) — simple + future-proof.

**Chosen:** C — configurable via `RouterConfiguration.pendingToolTurnTTLSeconds` (default 1800s).

### [DP-002-P4] prompt_cache_key fallback scope when session header absent (recommended)

**Context:** dev-guide § Phase 4 Architecture decisions lists `cache key 的 fallback 哈希范围（整个 input 还是只哈希 instructions + 第一条 message）` as open. The primary path uses `x-claude-code-session-id` from request headers (always present for real Claude CLI, per `AnthropicBridge.swift:42`). Fallback triggers only when the header is missing (non-CLI clients, probes, tests).

**Options:**
- A: `SHA-256(instructions + first user message text)` — stable across continuation turns that share the same prefix; different conversations hash differently.
- B: `SHA-256(instructions only)` — any two sessions sharing system prompt collide (dangerous: advisor/executor sub-calls use shared instructions → false cache hits).
- C: `SHA-256(instructions + full input)` — changes every turn → no cache hit on the prefix (defeats the purpose).

**Chosen:** A — SHA-256(instructions + first user message text).

### [DP-003-P4] Advisor history truncation strategy (recommended)

**Context:** dev-guide § Phase 4 Architecture decisions lists `advisor 子调用的历史截断策略（按 token 数、按 message 数、按字符数）` as open. Default N=8 is noted in scope.

**Options:**
- A: Last 8 messages (message-count based) — predictable, aligned with dev-guide default, simple.
- B: Last 4000 characters — robust to large single messages but unnatural boundary (cuts mid-message).
- C: Last 2000 tokens (via BPE) — requires `tiktoken` / swift-tokenizers which is Phase 5 territory; unnecessary coupling.

**Chosen:** A — last N=8 messages (N configurable via `RouterConfiguration.advisorContextMessageLimit`).

### [DP-004-P4] Eviction mechanism — lazy sweep vs background timer (recommended)

**Context:** dev-guide § Phase 4 scope says `后台 evict（30 分钟无活动即清）`. Background timer = an additional Task/Timer running even when no requests arrive. Lazy sweep = O(n) scan on each new request (map is small, usually < 10 entries).

**Options:**
- A: Lazy sweep on each `handleMessages` request — runs inside the actor's serialization, no extra concurrency primitive, O(n) where n ≈ active sessions count (small).
- B: Background `Task` with `Task.sleep(for: .seconds(60))` loop inside the actor — constant overhead even when idle, lifecycle tied to actor deinit (messy for testing).
- C: Hybrid — lazy sweep + expose a manual `evictStale()` method for tests.

**Chosen:** C — lazy sweep on each handleMessages + public `evictStalePending(now:)` hook for tests.

---

<!-- section: task-1 keywords: PromptCacheKey, sha256, session-id, stable-hash -->
### Task 1: Add `PromptCacheKey` helper module

**Files:**
- Create: `Sources/CCRouterCore/PromptCacheKey.swift`
- Test: `Tests/CCRouterCoreTests/PromptCacheKeyStabilityTests.swift`

**Steps:**

1. Create `Sources/CCRouterCore/PromptCacheKey.swift` with a pure struct + static function. Signature:

   ```swift
   import Foundation
   import CryptoKit

   public enum PromptCacheKey {
       /// Derives a stable cache key. When `sessionID` is non-empty and ≤ 512 bytes,
       /// returns the sanitised session ID (lowercased). Otherwise falls back to
       /// `sha256(instructions + firstUserMessageText)` rendered as 64-hex.
       public static func stable(
           sessionID: String?,
           instructions: String,
           firstUserMessageText: String
       ) -> String {
           if let id = sessionID,
              !id.isEmpty,
              id.utf8.count <= 512 {
               return id.lowercased()
           }
           var hasher = SHA256()
           hasher.update(data: Data(instructions.utf8))
           hasher.update(data: Data([0x1F]))  // unit separator, avoids accidental collisions
           hasher.update(data: Data(firstUserMessageText.utf8))
           let digest = hasher.finalize()
           return digest.map { String(format: "%02x", $0) }.joined()
       }
   }
   ```

2. Create `Tests/CCRouterCoreTests/PromptCacheKeyStabilityTests.swift`:

   ```swift
   import Foundation
   import CryptoKit
   @testable import CCRouterCore
   import Testing

   struct PromptCacheKeyStabilityTests {
       @Test
       func returnsSessionIDLowercasedWhenPresent() {
           let key = PromptCacheKey.stable(
               sessionID: "ABC-123",
               instructions: "irrelevant",
               firstUserMessageText: "irrelevant"
           )
           #expect(key == "abc-123")
       }

       @Test
       func sameSessionProducesSameKey() {
           let a = PromptCacheKey.stable(sessionID: "s1", instructions: "x", firstUserMessageText: "y")
           let b = PromptCacheKey.stable(sessionID: "s1", instructions: "different", firstUserMessageText: "different")
           #expect(a == b)
       }

       @Test
       func fallbackHashingIsDeterministic() {
           let a = PromptCacheKey.stable(sessionID: nil, instructions: "sys", firstUserMessageText: "hello")
           let b = PromptCacheKey.stable(sessionID: nil, instructions: "sys", firstUserMessageText: "hello")
           #expect(a == b)
           #expect(a.count == 64)
       }

       @Test
       func fallbackDifferentInputsProduceDifferentKeys() {
           let a = PromptCacheKey.stable(sessionID: nil, instructions: "sys", firstUserMessageText: "hello")
           let b = PromptCacheKey.stable(sessionID: nil, instructions: "sys", firstUserMessageText: "world")
           #expect(a != b)
       }

       @Test
       func separatorPreventsShiftCollision() {
           // "ab" + sep + "cd"  must differ from "a" + sep + "bcd"
           let a = PromptCacheKey.stable(sessionID: nil, instructions: "ab", firstUserMessageText: "cd")
           let b = PromptCacheKey.stable(sessionID: nil, instructions: "a", firstUserMessageText: "bcd")
           #expect(a != b)
       }

       @Test
       func emptySessionFallsBack() {
           let a = PromptCacheKey.stable(sessionID: "", instructions: "sys", firstUserMessageText: "hi")
           #expect(a.count == 64)
       }

       @Test
       func oversizedSessionFallsBack() {
           let big = String(repeating: "a", count: 1024)
           let a = PromptCacheKey.stable(sessionID: big, instructions: "sys", firstUserMessageText: "hi")
           #expect(a.count == 64)
       }
   }
   ```

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild -Xswiftc -warnings-as-errors`
Expected: Build succeeds with no warnings.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter PromptCacheKeyStabilityTests`
Expected: all 7 tests pass.
<!-- /section -->

---

<!-- section: task-2 keywords: AnthropicBridge, makeResponsesPayload, prompt_cache_key, wire-through -->
### Task 2: Wire stable cache key through `AnthropicBridge`

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:42` (raw header extraction), `:155-274` (runStreamingTurn signature), `:276-353` (runInitialTurn signature), `:461-476` (handleOutputBlocks signature), `:559-571` (runAdvisorSubcallAndSecondPass signature), `:721-733` (runAdvisorSubcall signature), `:764-795` (makeResponsesPayload signature)

**Steps:**

1. Extend a small helper inside `AnthropicBridge` that extracts the first user-message text from an `[IRMessage]`:

   ```swift
   private func firstUserMessageText(from messages: [IRMessage]) -> String {
       for message in messages where message.role == "user" {
           for block in message.content {
               if case .text(let s) = block, !s.isEmpty { return s }
           }
       }
       return ""
   }
   ```

   Place it in the `// MARK: - Helpers (preserved from original)` block near `joinedSystemText` (around `AnthropicBridge.swift:665`).

2. **⚠️ Critical wiring fix.** `handleMessages` at `AnthropicBridge.swift:42` currently collapses the raw header into a UUID fallback *before* anything else can see it. We need the raw header (nullable) reaching `PromptCacheKey.stable`, else the SHA-256 fallback branch is dead. Update `handleMessages`:

   ```swift
   let sessionHeader = request.headers["x-claude-code-session-id"]   // may be nil
   let sessionID = sessionHeader ?? UUID().uuidString.lowercased()    // keep existing UUID fallback for trace / pendingToolTurns keys
   ```

   Thread `sessionHeader: String?` alongside the existing `sessionID: String` through `runStreamingTurn` → `runInitialTurn` → `handleOutputBlocks` → `runAdvisorSubcallAndSecondPass`. Only `PromptCacheKey.stable(sessionID:...)` receives `sessionHeader`; every other consumer (trace logging, pendingToolTurns key) continues to use `sessionID` as today.

3. Change `makeResponsesPayload` signature (`AnthropicBridge.swift:764`):

   ```swift
   private func makeResponsesPayload(
       route: ModelRoute,
       instructions: String,
       input: [JSONValue],
       tools: [JSONObject],
       toolChoice: JSONValue,
       promptCacheKey: String   // NEW: caller computes via PromptCacheKey.stable(...)
   ) -> JSONObject {
       ...
       "prompt_cache_key": .string(promptCacheKey),   // replaces UUID().uuidString.lowercased()
       ...
   }
   ```

4. Update all four call sites to compute `promptCacheKey` with `PromptCacheKey.stable(...)` using the raw `sessionHeader`:

   - **Initial turn** (`runInitialTurn`, around `AnthropicBridge.swift:291`):
     ```swift
     let cacheKey = PromptCacheKey.stable(
         sessionID: sessionHeader,          // raw header, may be nil — triggers SHA-256 fallback
         instructions: instructions,
         firstUserMessageText: firstUserMessageText(from: requestIR)
     )
     let initialPayload = makeResponsesPayload(
         route: resolvedRoute,
         instructions: instructions,
         input: input,
         tools: tools,
         toolChoice: .string("auto"),
         promptCacheKey: cacheKey
     )
     ```

   - **Continuation turn** (inside `runStreamingTurn`, around `AnthropicBridge.swift:193`): reuse the same session-based key so continuation hits the same cache partition as the initial:
     ```swift
     let cacheKey = PromptCacheKey.stable(
         sessionID: sessionHeader,
         instructions: joinedSystemText(from: request.system ?? []),
         firstUserMessageText: firstUserMessageText(from: requestIR)
     )
     let continuationPayload = makeResponsesPayload(
         route: pending.resolvedRoute,
         instructions: "",
         input: replayInput + toolResultInput,
         tools: pending.convertedTools,
         toolChoice: .string("auto"),
         promptCacheKey: cacheKey
     )
     ```

   - **Advisor second pass** (`runAdvisorSubcallAndSecondPass`, around `AnthropicBridge.swift:605`): reuse the same `cacheKey` computed by the caller — add `promptCacheKey: String` to the function signature and thread it in from `handleOutputBlocks` (which in turn receives it from `runInitialTurn` / `runStreamingTurn` continuation).

   - **Advisor sub-call** (`runAdvisorSubcall`, around `AnthropicBridge.swift:721`): advisor has its own `advisorRoute` but shares the session; reuse the same `cacheKey`:
     ```swift
     let advisorPayload = makeResponsesPayload(
         route: configuration.advisorRoute,
         instructions: "You are a planning advisor...",
         input: [.object(advisorMessage)],
         tools: [],
         toolChoice: .string("none"),
         promptCacheKey: cacheKey  // passed in from caller
     )
     ```

5. Add `prompt_cache_key` to the three `TraceLogger.log` sites that record `responses_out_*` stages (`:299-307`, `:201-216`, `:613-619`) so real-machine verification via `jq .prompt_cache_key /tmp/modelbridge-trace.jsonl` works. The local variable is named `cacheKey` in `runInitialTurn` / `runStreamingTurn` continuation, and `promptCacheKey` (the function parameter name) in `runAdvisorSubcallAndSecondPass` — use whichever name is in scope at each log site:

   ```swift
   "prompt_cache_key": .string(cacheKey),         // in runInitialTurn / runStreamingTurn continuation
   "prompt_cache_key": .string(promptCacheKey),   // in runAdvisorSubcallAndSecondPass
   ```

6. Add a regression test to `BridgeRegressionTests.swift` (or extend `ModelRoutingBridgeIntegrationTests.swift`) that fires two requests *without* the `x-claude-code-session-id` header, same body, and asserts both captured request payloads have the same `prompt_cache_key` (proves the SHA-256 fallback path is live):

   ```swift
   @Test
   func requestsWithoutSessionHeaderShareStableCacheKey() async throws {
       let mockClient = MockResponsesClient(streams: [
           MockResponsesEventStream.textOnlyTurn(text: "ok"),
           MockResponsesEventStream.textOnlyTurn(text: "ok"),
       ])
       let bridge = AnthropicBridge(configuration: Self.testConfig, responsesClient: mockClient, sessionLoader: MockSessionLoader())

       // AnthropicMessagesRequest has 11 memberwise fields — use JSON decode path
       // (matches AnthropicProtocol.swift:47 textOnlyFixture pattern).
       let bodyJSON = """
       {"model":"claude-sonnet-4-6","max_tokens":512,"stream":true,
        "messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
       """
       let body = Data(bodyJSON.utf8)
       let req = HTTPRequest(method: "POST", path: "/v1/messages", headers: [:], body: body)

       _ = await bridge.handleMessages(req)
       _ = await bridge.handleMessages(req)

       let captured = await mockClient.capturedRequests
       #expect(captured.count == 2)
       let k1 = captured[0].string("prompt_cache_key")
       let k2 = captured[1].string("prompt_cache_key")
       #expect(k1 == k2)
       #expect(k1?.count == 64)   // SHA-256 hex
   }
   ```

   (Reuse `MockResponsesClient` already defined in `MockResponsesEventStream.swift:339` — it exposes `capturedRequests: [JSONObject]`.)

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild`
Expected: build succeeds.
Run: `grep -n 'UUID().uuidString.lowercased()' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: two matches — `installationID` init at `:38`, and the `sessionID` fallback in `handleMessages` at the updated `:42` area. The former `:791` `prompt_cache_key` line must NOT appear (now uses `cacheKey`).
Run: `grep -c 'promptCacheKey:' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: ≥ 5 occurrences (4 call sites + helper signature).
Run: `grep -c 'sessionHeader' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: ≥ 5 occurrences (raw extraction in handleMessages + threaded into 4 functions).
<!-- /section -->

---

<!-- section: task-3 keywords: RouterConfiguration, ttl, advisor-limit, fallback-scope, migration -->
### Task 3: Add Phase 4 `RouterConfiguration` fields

**Files:**
- Modify: `Sources/CCRouterCore/RouterConfiguration.swift:3-60` (struct + init + Codable)
- Modify: `Sources/CCRouterCore/RouterConfigurationStore.swift:94-113` (regenerateGatewayToken — rotation path), `:155-173` (resolveConfiguration — load path), `:286-303` (StoredConfiguration struct — persistence shape)
- Test: `Tests/CCRouterCoreTests/RouterConfigurationMigrationTests.swift` (extend existing suite)

**Steps:**

1. Add three new fields to `RouterConfiguration` (after `advisorRoute`, before `gatewayAuthToken`):

   ```swift
   public let pendingToolTurnTTLSeconds: Int         // default 1800 (DP-001-P4)
   public let advisorContextMessageLimit: Int        // default 8 (DP-003-P4)
   ```

   Note: fallback scope for cache key is a code-level constant (DP-002-P4 chosen: `instructions + first user message`), not a user-configurable field. If future phases need to make it configurable, extend then — YAGNI for Phase 4.

2. Update the canonical `init(...)` to accept and assign these two fields, with default values in the init signature:
   ```swift
   pendingToolTurnTTLSeconds: Int = 1800,
   advisorContextMessageLimit: Int = 8,
   ```

3. Update `CodingKeys` enum to add `pendingToolTurnTTLSeconds`, `advisorContextMessageLimit`.

4. Update `init(from decoder:)` to read the new fields with `decodeIfPresent(...) ?? <default>` so old `config.json` files still load:
   ```swift
   pendingToolTurnTTLSeconds = try c.decodeIfPresent(Int.self, forKey: .pendingToolTurnTTLSeconds) ?? 1800
   advisorContextMessageLimit = try c.decodeIfPresent(Int.self, forKey: .advisorContextMessageLimit) ?? 8
   ```

5. Update `encode(to:)` to write the new fields unconditionally.

6. **⚠️ Multiple construction sites — thread Phase 4 fields through every translation boundary**.

   `RouterConfiguration` and `StoredConfiguration` are separate structs. The translation boundary gets hit in 5 places. Missing any one causes silent data loss (values reset to defaults on disk round-trip).

   a. **Add fields to `StoredConfiguration` struct** (`RouterConfigurationStore.swift:286-303`) WITHOUT inline defaults — Swift Codable synthesis cannot overwrite a `let` property that has an initial value (verified with `swift /tmp/test_codable.swift`: the compiler emits `immutable property will not be decoded because it is declared with an initial value which cannot be overwritten` and the decoded value is always `nil` regardless of JSON contents — silent data loss). Use plain optionals:
      ```swift
      private struct StoredConfiguration: Codable {
          // ... existing fields ...
          let subscriptionAuthBookmarkData: Data?
          // Phase 4 additions.
          let pendingToolTurnTTLSeconds: Int?
          let advisorContextMessageLimit: Int?
      }
      ```
      Because there are no inline defaults, the fresh-install memberwise-init site at `:33-47` MUST also be updated to pass `nil` for both new fields (see sub-step (a2) below).

   a2. **Update the fresh-install memberwise init at `RouterConfigurationStore.swift:33-47`** to pass `nil` for both new fields:
      ```swift
      let created = normalizedConfiguration(from: StoredConfiguration(
          host: nil,
          // ... existing fields ...
          subscriptionAuthBookmarkData: nil,
          pendingToolTurnTTLSeconds: nil,
          advisorContextMessageLimit: nil
      ))
      ```
      This path is hit on the very first daemon launch before any config.json exists. Defaults (1800 / 8) are applied later in `resolveConfiguration` step (b).

   b. **`resolveConfiguration(...)`** (`:117-170`): add to the final `RouterConfiguration(...)` build at `:155-170`, reading from `stored` with defaults:
      ```swift
      pendingToolTurnTTLSeconds: stored.pendingToolTurnTTLSeconds ?? 1800,
      advisorContextMessageLimit: stored.advisorContextMessageLimit ?? 8,
      ```
      Place these in the parameter list adjacent to `advisorRoute` / `gatewayAuthToken` to match the canonical init order.

   c. **`save(configuration:)`** (`:62-92`): this path converts `RouterConfiguration` → `StoredConfiguration` explicitly via 14 named args at `:65-79`. Add the two new fields to that call after `subscriptionAuthBookmarkData`:
      ```swift
      subscriptionAuthBookmarkData: configuration.subscriptionAuthBookmarkData,
      pendingToolTurnTTLSeconds: configuration.pendingToolTurnTTLSeconds,
      advisorContextMessageLimit: configuration.advisorContextMessageLimit
      ```
      Missing this = user saves config via Settings UI → Phase 4 fields drop to disk as `nil` → next load resets them to defaults.

   d. **`normalizedConfiguration(from:)`** (`:190-230`): this normalisation helper also returns a `StoredConfiguration` at `:214-229` via 14 named args. Thread the new fields through from the input `configuration` (a `StoredConfiguration`), preserving them verbatim:
      ```swift
      subscriptionAuthBookmarkData: configuration.subscriptionAuthBookmarkData,
      pendingToolTurnTTLSeconds: configuration.pendingToolTurnTTLSeconds,
      advisorContextMessageLimit: configuration.advisorContextMessageLimit
      ```
      Missing this = `save()` → `normalizedConfiguration()` → persist → the new fields get stripped at the normalisation step.

   e. **`regenerateGatewayToken(...)`** (`:94-113`): this is the token-rotation path — it rebuilds a `RouterConfiguration` from an old one with just `gatewayAuthToken` replaced. Swift enforces init-arg declared order, so Phase 4 fields must match the position declared in `RouterConfiguration.swift` (Task 3 Step 2 placed them between `advisorRoute` and `gatewayAuthToken`). The inner `RouterConfiguration(...)` call at `:96-111` needs:
      ```swift
      responsesURL: configuration.responsesURL,
      routingTable: configuration.routingTable,
      advisorRoute: configuration.advisorRoute,
      pendingToolTurnTTLSeconds: configuration.pendingToolTurnTTLSeconds,   // NEW — immediately after advisorRoute
      advisorContextMessageLimit: configuration.advisorContextMessageLimit, // NEW
      gatewayAuthToken: makeGatewayToken(),
      gatewayAuthHeader: configuration.gatewayAuthHeader,
      subscriptionAuthFilePath: configuration.subscriptionAuthFilePath,
      subscriptionAuthBookmarkData: configuration.subscriptionAuthBookmarkData,
      configurationPath: configuration.configurationPath,
      configurationWarning: configuration.configurationWarning
      ```
      Missing this = user rotates their gateway token → Phase 4 config fields silently reset to defaults.

   f. **Verify all construction sites are updated** before running tests:
      ```bash
      grep -n 'pendingToolTurnTTLSeconds\|advisorContextMessageLimit' Sources/CCRouterCore/RouterConfigurationStore.swift
      ```
      Expected: ≥ 10 matches total (2 fields × 5 sites: the struct declaration + the 4 code sites a2/b/c/d/e).

7. Add two `@Test` cases to `RouterConfigurationMigrationTests.swift`:

   ```swift
   @Test
   func legacyConfigWithoutPhase4FieldsUsesDefaults() throws {
       let legacyJSON = """
       { "host":"127.0.0.1", "port":4317, "healthPath":"/health", "messagesPath":"/v1/messages",
         "countTokensPath":"/v1/messages/count_tokens",
         "responsesURL":"https://chatgpt.com/backend-api/codex/responses",
         "executorModel":"gpt-5.4", "advisorModel":"gpt-5.4",
         "gatewayAuthToken":"tok", "gatewayAuthHeader":"x-api-key",
         "subscriptionAuthFilePath":"/dev/null/auth.json",
         "configurationPath":"/dev/null/config.json" }
       """
       let decoded = try JSONDecoder().decode(RouterConfiguration.self, from: Data(legacyJSON.utf8))
       #expect(decoded.pendingToolTurnTTLSeconds == 1800)
       #expect(decoded.advisorContextMessageLimit == 8)
   }

   @Test
   func phase4FieldsRoundTripThroughCodable() throws {
       let original = RouterConfiguration(
           host: "127.0.0.1", port: 4317,
           healthPath: "/health", messagesPath: "/v1/messages",
           countTokensPath: "/v1/messages/count_tokens",
           responsesURL: "https://example/",
           routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
           advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
           pendingToolTurnTTLSeconds: 600,
           advisorContextMessageLimit: 4,
           gatewayAuthToken: "tok", gatewayAuthHeader: "x-api-key",
           subscriptionAuthFilePath: "/dev/null/auth.json",
           configurationPath: "/dev/null/config.json",
           configurationWarning: nil
       )
       let data = try JSONEncoder().encode(original)
       let decoded = try JSONDecoder().decode(RouterConfiguration.self, from: data)
       #expect(decoded.pendingToolTurnTTLSeconds == 600)
       #expect(decoded.advisorContextMessageLimit == 4)
   }

   /// Rotation path (RouterConfigurationStore.regenerateGatewayToken) must preserve Phase 4 fields.
   /// Regression for the silent data-loss failure mode flagged by plan-verifier.
   @Test
   func tokenRegenerationPreservesPhase4Fields() throws {
       let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
       try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
       defer { try? FileManager.default.removeItem(at: tempDir) }
       let configPath = tempDir.appendingPathComponent("config.json")

       let store = RouterConfigurationStore(
           environment: [:],
           fileManager: .default,
           homeDirectoryURL: tempDir
       )

       let initial = RouterConfiguration(
           host: "127.0.0.1", port: 4317,
           healthPath: "/health", messagesPath: "/v1/messages",
           countTokensPath: "/v1/messages/count_tokens",
           responsesURL: "https://example/",
           routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
           advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
           pendingToolTurnTTLSeconds: 600,   // custom non-default value
           advisorContextMessageLimit: 4,    // custom non-default value
           gatewayAuthToken: "initial-tok",
           gatewayAuthHeader: "x-api-key",
           subscriptionAuthFilePath: "/dev/null/auth.json",
           configurationPath: configPath.path,
           configurationWarning: nil
       )
       _ = store.save(configuration: initial)

       let rotated = store.regenerateGatewayToken(from: initial)

       #expect(rotated.pendingToolTurnTTLSeconds == 600)
       #expect(rotated.advisorContextMessageLimit == 4)
       #expect(rotated.gatewayAuthToken != "initial-tok")   // actually rotated
   }
   ```

   Adjust `RouterConfigurationStore(...)` init args in the test to match the real signature in `RouterConfigurationStore.swift:1-20`; the init pattern lives in the existing `RouterConfigurationStoreTests.swift`.

   Add one more test exercising the **full save → disk → load** pipeline. This catches StoredConfiguration Codable synthesis failures that the `phase4FieldsRoundTripThroughCodable` test (RouterConfiguration-level) and `tokenRegenerationPreservesPhase4Fields` test (in-memory) can both miss:

   ```swift
   @Test
   func saveReloadRoundTripPreservesPhase4Fields() throws {
       let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
       try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
       defer { try? FileManager.default.removeItem(at: tempDir) }

       let store1 = RouterConfigurationStore(
           environment: [:],
           fileManager: .default,
           homeDirectoryURL: tempDir
       )

       let initial = RouterConfiguration(
           host: "127.0.0.1", port: 4317,
           healthPath: "/health", messagesPath: "/v1/messages",
           countTokensPath: "/v1/messages/count_tokens",
           responsesURL: "https://example/",
           routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
           advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
           pendingToolTurnTTLSeconds: 600,
           advisorContextMessageLimit: 4,
           gatewayAuthToken: "tok",
           gatewayAuthHeader: "x-api-key",
           subscriptionAuthFilePath: "/dev/null/auth.json",
           configurationPath: "ignored-will-be-replaced",
           configurationWarning: nil
       )
       _ = store1.save(configuration: initial)
       // Disk now has config.json under tempDir.

       // Fresh store instance reads from disk (simulates daemon restart).
       let store2 = RouterConfigurationStore(
           environment: [:],
           fileManager: .default,
           homeDirectoryURL: tempDir
       )
       let reloaded = store2.loadOrCreate()

       #expect(reloaded.pendingToolTurnTTLSeconds == 600)
       #expect(reloaded.advisorContextMessageLimit == 4)
   }
   ```

   Why this test matters: if the `StoredConfiguration` Codable synthesis is broken (e.g., by reintroducing inline `= nil` defaults per cycle-3 lesson), the in-memory `phase4FieldsRoundTripThroughCodable` test still passes because it goes RouterConfiguration → JSON → RouterConfiguration (uses `RouterConfiguration.swift`'s own manual Codable at `:122-173`). Only the `save → persist → loadOrCreate` path exercises `StoredConfiguration.Codable`.

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter RouterConfigurationMigrationTests`
Expected: all prior + 2 new tests pass.
Run: `grep -n 'pendingToolTurnTTLSeconds\|advisorContextMessageLimit' Sources/CCRouterCore/RouterConfiguration.swift`
Expected: ≥ 4 lines each (field decl, init param, CodingKey case, decoder assignment, encoder call).
<!-- /section -->

---

<!-- section: task-4 keywords: PendingToolTurn, ttl, eviction, lastAccessedAt, evictStale -->
### Task 4: Add TTL + lazy eviction to `pendingToolTurns`

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:27` (storage type), `:836-842` (PendingToolTurn struct), `:168, :244, :338, :512, :541, :643, :652` (map access sites)
- Test: `Tests/CCRouterCoreTests/PendingToolTurnEvictionTests.swift`

**Steps:**

1. Add `lastAccessedAt: Date` to the `PendingToolTurn` struct (`AnthropicBridge.swift:836`):

   ```swift
   private struct PendingToolTurn: Sendable {
       let anthropicModel: String
       let convertedTools: [JSONObject]
       let replayIR: [IRBlock]
       let advisorEnabled: Bool
       let resolvedRoute: ModelRoute
       var lastAccessedAt: Date   // NEW — bumped on every read or write
   }
   ```

2. Introduce three private helpers in `AnthropicBridge` that encapsulate all map access (so every path bumps the timestamp and sweeps stale entries):

   ```swift
   private func readPending(sessionID: String) -> PendingToolTurn? {
       evictStalePending()
       guard var entry = pendingToolTurns[sessionID] else { return nil }
       entry.lastAccessedAt = Date()
       pendingToolTurns[sessionID] = entry
       return entry
   }

   private func storePending(_ value: PendingToolTurn, sessionID: String) {
       var v = value
       v.lastAccessedAt = Date()
       pendingToolTurns[sessionID] = v
       evictStalePending()
   }

   private func removePending(sessionID: String) {
       pendingToolTurns.removeValue(forKey: sessionID)
   }

   /// Internal access for tests and forced cleanup. DP-004-P4 Option C.
   internal func evictStalePending(now: Date = Date()) {
       let ttl = TimeInterval(configuration.pendingToolTurnTTLSeconds)
       pendingToolTurns = pendingToolTurns.filter { _, entry in
           now.timeIntervalSince(entry.lastAccessedAt) < ttl
       }
   }

   /// Exposes the count for DoctorSnapshot (used by Task 5).
   public func pendingToolTurnsCount() -> Int {
       evictStalePending()
       return pendingToolTurns.count
   }
   ```

3. Replace every direct map access with the helpers:
   - `:168` `if let pending = pendingToolTurns[sessionID]` → `if let pending = readPending(sessionID: sessionID)`
   - `:244`, `:338`, `:541`, `:652` `pendingToolTurns.removeValue(forKey: sessionID)` → `removePending(sessionID: sessionID)`
   - `:512`, `:643` `pendingToolTurns[sessionID] = PendingToolTurn(...)` → `storePending(PendingToolTurn(...), sessionID: sessionID)`

4. When constructing `PendingToolTurn`, include `lastAccessedAt: Date()` (the helper overrides it anyway, but it makes the initializer honest).

5. Create `Tests/CCRouterCoreTests/PendingToolTurnEvictionTests.swift`:

   ```swift
   import Foundation
   @testable import CCRouterCore
   import Testing

   /// DP-001-P4, DP-004-P4: verify TTL eviction is deterministic and bumped on read.
   ///
   /// These tests exercise eviction via a tiny TTL (1 second) by constructing a
   /// RouterConfiguration with pendingToolTurnTTLSeconds=1 and invoking the public
   /// `evictStalePending` hook (no real-time Task.sleep).
   struct PendingToolTurnEvictionTests {

       private static func config(ttl: Int) -> RouterConfiguration {
           RouterConfiguration(
               host: "127.0.0.1", port: 4317,
               healthPath: "/health", messagesPath: "/v1/messages",
               countTokensPath: "/v1/messages/count_tokens",
               responsesURL: "https://example/",
               routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
               advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
               pendingToolTurnTTLSeconds: ttl,
               advisorContextMessageLimit: 8,
               gatewayAuthToken: "tok", gatewayAuthHeader: "x-api-key",
               subscriptionAuthFilePath: "/dev/null/auth.json",
               configurationPath: "/dev/null/config.json",
               configurationWarning: nil
           )
       }

       @Test
       func countStartsAtZero() async {
           let bridge = AnthropicBridge(configuration: Self.config(ttl: 1800))
           #expect(await bridge.pendingToolTurnsCount() == 0)
       }

       // Tool-use turn storage → count increments — exercised via the public
       // handleMessages path in Task 4's accompanying test updates in
       // ModelRoutingBridgeIntegrationTests.swift (see Task 4 step 6 below).
   }
   ```

6. Extend `ModelRoutingBridgeIntegrationTests.swift` (or add to `PendingToolTurnEvictionTests.swift`) with a test that exercises the time-based branch of `evictStalePending(now:)` — this is the purpose of DP-004-P4 Option C's `now:` parameter. Drive `handleMessages` through a tool-use turn to store an entry, then invoke `evictStalePending(now: Date().addingTimeInterval(1801))` to simulate time passage past the default 30-minute TTL, and assert the entry is gone:

   ```swift
   @Test
   func pendingToolTurnEvictedWhenSimulatedTimeExceedsTTL() async throws {
       let config = Self.config(ttl: 1800)   // default 30-minute TTL

       // Build a tool-use stream that leaves a pending entry after the turn completes.
       // Pattern from ModelRoutingBridgeIntegrationTests.toolUseTurn-style tests.
       let toolCallID = "toolu_evict_1"
       let mockClient = MockResponsesClient(
           streams: [
               MockResponsesEventStream.toolUseTurn(
                   textBefore: nil,
                   toolName: "Bash",
                   callID: toolCallID,
                   argumentsJSON: "{\"command\":\"ls\"}"
               ),
           ],
           performResults: []
       )
       let bridge = AnthropicBridge(configuration: config, responsesClient: mockClient, sessionLoader: MockSessionLoader())

       // Send a request with a Bash tool definition so convertTools recognises it.
       let req = try Self.toolUseRequest(sessionID: "evict-session-1", toolName: "Bash")
       _ = await bridge.handleMessages(req)

       // Entry exists (stored by handleOutputBlocks tool-use branch).
       #expect(await bridge.pendingToolTurnsCount() == 1)

       // Simulate 30 min + 1 s elapsed — past the TTL. Since evictStalePending(now:)
       // ages the filter by `now.timeIntervalSince(entry.lastAccessedAt) < ttl`,
       // feeding a future `now` forces eviction deterministically without real-time sleep.
       await bridge.evictStalePending(now: Date().addingTimeInterval(1801))

       #expect(await bridge.pendingToolTurnsCount() == 0)
   }

   @Test
   func pendingToolTurnSurvivesBeforeTTL() async throws {
       let config = Self.config(ttl: 1800)
       let toolCallID = "toolu_evict_2"
       let mockClient = MockResponsesClient(
           streams: [
               MockResponsesEventStream.toolUseTurn(
                   textBefore: nil,
                   toolName: "Bash",
                   callID: toolCallID,
                   argumentsJSON: "{}"
               ),
           ],
           performResults: []
       )
       let bridge = AnthropicBridge(configuration: config, responsesClient: mockClient, sessionLoader: MockSessionLoader())
       let req = try Self.toolUseRequest(sessionID: "evict-session-2", toolName: "Bash")
       _ = await bridge.handleMessages(req)

       #expect(await bridge.pendingToolTurnsCount() == 1)
       // 29 min elapsed — still inside TTL.
       await bridge.evictStalePending(now: Date().addingTimeInterval(29 * 60))
       #expect(await bridge.pendingToolTurnsCount() == 1)
   }
   ```

   Note: `toolUseRequest` is a new helper in the test suite that builds an `HTTPRequest` body as JSON (pattern from Task 6 `messagesRequest`) containing a single user message + a `{"type":"custom","name":"Bash","description":"...","input_schema":{...}}` tool. Fields mirror `BridgeRegressionTests.bashToolRequest` if it exists; otherwise author a fresh builder following the same JSON-encode shape used elsewhere in the suite.

   **Why explicit `now:` instead of `pendingToolTurnTTLSeconds: 0`:** TTL=0 skips the time-based branch entirely (every entry is stale upon insertion), which means the test never verifies `now.timeIntervalSince(lastAccessedAt) < ttl` actually evaluates correctly. The `now:` override is the hook DP-004-P4 Option C was designed to validate.

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter PendingToolTurnEvictionTests`
Expected: tests pass.
Run: `grep -c 'pendingToolTurns\[sessionID\]' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: 0 (all direct subscript writes replaced by helpers; reads too). Direct reads in diagnostic logging paths are also migrated.
Run: `grep -c 'readPending\|storePending\|removePending' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: ≥ 6 occurrences (3 helpers × ≥ 2 call sites each).
<!-- /section -->

---

<!-- section: task-5 keywords: DoctorSnapshot, pendingToolTurnsCount, GatewayDaemon, snapshot -->
### Task 5: Expose `pendingToolTurnsCount` via `DoctorSnapshot`

**Files:**
- Modify: `Sources/CCRouterCore/DoctorSnapshot.swift` (add field + init param)
- Modify: `Sources/CCRouterCore/GatewayDaemon.swift:38-70, :82-112` (two DoctorSnapshot construction sites)
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift` — `doctorStatus()` returns a tuple or new struct that includes count (the public `pendingToolTurnsCount()` from Task 4 is accessed directly by GatewayDaemon)

**Steps:**

1. Add `pendingToolTurnsCount: Int` to `DoctorSnapshot` struct body (`DoctorSnapshot.swift:27` area) and to the `init(...)` parameter list (append at the end, no default — only 2 call sites in `GatewayDaemon.swift` will need updating, compiler will flag both).

2. Update both DoctorSnapshot construction sites in `GatewayDaemon.swift`:
   - `:38-70` (public `snapshot()`): add `pendingToolTurnsCount: await bridge.pendingToolTurnsCount()`
   - `:82-112` (the GET `/health` route handler): same

3. No new test file needed — existing smoke and doctor-status tests (if any) will assert shape via Codable round-trip. Add one `@Test` to an existing test file (or create `DoctorSnapshotTests.swift` if none exists) that verifies the new field serialises correctly:

   ```swift
   @Test
   func doctorSnapshotIncludesPendingToolTurnsCount() throws {
       let snapshot = DoctorSnapshot(
           host: "127.0.0.1", port: 4317, daemonState: "running", startedAt: nil,
           anthropicMessagesPath: "/v1/messages", countTokensPath: "/v1/messages/count_tokens",
           messagesImplemented: true, countTokensImplemented: true, countTokensStrategy: "body-size-heuristic",
           responsesURL: "https://example/",
           executorModel: "gpt-5.4", advisorModel: "gpt-5.4",
           gatewayAuthHeader: "x-api-key", gatewayAuthTokenSuffix: "xxxxxx",
           configurationPath: "/dev/null/config.json", configurationWarning: nil,
           subscriptionAuthFilePath: "/dev/null/auth.json",
           authState: .ready, chatGPTAuthenticated: true, accountIDSuffix: "abcdef", authError: nil,
           tracePath: "/tmp/trace.jsonl", recentTraceLines: [],
           traceDiagnostics: .empty,
           pendingToolTurnsCount: 3
       )
       let data = try JSONEncoder().encode(snapshot)
       let decoded = try JSONDecoder().decode(DoctorSnapshot.self, from: data)
       #expect(decoded.pendingToolTurnsCount == 3)
   }
   ```

   Place this in a new file `Tests/CCRouterCoreTests/DoctorSnapshotTests.swift` (the minimal scaffolding keeps it isolated).

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild`
Expected: build succeeds (catches any missed construction sites).
Run: `grep -n 'pendingToolTurnsCount' Sources/CCRouterCore/*.swift`
Expected: ≥ 3 matches (DoctorSnapshot decl + init, 2 GatewayDaemon populate sites).
<!-- /section -->

---

<!-- section: task-6 keywords: runAdvisorSubcall, advisor-context, instructions, message-history, truncation -->
### Task 6: Forward instructions + recent history to advisor sub-call

**Files:**
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:721-733` (`runAdvisorSubcall`), `:463-476` (`handleOutputBlocks` signature), `:559-571` (`runAdvisorSubcallAndSecondPass` signature), call sites at `:229-242, :320-333`
- Test: `Tests/CCRouterCoreTests/AdvisorContextForwardingTests.swift`

**Steps:**

1. Change `runAdvisorSubcall` signature to take (instructions, historyMessages, messageLimit, promptCacheKey). Note: this is the **union** of Task 2's `promptCacheKey: String` parameter and Task 6's three new context-forwarding parameters — the final signature lands only once, after both tasks apply their changes. Avoid signature drift by applying Task 2 first (smaller diff), then Task 6 adds the three context params:

   ```swift
   private func runAdvisorSubcall(
       credentials: SubscriptionCredentials,
       instructions: String,
       historyIR: [IRMessage],
       messageLimit: Int,
       promptCacheKey: String
   ) async throws -> String {
       // Truncate to last N messages (DP-003-P4 Option A).
       let truncated = Array(historyIR.suffix(messageLimit))

       // Build advisor input: flatten each message to a single input_text item per message.
       // Only text blocks are carried to advisor — image/tool/thinking blocks are out of scope
       // for strategic guidance and would balloon advisor payload.
       let advisorMessages: [JSONValue] = truncated.compactMap { message -> JSONValue? in
           let texts = message.content.compactMap { block -> String? in
               if case .text(let s) = block { return s }
               return nil
           }
           guard !texts.isEmpty else { return nil }
           let joined = texts.joined(separator: "\n")
           let contentItem = JSONObject([
               "type": .string(message.role == "assistant" ? "output_text" : "input_text"),
               "text": .string(joined),
           ])
           return .object(JSONObject([
               "type": .string("message"),
               "role": .string(message.role),
               "content": .array([.object(contentItem)]),
           ]))
       }

       let advisorSystem = instructions.isEmpty
           ? "You are a planning advisor. Return only a short guidance paragraph with the best next-step strategy."
           : "You are a planning advisor for the following task. Return only a short guidance paragraph with the best next-step strategy.\n\nOriginal system prompt:\n\(instructions)"

       let advisorPayload = makeResponsesPayload(
           route: configuration.advisorRoute,
           instructions: advisorSystem,
           input: advisorMessages,
           tools: [],
           toolChoice: .string("none"),
           promptCacheKey: promptCacheKey
       )
       let events = try await responsesClient.perform(request: advisorPayload, credentials: credentials)
       return joinedMessageText(from: events)
   }
   ```

   Note on output_text vs input_text: the `/responses` API distinguishes assistant replay (`output_text`) from user input (`input_text`). Phase 3 Task 10 already landed this distinction in `IRResponsesCodec` — consistency required here.

2. Thread the three new arguments from `handleOutputBlocks` call sites back up:

   - Add `instructions: String`, `historyIR: [IRMessage]`, `promptCacheKey: String` to `handleOutputBlocks` signature
   - Add same to `runAdvisorSubcallAndSecondPass` signature; pass through to `runAdvisorSubcall` and to the `makeResponsesPayload` call at `:605`
   - **Initial turn** caller (`runInitialTurn`, around `:320`): already has `instructions` + `requestIR` as local params; pass `requestIR` as `historyIR`, and the `cacheKey` computed in Task 2
   - **Continuation** caller (around `:229`): pass `joinedSystemText(from: request.system ?? [])` as `instructions`, `requestIR` as `historyIR`, and the `cacheKey` computed in Task 2

3. Use `configuration.advisorContextMessageLimit` (from Task 3) as the `messageLimit` parameter — threaded via `self.configuration` inside the actor, no need to propagate through call sites.

4. Create `Tests/CCRouterCoreTests/AdvisorContextForwardingTests.swift`. Reuse `MockResponsesClient` from `MockResponsesEventStream.swift:339` (its `capturedRequests: [JSONObject]` stores every payload from both `streamEvents` and `perform`, in call order — so the advisor `/responses` sub-call payload will be element `[1]` after the main turn stream at `[0]`):

   ```swift
   import Foundation
   @testable import CCRouterCore
   import Testing

   /// DP-003-P4: advisor sub-call carries the current task's instructions and
   /// the last N conversation messages, not a fixed "current task..." prompt.
   ///
   /// Pattern mirrors BridgeRegressionTests.advisorBridgeStillSynthesizesServerToolUseAndAdvisorToolResult:
   /// MockResponsesClient.capturedRequests is populated in call order; [0] is the main
   /// streamEvents payload, [1] is the advisor `perform` sub-call payload.
   struct AdvisorContextForwardingTests {

       // MARK: - Shared config + request builder

       private static func config(advisorContextMessageLimit: Int) -> RouterConfiguration {
           RouterConfiguration(
               host: "127.0.0.1", port: 4317,
               healthPath: "/health", messagesPath: "/v1/messages",
               countTokensPath: "/v1/messages/count_tokens",
               responsesURL: "https://chatgpt.com/backend-api/codex/responses",
               routingTable: ModelRoutingTable(rules: [], fallback: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low")),
               advisorRoute: ModelRoute(upstreamModel: "gpt-5.4", reasoningEffort: "xhigh", textVerbosity: "low"),
               pendingToolTurnTTLSeconds: 1800,
               advisorContextMessageLimit: advisorContextMessageLimit,
               gatewayAuthToken: "tok", gatewayAuthHeader: "x-api-key",
               subscriptionAuthFilePath: "/dev/null/auth.json",
               configurationPath: "/dev/null/config.json",
               configurationWarning: nil
           )
       }

       /// Build an HTTPRequest body directly as JSON (AnthropicMessagesRequest's memberwise
       /// init has 11 parameters — raw JSON is simpler and matches AnthropicProtocol.swift:47
       /// `textOnlyFixture` pattern).
       private static func messagesRequest(messageCount: Int, systemText: String) throws -> HTTPRequest {
           var messageObjects: [String] = []
           for i in 0..<messageCount {
               let role = (i % 2 == 0) ? "user" : "assistant"
               messageObjects.append("""
               {"role":"\(role)","content":[{"type":"text","text":"msg-\(i)"}]}
               """)
           }
           let json = """
           {
             "model": "claude-sonnet-4-6",
             "max_tokens": 512,
             "stream": true,
             "system": [{"type":"text","text":\(Self.jsonEscape(systemText))}],
             "tools": [{"type":"advisor_20260301"}],
             "messages": [\(messageObjects.joined(separator: ","))]
           }
           """
           return HTTPRequest(
               method: "POST", path: "/v1/messages",
               headers: ["x-claude-code-session-id": "test-session"],
               body: Data(json.utf8)
           )
       }

       private static func jsonEscape(_ s: String) -> String {
           let data = try! JSONEncoder().encode(s)
           return String(data: data, encoding: .utf8) ?? "\"\""
       }

       /// The advisor `perform` sub-call needs a response with a message containing text,
       /// so `joinedMessageText(from:)` returns a non-empty guidance string.
       private static func advisorPerformResult() -> [JSONObject] {
           let messageItem = JSONObject.from([
               "type": .string("message"),
               "role": .string("assistant"),
               "content": .array([.object(JSONObject.from([
                   "type": .string("output_text"),
                   "text": .string("advisor guidance"),
               ]))]),
           ])
           return [
               JSONObject.from([
                   "type": .string("response.output_item.done"),
                   "item": .object(messageItem),
               ]),
               JSONObject.from([
                   "type": .string("response.completed"),
                   "response": .object(JSONObject.from([
                       "usage": .object(JSONObject.from([
                           "input_tokens": .number(5),
                           "output_tokens": .number(3),
                       ])),
                   ])),
               ]),
           ]
       }

       // MARK: - Tests

       @Test
       func advisorPayloadIncludesInstructionsAndLastNMessages() async throws {
           let advisorCallID = "toolu_advisor_ctx_1"
           // Pattern from BridgeRegressionTests.advisorBridge... (line 256-264):
           // first stream = toolUseTurn with toolName="advisor" (main turn calls advisor function),
           // second stream = textOnlyTurn (second-pass reply after advisor result injected).
           let mockClient = MockResponsesClient(
               streams: [
                   MockResponsesEventStream.toolUseTurn(
                       textBefore: "Let me consult advisor.",
                       toolName: "advisor",
                       callID: advisorCallID,
                       argumentsJSON: "{}"
                   ),
                   MockResponsesEventStream.textOnlyTurn(text: "Final reply"),
               ],
               performResults: [Self.advisorPerformResult()]
           )
           let bridge = AnthropicBridge(
               configuration: Self.config(advisorContextMessageLimit: 8),
               responsesClient: mockClient,
               sessionLoader: MockSessionLoader()
           )
           let req = try Self.messagesRequest(messageCount: 10, systemText: "Original system prompt body.")

           _ = await bridge.handleMessages(req)

           let captured = await mockClient.capturedRequests
           // [0] main stream, [1] advisor perform, [2] second-pass stream
           #expect(captured.count >= 2)
           let advisorPayload = captured[1]

           // Input is the truncated last-N conversation messages.
           let inputMessages = advisorPayload.array("input") ?? []
           #expect(inputMessages.count == 8)

           // Instructions carry the original system prompt verbatim.
           let advisorInstr = advisorPayload.string("instructions") ?? ""
           #expect(advisorInstr.contains("Original system prompt body."))
           #expect(advisorInstr.contains("planning advisor"))
       }

       @Test
       func advisorMessageLimitHonoursConfig() async throws {
           let advisorCallID = "toolu_advisor_ctx_2"
           let mockClient = MockResponsesClient(
               streams: [
                   MockResponsesEventStream.toolUseTurn(
                       textBefore: "Consulting.",
                       toolName: "advisor",
                       callID: advisorCallID,
                       argumentsJSON: "{}"
                   ),
                   MockResponsesEventStream.textOnlyTurn(text: "Final"),
               ],
               performResults: [Self.advisorPerformResult()]
           )
           let bridge = AnthropicBridge(
               configuration: Self.config(advisorContextMessageLimit: 4),
               responsesClient: mockClient,
               sessionLoader: MockSessionLoader()
           )
           let req = try Self.messagesRequest(messageCount: 10, systemText: "sys")

           _ = await bridge.handleMessages(req)

           let captured = await mockClient.capturedRequests
           let inputMessages = captured[1].array("input") ?? []
           #expect(inputMessages.count == 4)
       }

       @Test
       func advisorReplacesFixedGuidancePrompt() async throws {
           let advisorCallID = "toolu_advisor_ctx_3"
           let mockClient = MockResponsesClient(
               streams: [
                   MockResponsesEventStream.toolUseTurn(
                       textBefore: nil,
                       toolName: "advisor",
                       callID: advisorCallID,
                       argumentsJSON: "{}"
                   ),
                   MockResponsesEventStream.textOnlyTurn(text: "ok"),
               ],
               performResults: [Self.advisorPerformResult()]
           )
           let bridge = AnthropicBridge(
               configuration: Self.config(advisorContextMessageLimit: 8),
               responsesClient: mockClient,
               sessionLoader: MockSessionLoader()
           )
           let req = try Self.messagesRequest(messageCount: 2, systemText: "sys")

           _ = await bridge.handleMessages(req)

           let captured = await mockClient.capturedRequests
           let advisorPayload = captured[1]

           // The old fixed string MUST NOT appear as advisor input — it was replaced by real history.
           let inputAsString = advisorPayload.array("input")?
               .compactMap { $0.objectValue }
               .flatMap { ($0.array("content") ?? []).compactMap { $0.objectValue?.string("text") } }
               .joined(separator: " ") ?? ""
           #expect(!inputAsString.contains("Provide concise strategic guidance for the current task"))
       }
   }
   ```

   Note: pattern verified against `BridgeRegressionTests.swift:254-264`. `MockResponsesClient.capturedRequests` at `MockResponsesEventStream.swift:331` records both `streamEvents` and `perform` in call order — index [0] is the main stream payload, index [1] is the advisor `perform` sub-call payload. `AnthropicMessagesRequest` / `AnthropicMessage` field layout lives in `Sources/CCRouterCore/AnthropicProtocol.swift`; verify the exact initializer signature during execution and adjust test builders if needed.

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter AdvisorContextForwardingTests`
Expected: 3 tests pass.
Run: `grep -n 'Provide concise strategic guidance for the current task.' Sources/CCRouterCore/AnthropicBridge.swift`
Expected: 0 matches (fixed prompt replaced).
<!-- /section -->

---

<!-- section: task-7 keywords: probe, prompt_cache_hit_tokens, upstream-usage, research -->
### Task 7: Probe — does `/responses` expose `prompt_cache_hit_tokens`?

**Files:**
- Create: `scripts/probe_prompt_cache_hit.py` (modeled on `scripts/probe_responses_advisor_bridge.py`)
- Create: `docs/research/2026-04-23-prompt-cache-hit-metrics-probe.md`

**⚠️ No test: pure research script + written report; execution happens manually against the user's live ChatGPT subscription and updates the report, no automated assertions in CI.**

**Steps:**

1. Copy `scripts/probe_responses_advisor_bridge.py` to `scripts/probe_prompt_cache_hit.py` and adapt:
   - Same auth path (reads `~/.codex/auth.json` for `access_token` + `account_id`)
   - Same zstd handling, same SSE parsing (reuse `_probe_common.py`)
   - Send three consecutive `/responses` requests with **identical** `prompt_cache_key`, `instructions`, `input[0]` content (triggers cache hit on request 2 and 3)
   - For each request, parse the final `response.completed` event and print:
     - `response.usage.input_tokens`
     - `response.usage.output_tokens`
     - `response.usage.total_tokens`
     - The entire `response.usage` object (pretty-printed) to surface any cache-specific subfields

2. Run the probe (user executes after reviewing the script):
   ```bash
   python3 scripts/probe_prompt_cache_hit.py > /tmp/cache-hit-probe.jsonl
   ```

3. Write `docs/research/2026-04-23-prompt-cache-hit-metrics-probe.md` with:
   - Probe setup (3 identical requests, same cache key)
   - Raw `response.usage` JSON for each of the 3 responses
   - Conclusion: whether `/responses` surfaces any cache-hit indicator (e.g., `prompt_cache_hit_tokens`, `input_tokens_details.cached_tokens`, or similar)
   - If yes: which field(s), at what granularity, and note "Phase 6 Dashboard cache-hit metric is implementable — field X, definition Y"
   - If no: note "Phase 6 Dashboard cache-hit metric is deferred; alternative surrogate = turn latency delta across same-session requests" (dev-guide § Phase 6 Dashboard cache-hit rate is NOT a Phase 4 acceptance criterion, so a negative result does not block Phase 4)

4. Scheme3 evidence baseline: `docs/scheme3/08-responses-http-contract.md:200-202` currently lists only `input_tokens` / `output_tokens` / `total_tokens`. If the probe reveals additional subfields, append an amendment note to `docs/scheme3/08-responses-http-contract.md` under a new subsection `### 4.4a Prompt cache hit fields (verified 2026-04-23)`.

**Verify:**
Run: `python3 scripts/probe_prompt_cache_hit.py --dry-run` (script should print "dry-run: 3 requests to https://chatgpt.com/backend-api/codex/responses with cache_key=<hex>").
Expected: script runs and prints the plan without making HTTP calls.
Run: `ls docs/research/2026-04-23-prompt-cache-hit-metrics-probe.md`
Expected: file exists and contains `## Conclusion` section.
<!-- /section -->

---

## Task Dependencies

- Task 1 → Task 2 (Task 2 imports `PromptCacheKey`)
- Task 3 → Task 4, Task 6 (both read `configuration.pendingToolTurnTTLSeconds` / `configuration.advisorContextMessageLimit`)
- Task 4 → Task 5 (Task 5 calls `pendingToolTurnsCount()` introduced in Task 4)
- Task 2 → Task 6 (Task 6 reuses the `cacheKey` computed by Task 2's callers)
- Task 7 is independent and can run in parallel with any other task.

Reasonable execution order: 1 → 3 → 2 → 4 → 5 → 6 → 7.

---

## Out of Scope (for Phase 4)

- Dashboard cache-hit-rate UI rendering — dev-guide § Phase 6, blocked on Task 7 probe outcome
- Routing-table / advisor-route Settings editor — dev-guide § Phase 6
- Token refresh logic — dev-guide § Phase 5
- BPE-accurate count_tokens — dev-guide § Phase 5
- `x-claude-code-session-id` validation beyond length + UTF-8 check (e.g., character-set allowlist) — add only if Task 7 surfaces a security concern

---

## Recommended additions (not in scope)

None. The dev-guide § Phase 4 scope is self-contained and addresses each stated acceptance criterion without needing adjacent work.

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-04-23
- **Cycles:** 4 (cycles 1-3 must-revise → targeted fixes → cycle 4 approved)
- **Reports:**
  - Cycle 1: `.claude/reviews/plan-verifier-2026-04-23-101032.md`
  - Cycle 2: `.claude/reviews/plan-verifier-2026-04-23-102403.md`
  - Cycle 3: `.claude/reviews/plan-verifier-2026-04-23-103208.md`
  - Cycle 4: `.claude/reviews/plan-verifier-2026-04-23-103557.md`
- **Advisory items remaining (non-blocking):**
  - Step 6(f) grep count is off by 2 (cosmetic)
  - Step 6(e) init-arg order phrasing could be clearer (cosmetic)
