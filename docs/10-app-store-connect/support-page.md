# Support

**Claudex** — Zhijie Zhang

---

## Getting Started

### Prerequisites

- macOS 13 or later
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- Active ChatGPT Plus subscription

### Setup

1. Download and launch Claudex
2. Click **Authorize** in the Claudex menu bar popover
3. Select your `~/.codex/auth.json` file from your home directory
4. Copy the environment variables from the Claudex Settings → Claude Code tab
5. Set the environment variables in your terminal where you run Claude Code

### Configuration

In Claudex Settings, you can configure:

- **Gateway host and port** — Default: `127.0.0.1:4317`
- **Upstream URL** — Default: `https://chatgpt.com/backend-api/codex/responses`
- **Routing rules** — Route different Claude models to different upstream models
- **Advisor model** — Model used for multi-step tool planning

---

## Troubleshooting

### "Claudex daemon stopped"

The gateway has stopped. Click the toggle in the menu bar popover to restart it. If it won't start, check that your ChatGPT auth is still valid (click Authorize).

### Claude Code returns errors

1. Verify the gateway is running (green dot in popover)
2. Verify your environment variables are set:
   ```
   echo $ANTHROPIC_BASE_URL
   echo $ANTHROPIC_AUTH_TOKEN
   ```
3. If variables are correct, try restarting the daemon (toggle off/on)
4. Check the Diagnostics tab in Settings for error details

### Auth file errors

If you see "auth file invalid" or "missing access token":
1. Open ChatGPT in your browser and verify you are logged in
2. Check that your `~/.codex/auth.json` file exists and is readable
3. Click **Authorize** again to re-authorize

### High latency

Latency depends on your upstream model and network conditions. Try switching to a faster upstream model in the routing settings.

---

## Known Limitations

- Claudex requires an active ChatGPT Plus subscription
- The gateway must be running before starting Claude Code
- Some Claude Code features may not work with all upstream configurations
- Routing rules are evaluated in order; more specific rules should come first

---

## Release Notes

### Version 1.0 (2026-04-25)
- Initial App Store release
- Local Anthropic-compatible gateway for Claude Code CLI
- Menu bar app with real-time routing insights
- Configurable model routing rules
- Session health diagnostics

---

## Contact

For bugs, feature requests, or questions:

**GitHub Issues:** [https://github.com/n0rvyn/Claudex/issues](https://github.com/n0rvyn/Claudex/issues)

**Email:** Available via GitHub Issues

---

## More Information

- **GitHub Repository:** [https://github.com/n0rvyn/Claudex](https://github.com/n0rvyn/Claudex)
- **Privacy Policy:** Available on the App Store listing page
- **Terms of Use:** Available on the App Store listing page
