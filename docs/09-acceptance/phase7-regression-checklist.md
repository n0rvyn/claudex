# Phase 7 Regression Checklist

**Purpose:** Before closing Phase 7, re-run each of the 22 baseline paths documented in `docs/scheme3/01-validated-baseline.md` §3.13-3.17 and §3.24-3.40 to confirm Phase 1-6 refactoring has not caused regressions.

**Executed by:** User (real device + live Codex subscription)

**Running constraints:**
- All scripts run after `swift build --product modelbridge-daemon`
- Each command must run in a separate shell session or use `env VAR=value cmd` one-liner; do NOT `export` into the parent shell (see `docs/11-crystals/2026-04-24-phase-7-e2e-acceptance-crystal.md` D-001/D-002/D-005)
- After filling Pass/Fail + Evidence, submit PR or notify Claude to update the acceptance report

**Tips on probe scripts:**
- Some probe scripts may not support `--first-turn / --second-turn` flags exactly as listed. Run `python3 scripts/probe_<name>.py --help` first to see available options. Adjust the command to the nearest equivalent flag, then document the actual command used in the Evidence column.
- If a script is missing or fails with a usage error, record `MISSING` in Pass/Fail and note the error in Evidence.

| Section | Verification content | Existing probe | Unit test coverage | Re-run command | Pass/Fail | Evidence |
|---------|---------------------|---------------|-------------------|---------------|-----------|----------|
| §3.13 | Bash tool round-trip upstream accepts | `scripts/probe_converted_tool_roundtrip.py` | `BridgeRegressionTests.swift` | `python3 scripts/probe_converted_tool_roundtrip.py` | ☐ | |
| §3.14 | 8 function family round-trip | `scripts/probe_converted_tool_roundtrip.py` | `BridgeRegressionTests.swift` | `python3 scripts/probe_converted_tool_roundtrip.py --suite functions` | ☐ | |
| §3.15 | Raw `advisor_20260301` upstream 400 | `scripts/probe_anthropic_advisor_server.py` | `AdvisorContextForwardingTests.swift` | `python3 scripts/probe_anthropic_advisor_server.py --raw` | ☐ | |
| §3.16 | Official advisor tool contract | — | `AdvisorContextForwardingTests.swift` | `swift test --filter AdvisorContextForwardingTests` | ☐ | |
| §3.17 | Claude CLI accepts advisor_tool_result | `scripts/probe_anthropic_advisor_server.py` | `AdvisorContextForwardingTests.swift` | `python3 scripts/probe_anthropic_advisor_server.py --server-side` | ☐ | |
| §3.24 | Interactive features.apps=true first-turn HTTP-only | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --interactive --first-turn` | ☐ | |
| §3.25 | First turn survives sidecar 404/500 | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --interactive --first-turn --sidecar-fail` | ☐ | |
| §3.26 | First-turn /responses 400/500 error surface | `scripts/probe_responses_error_modes.py` | `ResponsesClientStreamingTests.swift` | `python3 scripts/probe_responses_error_modes.py --first-turn` | ☐ | |
| §3.27 | Four-sample /responses top-level skeleton parity | `scripts/probe_upstream_models.py` | — | `python3 scripts/probe_upstream_models.py --schema-parity` | ☐ | |
| §3.28 | Non-interactive features.apps=true exec HTTP-only | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --exec` | ☐ | |
| §3.29 | Non-interactive exec survives sidecar 404/500 | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --exec --sidecar-fail` | ☐ | |
| §3.30 | Interactive first-turn malformed/truncated SSE | `scripts/probe_responses_error_modes.py` | `ResponsesClientStreamingTests.swift` | `python3 scripts/probe_responses_error_modes.py --first-turn --malformed` | ☐ | |
| §3.31 | Interactive second-turn text HTTP-only | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --interactive --second-turn` | ☐ | |
| §3.32 | Interactive second-turn survives sidecar 404/500 | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --interactive --second-turn --sidecar-fail` | ☐ | |
| §3.33 | Second-turn 400/500/malformed/truncated | `scripts/probe_responses_error_modes.py` | `ResponsesClientStreamingTests.swift` | `python3 scripts/probe_responses_error_modes.py --second-turn` | ☐ | |
| §3.34 | Default tool-use round-trip error surface | `scripts/probe_anthropic_error_modes.py` | `LocalHTTPServerStreamingErrorTests.swift` | `python3 scripts/probe_anthropic_error_modes.py --roundtrip-errors` | ☐ | |
| §3.35 | Swift gateway completes Claude CLI real path | `scripts/smoke_local_gateway.sh` | `BridgeRegressionTests.swift` + `ModelRoutingBridgeIntegrationTests.swift` | `bash scripts/smoke_local_gateway.sh` | ☐ | |
| §3.36 | Interactive third-turn text HTTP-only | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --interactive --third-turn` | ☐ | |
| §3.37 | GitHub app action forward-only | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --app github` | ☐ | |
| §3.38 | Gmail app action same mode | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --app gmail` | ☐ | |
| §3.39 | Gmail 500 fallback local search | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --app gmail --sidecar-fail` | ☐ | |
| §3.40 | Notion app action same mode | `scripts/probe_backend_api_dependency.py` | — | `python3 scripts/probe_backend_api_dependency.py --app notion` | ☐ | |

### Notes

- Run `python3 scripts/probe_<name>.py --help` before executing any probe script to confirm available flags.
- Smoke scripts require the daemon binary: `swift build --product modelbridge-daemon`
- For probe scripts that take no flags, run without flags and interpret output.
- Pass: exit code 0, expected output present. Fail: non-zero exit, error in output. Record the exit code and a 1-2 line excerpt in the Evidence column.
