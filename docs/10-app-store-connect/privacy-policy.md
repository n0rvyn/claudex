# Privacy Policy

**Claudex** — Zhijie Zhang

**Effective Date:** 2026-04-25

---

## Overview

Claudex is a local macOS gateway application that routes API requests from the Claude Code CLI to upstream AI providers. It does not collect, store, or transmit personal user data.

---

## What Claudex Does

Claudex runs a local HTTP server on your Mac (default port 4317) and forwards Anthropic-compatible Messages API calls to OpenAI's ChatGPT/Codex endpoint (`chatgpt.com/backend-api/codex/responses`) using your existing ChatGPT Plus subscription.

---

## Data Collection

**Claudex does not collect any user data.**

Specifically:

- **No personal information** — Claudex does not collect names, email addresses, phone numbers, or any other contact information.
- **No usage data** — Claudex does not track, log, or transmit your prompts, responses, or AI interaction content.
- **No device identifiers** — Claudex does not collect advertising identifiers, device IDs, or other tracking tokens.
- **No location data** — Claudex does not access or transmit your location.
- **No health or fitness data** — Claudex does not use HealthKit or any health-related APIs.
- **No financial data** — Claudex does not process payments or access financial information.
- **No photos or media** — Claudex does not access your photo library or any media files.

---

## Data Transmitted

When you use Claudex, the following is transmitted to `chatgpt.com` via your ChatGPT Plus subscription auth:

- **Request body** — Your prompt, system message, and tool definitions (as sent by Claude Code CLI)
- **Auth token** — Your ChatGPT Plus session token from `~/.codex/auth.json`

This data is transmitted directly between your Mac and OpenAI's servers. Claudex acts as a local proxy and does not store, log, or retain any of this data beyond the immediate request/response cycle.

---

## Local Data Storage

Claudex stores the following locally on your Mac:

- **Configuration** — Gateway host, port, and routing rules stored in `~/Library/Application Support/com.90percent.ModelBridge/config.json`
- **Auth bookmark** — A security-scoped bookmark for your `~/.codex/auth.json` file (for app restart persistence)
- **Trace logs** — Optional request/response trace logs written to `~/Library/Application Support/com.90percent.ModelBridge/trace/` (user opt-in, contains no personal data beyond request metadata)

None of this data is transmitted to any external server.

---

## Third-Party Services

Claudex uses the following third-party service:

| Service | Provider | Data Shared |
|---------|----------|-------------|
| ChatGPT/Codex API | OpenAI | Request body and auth token forwarded via your own ChatGPT Plus subscription |

OpenAI's privacy policy applies to data transmitted through the ChatGPT API. See [OpenAI's Privacy Policy](https://openai.com/privacy) for details.

---

## Changes to This Policy

If this privacy policy is updated, the revised version will be posted on this page with an updated effective date.

---

## Contact

For privacy-related questions, contact:

**Zhijie Zhang**
GitHub: [https://github.com/n0rvyn](https://github.com/n0rvyn)
