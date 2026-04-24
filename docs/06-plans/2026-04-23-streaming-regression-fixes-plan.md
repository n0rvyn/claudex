---
type: plan
status: active
tags: [anthropic-bridge, streaming, tool-contract, http, token-usage]
refs:
  - docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md
  - docs/11-crystals/2026-04-22-phase-3-protocol-completeness-crystal.md
---

# Streaming Regression Fixes Implementation Plan

**Goal:** Eliminate the 3 post-refactor regressions in the Anthropic bridge: pending tool-turn contract loss, duplicate HTTP responses after a committed streaming failure, and incorrect `message_start.usage.input_tokens`.

**Architecture:** Split `AnthropicBridge` into a preflight planning stage and a streaming execution stage. Preflight must validate any pending tool contract before headers are committed, build the exact first-pass upstream payload for this round, and compute the `message_start` usage value up front from a defined prompt-bearing surface. `LocalHTTPServer` must adopt stricter "response committed" semantics: once the stream branch begins attempting to send headers, that socket is owned by the stream path only and can never fall back to a second JSON body.

**Tech Stack:** Swift 6 actor concurrency, Foundation, Network, CryptoKit, Swift Testing (`@Test`, `#expect`), vendored `cl100k_base` tokenizer data loaded from SwiftPM resources, pure Swift BPE encoder inside `CCRouterCore`.

**Design doc:** `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md` §§ Phase 1, Phase 2, Phase 5. No scope-specific `*-design.md` exists for these fixes; `rg --files docs/06-plans -g '*design.md' -g '*design-analysis.md'` only returns the unrelated `docs/06-plans/2026-04-21-modelbridge-dashboard-design.md`.

**Design analysis:** none

**Crystal file:** `docs/11-crystals/2026-04-22-phase-3-protocol-completeness-crystal.md`

**Threat model:** included

**Recommended additions (not in scope):** After the shared exact token counter exists, wire it into `GatewayDaemon`'s `POST /v1/messages/count_tokens` path so Anthropic `count_tokens` and streamed `message_start` usage stop diverging. This plan does not change `Sources/CCRouterCore/GatewayDaemon.swift`.

---

## Threat Model

### Attack surface

- Continuation request tool definitions are client-controlled input. Attack class: tool-contract drift between the first tool-use turn and the continuation turn, causing the bridge to replay one contract upstream while the client believes it is using another.
- Upstream stream failures currently cross the HTTP protocol boundary. Attack class: protocol desynchronization after commit, where one socket carries SSE bytes and then a second JSON response.
- Token counting preflight walks user/system text and tool schemas. Attack class: CPU blow-up on very large schemas or long transcripts if the counter duplicates work or retries.

### Failure modes

- Tool-contract validation failure must fail closed before headers are sent. Response shape: one Anthropic-compatible `400 invalid_request_error` JSON body. The existing pending entry remains in memory until a matching continuation arrives or TTL eviction removes it.
- Post-commit streaming failure must finish exactly one response. Response shape: the already-started SSE stream gets the best-effort error marker and chunk terminator, then the socket closes. No second HTTP response is allowed.
- Token counting must not fall back to the placeholder `1`. The counter must be total for every payload shape `makeResponsesPayload` emits; if a block type lacks a special fast path, the counter must canonicalize that item to sorted-key JSON and count that representation instead of throwing.

### Resource lifecycle

- `PendingToolTurn` entries are created on tool-use turns, updated on continuation turns, removed on success or explicit cleanup, and evicted by the existing TTL sweep. Contract-mismatch failures do not overwrite or delete the stored entry.
- Chunked SSE connections are still cleaned by `writer.finish()` on success and best-effort `writer.finish()` on error. `LocalHTTPServer.serve` continues to call `connection.cancel()` after the send path completes.
- The new token counter keeps tokenizer tables in process memory only. No temp files, extra sockets, or child processes are introduced.

## Decisions

### [DP-001] Tokenizer strategy

**Context:** The repo currently has no tokenizer code or data, but Task 3 needs an executable exact-count plan rather than a placeholder.

**Options:**
- A: Add a package dependency for an external tokenizer library.
- B: Vendor the `cl100k_base` merge table into the repo and load it from SwiftPM resources inside a pure Swift encoder.
- C: Keep a deterministic heuristic and rename the task accordingly.

**Chosen:** B. Create `Sources/CCRouterCore/Resources/cl100k_base.tiktoken`, sourced from the `tiktoken` `0.9.0` `cl100k_base` artifact URL `https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken`, and pin its SHA-256 to `223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7`. Update `Package.swift` so `CCRouterCore` processes that resource, and load it through `Bundle.module` inside a pure Swift encoder. This matches the dev-guide's Phase 5 direction without adding a runtime network dependency.

### [DP-002] Meaning of `message_start.usage.input_tokens`

**Context:** `message_start` is emitted once per Anthropic SSE response. Advisor second-pass work happens later in the same stream and cannot be represented retroactively in `message_start`.

**Options:**
- A: Count the public Anthropic request surface only.
- B: Count the bridge's effective first-pass executor prompt surface only.
- C: Try to fold first pass and later advisor second-pass work into one number.

**Chosen:** B. `message_start.usage.input_tokens` counts the first executor `/responses` payload only, using an explicit allowlist of prompt-bearing fields. Advisor second-pass work is not included because the protocol has no place to patch `message_start` after streaming begins.

### [DP-003] Tool fingerprint normalization depth

**Context:** Tool contracts should survive harmless schema reordering without accepting materially changed tools as equivalent.

**Options:**
- A: Hash the raw converted tools as-is.
- B: Deep-normalize objects plus schema arrays whose order is semantically set-like.
- C: Fully canonicalize every array regardless of meaning.

**Chosen:** B. Normalize object keys recursively. For schema arrays under `required`, `enum`, `type` (when array-valued), `allOf`, `anyOf`, and `oneOf`, sort by canonical JSON string before hashing. Preserve order for all other arrays.

### [DP-004] Port strategy for raw-byte streaming tests

**Context:** `LocalHTTPServer` binds to `configuration.port`, and `NWListener(using:on: 0)` is not a usable ephemeral-port path here.

**Options:**
- A: Use a fixed hardcoded test port.
- B: Add a loopback free-port helper backed by a temporary BSD socket, then start the server immediately on that port in a serialized test suite.
- C: Avoid socket-level testing and only unit-test the writer.

**Chosen:** B. Add a small test helper that binds a BSD socket to `127.0.0.1:0`, reads the assigned port with `getsockname`, closes it, and returns that port. The raw-byte suite uses `@Suite(.serialized)` and retries server start once on `EADDRINUSE`.

<!-- section: task-1 keywords: AnthropicBridge, ToolContractFingerprint, PendingToolTurn, preflight -->
### Task 1: Preflight tool-turn planning and contract validation

**Files:**
- Create: `Sources/CCRouterCore/ToolContractFingerprint.swift`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:41-123`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:157-381`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:493-705`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:934-940`
- Test: `Tests/CCRouterCoreTests/ToolContractFingerprintTests.swift`
- Test: `Tests/CCRouterCoreTests/ModelRoutingBridgeIntegrationTests.swift`
- Test: `Tests/CCRouterCoreTests/BridgeRegressionTests.swift`

**Steps:**
1. Create `ToolContractFingerprint.stable(_ tools: [JSONObject]) -> String` as a pure helper. Normalize each converted tool to exactly `name`, `description`, `strict`, and `parameters`; sort the normalized array by `name`; recursively sort object keys; and normalize schema arrays according to DP-003:
   - sort arrays under `required`, `enum`, `type` (array form), `allOf`, `anyOf`, and `oneOf` by canonical JSON string
   - preserve order for every other array
   Encode with `JSONEncoder.outputFormatting = [.sortedKeys]`; hash the bytes with SHA-256. Use this helper only for equality checks. Upstream replay must still use the exact original `convertedTools` array from the first turn.
2. Refactor `AnthropicBridge.handleMessages` into two stages:
   - preflight: decode the Anthropic request, convert tools, inspect `pendingToolTurns`, decide whether the request is initial or continuation, and build a `PreparedTurn`
   - execution: the returned `.stream` closure captures `PreparedTurn` and runs the existing streaming logic against that prepared state
   Validation that must happen before headers are committed moves into preflight.
3. Extend `PendingToolTurn` with `toolContractFingerprint: String`. When a non-advisor tool-use turn stores pending state, persist:
   - `convertedTools: tools` from the current request, not `pending?.convertedTools ?? []`
   - `toolContractFingerprint: ToolContractFingerprint.stable(tools)`
   Apply the same rule to the advisor second-pass tool-use branch so it preserves the original contract instead of storing an empty array.
4. Apply continuation preflight rules:
   - if no pending entry exists, keep current fresh-turn behavior
   - if a pending entry exists but the request contains no `tool_result`, keep the current fresh-turn fallback and leave the pending entry intact
   - if a pending entry exists and the request contains `tool_result`:
     - when `request.tools` is `nil` or `[]`, silently reuse the stored pending contract
     - when `request.tools` is non-empty, convert and fingerprint the new tools; if the fingerprint differs from `pending.toolContractFingerprint`, return `anthropicError(statusCode: 400, errorType: "invalid_request_error", message: "tool contract changed during pending tool turn")`
5. Add regression coverage:
   - `ToolContractFingerprintTests` proves reordered tools hash the same, `required`/`enum` array reordering stays equivalent, non-set-like array order stays significant, and schema/name/description changes hash differently
   - extend `pendingToolTurnSecondSegmentKeepsSameRoute` so it also asserts the second captured `/responses` payload still carries the stored tool definition
   - add a continuation mismatch test that asserts the bridge returns a non-streaming `400` JSON error before any SSE bytes are written
   - add an advisor second-pass regression test ensuring a tool-use produced after the advisor second pass stores the original tool contract

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ToolContractFingerprintTests`
Expected: all fingerprint normalization tests pass.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ModelRoutingBridgeIntegrationTests`
Expected: route-preservation and tool-contract continuation regressions pass.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter BridgeRegressionTests`
Expected: advisor and tool-use bridge regressions pass with no new failures.
<!-- /section -->

<!-- section: task-2 keywords: LocalHTTPServer, committed-stream, chunked, error-path -->
### Task 2: Make committed streaming responses single-response only

**Files:**
- Modify: `Sources/CCRouterCore/LocalHTTPServer.swift:11-23`
- Modify: `Sources/CCRouterCore/LocalHTTPServer.swift:226-243`
- Modify: `Sources/CCRouterCore/LocalHTTPServer.swift:334-415`
- Create: `Tests/CCRouterCoreTests/TestSupport/LoopbackPort.swift`
- Create: `Tests/CCRouterCoreTests/TestSupport/RawLoopbackHTTPClient.swift`
- Test: `Tests/CCRouterCoreTests/LocalHTTPServerStreamingErrorTests.swift`

**Steps:**
1. Introduce an internal error wrapper in `LocalHTTPServer.swift` for post-commit failures, for example:

   ```swift
   private enum ResponseWriteError: Error {
       case committedStreamFailure(underlying: Error)
   }
   ```

   Use this for any error once the `.stream` branch has started attempting to write response headers. This stricter rule avoids double-response corruption even if the underlying send reports failure after partial bytes hit the socket.
2. Update `sendStreamBody` to track commit state explicitly:
   - as soon as the `.stream` branch starts the header send attempt, mark the response as committed for outer error-handling purposes
   - if header write fails, wrap it as `ResponseWriteError.committedStreamFailure`
   - if `producer(writer)` or the success-path `writer.finish()` fails, attempt a best-effort `writer.finish()` once, then throw `ResponseWriteError.committedStreamFailure`
3. Update `serve` to separate pre-commit and post-commit failures:
   - `catch ResponseWriteError.committedStreamFailure`: do not call `send(response:on:)` again; optionally log to stderr/trace, then fall through to `connection.cancel()`
   - generic `catch`: keep the existing single `400 JSON` fallback for parse, decode, and other pre-commit errors
4. Add raw-byte integration tests in `LocalHTTPServerStreamingErrorTests.swift`:
   - annotate the suite with Swift Testing's `@Suite(.serialized)` so the port-reservation tests do not run in parallel
   - add `reserveLoopbackPort()` in `Tests/CCRouterCoreTests/TestSupport/LoopbackPort.swift`; it binds a temporary BSD socket to `127.0.0.1:0`, reads the assigned port via `getsockname`, closes the socket, and returns the port; retry server start once on `EADDRINUSE`
   - add `RawLoopbackHTTPClient.fetch(request:host:port:)` in `Tests/CCRouterCoreTests/TestSupport/RawLoopbackHTTPClient.swift`; it uses a BSD socket `connect` + `send` + `shutdown(SHUT_WR)` path and then loops on `recv` until it returns `0`, appending every chunk into one `Data` buffer
   - start a real `LocalHTTPServer` on that reserved port with a handler whose streaming body comes from `AnthropicBridge` + `MockResponsesEventStream.textThenError(partialText:error:)`
   - send one raw HTTP request over loopback through `RawLoopbackHTTPClient.fetch(...)`, read until `recv == 0`, and assert against that exact byte buffer
   - assert the bytes contain exactly one status line (`HTTP/1.1 200 OK`), the deterministic SSE error marker substring `[upstream error: connection reset]`, and the chunk terminator `0\r\n\r\n`
   - assert the bytes do not contain `HTTP/1.1 400 Bad Request` or an appended `{"error":...}` body
   - add one control test showing a true pre-commit error still returns a single `400` JSON response

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter LocalHTTPServerStreamingErrorTests`
Expected: the post-commit error path proves one response only, and the pre-commit error path still returns one `400` JSON body.
<!-- /section -->

<!-- section: task-3 keywords: input-tokens, AnthropicSSEEncoder, token-counter, message-start -->
### Task 3: Precompute exact `message_start` input tokens

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CCRouterCore/AnthropicInputTokenCounter.swift`
- Create: `Sources/CCRouterCore/Resources/cl100k_base.tiktoken`
- Create: `scripts/generate_cl100k_reference_cases.py`
- Create: `scripts/requirements-cl100k-fixtures.txt`
- Create: `Tests/CCRouterCoreTests/Fixtures/cl100k_reference_cases.json`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:41-123`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:157-381`
- Modify: `Sources/CCRouterCore/AnthropicBridge.swift:861-892`
- Modify: `Sources/CCRouterCore/AnthropicSSEEncoder.swift:33-52`
- Test: `Tests/CCRouterCoreTests/AnthropicInputTokenCounterTests.swift`
- Test: `Tests/CCRouterCoreTests/AnthropicMessageStartUsageTests.swift`
- Test: `Tests/CCRouterCoreTests/CL100KEncoderReferenceTests.swift`
- Test: `Tests/CCRouterCoreTests/ThinkingBlockEmissionTests.swift`

**Design ref:** `docs/06-plans/2026-04-22-modelbridge-refactoring-dev-guide.md` § Phase 5 count-token precision

**Replaces:** hardcoded `startMessage(initialInputTokens: 1)` at `AnthropicBridge.swift:230`, `AnthropicBridge.swift:335`, and `AnthropicSSEEncoder.swift:34`

**Data flow:** Anthropic request + stored pending replay state -> preflight first-pass `/responses` payload -> explicit prompt-bearing field allowlist -> vendored `cl100k_base` encoder -> `message_start.message.usage.input_tokens`

**Quality markers:** the emitted value is computed before streaming starts, there is no placeholder path left, the counted surface is explicitly documented, advisor second-pass work is excluded by design, and `AnthropicSSEEncoder` block open/close semantics remain unchanged per the Phase 3 crystal constraints.

**Steps:**
1. Add a vendored `cl100k_base` tokenizer to `CCRouterCore`:
   - store the merge table at `Sources/CCRouterCore/Resources/cl100k_base.tiktoken`
   - vendor the exact `tiktoken` `0.9.0` artifact from `https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken`
   - record the pinned SHA-256 `223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7` in source comments and in a resource-integrity assertion inside `CL100KEncoderReferenceTests`
   - update `Package.swift` so the `CCRouterCore` target processes that resource
   - add a pure Swift loader/encoder inside `AnthropicInputTokenCounter.swift` that lazily parses the file through `Bundle.module`
   - add `scripts/requirements-cl100k-fixtures.txt` with the single pinned line `tiktoken==0.9.0`
   - add `scripts/generate_cl100k_reference_cases.py` that uses `tiktoken==0.9.0` only as an offline fixture generator, reads the vendored resource file, constructs a reference `Encoding` with the exact `cl100k_base` `pat_str` and special tokens from `tiktoken_ext.openai_public.cl100k_base`, and writes `Tests/CCRouterCoreTests/Fixtures/cl100k_reference_cases.json`
   - generate and commit `Tests/CCRouterCoreTests/Fixtures/cl100k_reference_cases.json` for these exact inputs:
     - `hello`
     - `Run a bash command`
     - `{"additionalProperties":false,"properties":{"command":{"type":"string"}},"required":["command"],"type":"object"}`
     Each fixture row stores `input`, `token_ids`, and `count`
2. Add `AnthropicInputTokenCounting` and a default `AnthropicInputTokenCounter` implementation inside `CCRouterCore`. The counter must walk the already-built first-pass `/responses` payload and count only this allowlist:
   - top-level `instructions`
   - `input[*].content[*].text` when present
   - `input[*].arguments`
   - `input[*].output`
   - reasoning summary text carried inside input items, if present
   - `tools[*].name`
   - `tools[*].description`
   - canonical JSON text of `tools[*].parameters`
   Exclude this denylist explicitly: `model`, `tool_choice`, `parallel_tool_calls`, `reasoning`, `store`, `stream`, `include`, `service_tier`, `prompt_cache_key`, `text`, `client_metadata`, and every other field not named in the allowlist.
3. Inject the counter into `AnthropicBridge` so tests can supply a deterministic stub. Production uses the real counter by default. Extend `PreparedTurn` from Task 1 with `messageStartInputTokens`, computed during preflight from the exact first-pass executor payload that will be sent for:
   - initial turns
   - pending-tool continuations
   - advisor first passes
   Do not compute or report a second-pass advisor value in `message_start`; the protocol cannot surface it after the stream has started.
4. Change `AnthropicSSEEncoder.startMessage` to require a caller-supplied value and remove the implicit default:

   ```swift
   func startMessage(initialInputTokens: Int) async throws
   ```

   Keep the final write boundary defensive with `max(1, initialInputTokens)`, but delete every call site that relied on the hardcoded placeholder.
5. Add targeted tests:
   - `AnthropicMessageStartUsageTests` injects a stub counter and proves the initial turn, pending-tool continuation, and advisor first pass all emit the preflight count in `message_start`, while advisor second-pass work does not try to mutate `message_start`
   - `AnthropicInputTokenCounterTests` verifies determinism and monotonicity: identical payloads count the same, adding prompt-bearing text or tool schema increases the count, denylisted fields do not change the result, and the count never drops below 1
   - `CL100KEncoderReferenceTests` first asserts the bundled resource SHA-256 matches `223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7`, then proves the vendored encoder reproduces the committed fixture file's `token_ids` and `count` values
   - extend one existing streaming/thinking test so changing `startMessage` does not disturb content-block ordering or thinking/signature emission

**Verify:**
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter AnthropicInputTokenCounterTests`
Expected: deterministic and monotonic counter tests pass.
Run: `python3 -m venv /tmp/modelbridge-cl100k-venv && /tmp/modelbridge-cl100k-venv/bin/pip install -r scripts/requirements-cl100k-fixtures.txt && /tmp/modelbridge-cl100k-venv/bin/python scripts/generate_cl100k_reference_cases.py --encoding-file Sources/CCRouterCore/Resources/cl100k_base.tiktoken --out Tests/CCRouterCoreTests/Fixtures/cl100k_reference_cases.json`
Expected: fixture JSON is regenerated deterministically for the 3 pinned inputs using the pinned `tiktoken==0.9.0` environment.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter CL100KEncoderReferenceTests`
Expected: vendored tokenizer resource hash matches the pinned SHA-256, and fixture token IDs/counts match the Swift encoder output.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter AnthropicMessageStartUsageTests`
Expected: initial, continuation, and advisor first-pass streaming turns emit the preflight `input_tokens` value instead of `1`, and advisor second-pass work does not try to rewrite `message_start`.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest --filter ThinkingBlockEmissionTests`
Expected: thinking/signature streaming order remains unchanged after the `startMessage` signature change.
<!-- /section -->

<!-- section: task-4 keywords: verification, swift-build, swift-test, regression -->
### Task 4: Full verification

**Files:**
- Modify: `docs/06-plans/2026-04-23-streaming-regression-fixes-plan.md` (append execution notes if implementation discovers deviations)

**Steps:**
1. Run the targeted suites from Tasks 1-3 first so failures stay local to the changed area.
2. Run the full Swift package build discovered from `Package.swift`.
3. Run the full Swift package test suite discovered from `Package.swift`.
4. Confirm the final test matrix covers all three bug classes:
   - pending continuation reuses the stored tool contract and rejects drift before streaming
   - committed streaming failures never emit a second HTTP response
   - `message_start.usage.input_tokens` is supplied by preflight, not the placeholder `1`

**Verify:**
Run: `swift build --scratch-path /tmp/ModelBridgeSwiftBuild`
Expected: package builds successfully.
Run: `swift test --scratch-path /tmp/ModelBridgeSwiftTest`
Expected: all tests pass with zero failures.
<!-- /section -->

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-04-23
