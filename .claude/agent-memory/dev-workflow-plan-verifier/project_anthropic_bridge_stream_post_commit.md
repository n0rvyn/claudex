---
name: AnthropicBridge streaming response commits headers before upstream call
description: Architectural invariant in CCRouterCore that shapes any "retry on upstream error" plan for /v1/messages
type: project
---

`AnthropicBridge.handleMessages` (Sources/CCRouterCore/AnthropicBridge.swift:44) returns `HTTPResponse(statusCode: 200, ..., stream: {...})` as soon as `prepareTurn` succeeds. The upstream `/responses` call via `responsesClient.streamEvents` happens INSIDE the body closure (runPreparedTurn:441), which `LocalHTTPServer.sendStreamBody` invokes AFTER flushing the 200 OK headers (LocalHTTPServer.swift:402-414).

Consequence: `ResponsesHTTPError(statusCode: 401)` from expired access_token is raised post-header-commit. The outer `handleMessages` catch at AnthropicBridge.swift:97 cannot see it, because the status code is already 200 on the wire. Only the in-stream catch at :469-487 sees it, and it writes a text delta "[upstream error: ...]" inside an already-committed 200 response.

**Why:** Bridge was restructured to support chunked SSE streaming; the tradeoff is that retry/error-mapping must happen either (a) before `return HTTPResponse` or (b) via SSE `event: error` frames (non-standard for Anthropic).

**How to apply:** When verifying any plan that adds "catch upstream N → refresh/retry → return error" logic in `handleMessages`, confirm the caught error is raised before the streaming closure executes. For 401 specifically (token expired): the first `streamEvents` must be moved outside the body closure, and `runPreparedTurn` must accept the already-established `AsyncThrowingStream` as input. This pattern also applies to any future "429 rate limit" or "quota exceeded" retry plans.

Secondary streamEvents call sites that share the same post-commit constraint: `AnthropicBridge.swift:791` (advisor second-pass) and `:947` (advisor perform). Plans that only address the first-pass must explicitly scope-exclude these.
