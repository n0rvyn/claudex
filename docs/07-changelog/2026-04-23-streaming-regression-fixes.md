# 2026-04-23 Streaming Regression Fixes

## Changed

- Fixed pending tool-turn continuation to preserve the original tool contract, reuse it when the continuation omits `tools`, and reject contract drift before streaming starts.
- Fixed committed streaming failures so `LocalHTTPServer` finishes the started stream once and never appends a second JSON error response on the same socket.
- Replaced placeholder `message_start.usage.input_tokens = 1` with a preflight-computed value backed by a vendored `cl100k_base` tokenizer resource and a pure Swift encoder.

## Tests

- Added regression coverage for tool-contract fingerprinting and continuation validation.
- Added raw loopback coverage for committed streaming failures and pre-commit `400` handling.
- Added tokenizer reference fixtures plus `message_start` usage tests for initial turns, continuations, and advisor flows.
- Corrected the streaming latency integration test so it measures first upstream text delta to first Anthropic `content_block_delta`, which matches the documented acceptance rule.
