# Claudex

**Local API Gateway for Claude Code CLI**

---

## Overview

Claudex is a macOS menu bar app that lets Claude Code CLI use your existing ChatGPT Plus subscription as the upstream AI provider. It runs a local Anthropic-compatible gateway, so you can use Claude Code's familiar interface while routing through ChatGPT.

---

## What It Does

Claudex sits in your menu bar and runs a local HTTP server that speaks the Anthropic Messages API. When Claude Code sends a request, Claudex translates it and forwards it to `chatgpt.com/backend-api/codex/responses` using your personal ChatGPT auth — no API key needed.

---

## How It Works

1. **Authorize once** — Point Claudex to your `~/.codex/auth.json` file
2. **Set env vars** — Copy two environment variables into your terminal
3. **Use Claude Code** — Everything works as normal, just routed through Claudex

---

## Features

- **Menu bar app** — Runs silently in the background
- **Real-time routing insights** — See which upstream model handles each request
- **Configurable routing rules** — Route Claude Opus/Sonnet/Haiku to different upstream models
- **Session diagnostics** — Latency, success rate, error reasons at a glance
- **Launch at login** — Claudex can start automatically when you log in
- **Privacy-first** — No data collection, no analytics, no telemetry

---

## Requirements

- macOS 13 or later
- Claude Code CLI installed
- Active ChatGPT Plus subscription

---

## Privacy

Claudex does not collect any user data. All requests are forwarded directly to OpenAI using your personal ChatGPT Plus subscription auth. See our privacy policy for details.

---

## Screenshots

*Screenshots coming soon.*

---

## Support

For support, visit our [GitHub Issues](https://github.com/n0rvyn/Claudex/issues) page.

---

© 2026 Zhijie Zhang
