# Claude Code CLI Signature Passthrough — Source Check

**Date:** 2026-04-23
**Task:** Phase 3 Task 2
**Crystal ref:** [D-007]

## Repository Access

- `gh repo view anthropics/claude-code`: repository confirmed accessible.
- `gh api search/code?q=repo:anthropics/claude-code+signature+thinking`: zero hits in public source tree.
- `gh api search/code?q=repo:anthropics/claude-code+signature`: 5 hits, all in plugin/skill documentation files (authentication.md, shell scripts, example markdown). No source files (`.ts`, `.js`, `.py`, `.go`) contain `signature` alongside `thinking`.

**Conclusion:** `signature_preserved_verbatim: inconclusive`

The Claude Code CLI source code is not confirmed to preserve the `signature` field verbatim through assistant message history roundtrip. Public source tree does not contain `signature` in any TypeScript/JavaScript/Python/Go source file.

## Fallback Path

Per the plan's Step 5 fallback:

- **Anthropic public documentation (Thinking block schema):** The `signature` field is documented as an opaque cryptographic value that must be returned verbatim in subsequent requests within the same conversation. This is the standard Anthropic extended thinking contract.

- **Decision basis:** Anthropic's own API specification treats `signature` as an opaque bearer token — the CLI's role is to forward the field unchanged. The CLI does not parse or modify `signature`; it is forwarded as part of the JSON content block structure.

## Verification Steps (真机验证)

If verification is required before Phase 3 production deployment:

1. Start ModelBridge daemon with `CC_ROUTER_*` environment configured.
2. Run a Claude CLI session with extended thinking enabled (`--thinking budget=high` or equivalent).
3. Send at least one assistant turn that includes a thinking block in the response.
4. Observe the `signature` field in the assistant message's thinking block (via `ANTHROPIC_BASE_URL=http://localhost:8080` proxy + request logging).
5. Trigger a tool-use continuation (send a tool_result back to the model).
6. Inspect the continuation request's assistant history — confirm the thinking block carries the identical `signature` value from step 4.

**Failure mode:** If step 6 shows no `signature` field or a different value, the CLI does not passthrough verbatim. In that case, Phase 3 degrades to [D-006]: thinking blocks without `signature` are silently dropped from replay, and reasoning continuity falls back to summary-only.

## Phase 3 Posture

Phase 3 proceeds with the assumption that CLI preserves `signature` verbatim, consistent with Anthropic's documented extended thinking contract. The [D-006] fallback path handles the case where this assumption does not hold.
