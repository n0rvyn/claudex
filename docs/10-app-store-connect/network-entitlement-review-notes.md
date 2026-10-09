# Network entitlement explanation for App Review

## Review Notes draft

Claudex uses `com.apple.security.network.server` for two local HTTP listeners: the gateway that receives requests from the user’s separately installed Claude Code client, and the temporary OAuth redirect listener used during browser-based Sign in with ChatGPT. The gateway accepts only literal loopback addresses (`127.0.0.1` or `::1`); the OAuth callback binds to `127.0.0.1` on an ephemeral port. These listeners are not exposed on external network interfaces. The gateway authenticates incoming inference requests with its local gateway token. Outgoing network access is used for the authorized OpenAI OAuth, model discovery, and Responses HTTPS requests.

## Entitlement change

On 2026-10-09, `ENABLE_USER_SELECTED_FILES` was changed from `readwrite` to `NO` in both Debug and Release. The current app has no user-selected file import/export UI or security-scoped file access. Its former credential-file bookmark helper has no caller, and the current authentication factory uses `SIWCAuth.shared`. App Sandbox and incoming/outgoing network permissions remain enabled.

## Source evidence

- `Sources/CCRouterCore/LocalHTTPServer.swift:199–216`: literal loopback guard and gateway listener.
- `Sources/CCRouterCore/SIWCSignIn.swift:18–19`: loopback OAuth callback listener.
- `Sources/CCRouterCore/ResponsesClient.swift:17–21`: public Responses HTTPS endpoint.
- `Claudex/ContentView.swift:147–149`: current SIWC authentication factory.
- `Claudex.xcodeproj/project.pbxproj`: Debug/Release file-access setting disabled.

## Submission boundary

This draft has not been entered into App Store Connect. The original complete App Review rejection message was not available locally; a request to justify incoming networking must not be described as proof that the entitlement is unused. No live inference, app restart, account change, provisioning update, or submission is part of this fix.

## Validation evidence — 2026-10-09

- Project plist syntax and `git diff --check` passed.
- Debug build and signed Release archive both succeeded using existing signing; no provisioning updates were allowed.
- Debug signature verification passed with normal macOS trust access. File access is absent; `get-task-allow` remains enabled for debugging.
- Release archive signature verification passed. Both arm64 and x86_64 signed entitlements contain only `app-sandbox`, `network.client`, and `network.server`; user-selected file access and `get-task-allow` are absent.
- The archive was signed with the existing Apple Development identity. It was not exported or validated as an App Store distribution-signed artifact, and was not uploaded. Distribution export/signing remains to be checked before submission. Its existing version/build remains 1.0 (1); this fix does not claim that build number is ready for resubmission.
- Evidence, build logs, and the signed archive are retained in `/Users/norvyn/Documents/Codex/2026-10-08/task/claudex-repair-evidence/entitlement-fix-2026-10-09/`.
- No runtime logic changed; build/signature checks directly validate this entitlement-only change. No new implementation tests or live inference were needed.
