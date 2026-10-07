---
type: dev-guide
status: active
current: true
tags: [siwc, oauth, responses, claude-tools]
refs: [docs/03-decisions/2026-10-08-siwc-model-only.md]
---
# Claudex SIWC refactor

User authorization: “按照你的调研和理解，以及我们的目标，由你来完全重构claudex。”
Baseline: clean dev at e4b29ca768029fef134d67a1e2c23fe1b8a75d16.
Project context contract: docs/00-AI-CONTEXT.md missing; source and CLAUDE.md govern.

## Goal
Preserve Claude Code UI, permissions, tools and agent loop. Use official Sign in with ChatGPT authorized model-only Responses inference. Never import Codex credentials, run a nested Codex agent, or fall back to paid API billing.

## Phases
1. Boundary hardening: explicit loopback listener, public health minimal, protected diagnostics without credential fragments. Offline network and authorization tests.
2. App-owned OAuth: stable host ID; dynamic registration, PKCE/state/nonce, verified ID token/scopes, protected credential store and serialized rotating refresh. Fake HTTP/storage tests. Browser consent and real token exchange require separate user authorization.
3. Responses bridge: official endpoint and bearer contract, full history/instructions on every request, namespace/additional_tools mapping, streaming tool arguments, opaque reasoning replay without Anthropic signatures, explicit unsupported-tool errors. Fixture tests cover parallel IDs, images and errors.
4. Session lifecycle: branch isolation, cancellation, no unsafe retries, route consistency and interrupted stream recovery. Offline end-to-end fixture harness.
5. Settings and migration: remove Codex auth chooser and private endpoint defaults; explicit sign-in/capability states; preserve routing settings. Build and rendered UI verification; no live sign-in or inference.

## Threat model
Untrusted local HTTP clients, OAuth callbacks and upstream event streams cross separate trust boundaries. Bind literal loopback only; authenticated sensitive routes; reject invalid state/nonce/issuer/audience/scopes/signatures before persistence. Treat malformed/unsupported tools as explicit errors. Keep credentials in protected app-owned storage, never logs or health output. Dispose sockets/tasks on stop/error/cancellation; pending login expires; never retry inference after response commitment. Encode URL query and form parameters using structural encoders.

## Acceptance
- Offline tests and build pass; no shipping reference reads Codex auth.
- Claude executes every client tool; gateway never invokes local tools itself.
- Complete user/instruction/tool history survives continuation and branch separation.
- Secret-free diagnostics and strict loopback binding are exercised offline.
- User-approved browser OAuth and real inference remain separately documented validation gates.

## Decisions
None pending for offline work. No publication, pushes, device/simulator operations, credential transmission, or live inference are authorized by this plan.
