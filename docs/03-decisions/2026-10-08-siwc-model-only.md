# Use official SIWC model-only inference

Status: accepted for local refactor, 2026-10-08.

Claude Code owns the UI, permissions and tool loop. Claudex remains an Anthropic Messages compatibility gateway. Official SIWC app-owned OAuth authorizes eligible ChatGPT-plan Responses requests. A nested Codex agent and app-server control loop alter ownership and are excluded. The existing private backend/Codex-auth path is retired, with no automatic credential migration.

Reuse typed content codecs and Anthropic SSE framing, but replace auth, transport, incomplete continuation history, fabricated signatures and permissive unknown-tool dropping. App registration and consent are explicit user actions. Errors identify unsupported capabilities without billing fallback.

Official sources (read 2026-10-08):
- https://developers.openai.com/siwc/token-sharing-open-source
- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions

Preserve the clean baseline commit as the rollback point. Verify protocol and auth with fixtures before any separately approved live sign-in/inference.
