#!/bin/bash

# Phase 7 e2e smoke: three-model routing分流验证.
# Independent port (4418) and trace path; does not pollute production trace.
# Crystal D-001..D-005: one-liner env vars, subshell daemon, isolated trace + port.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DAEMON_BIN="$ROOT_DIR/.build/debug/modelbridge-daemon"
HOST="${CC_ROUTER_HOST:-127.0.0.1}"
PORT="${CC_ROUTER_PORT:-4418}"
HEALTH_URL="http://$HOST:$PORT/health"
GATEWAY_TOKEN="${CC_ROUTER_GATEWAY_TOKEN:-modelbridge-smoke-token}"

SMOKE_OUTDIR="${SMOKE_OUTDIR:-$(mktemp -d -t modelbridge-routing.XXXXXX)}"
TRACE_PATH="$SMOKE_OUTDIR/trace.jsonl"
CONFIG_PATH="$SMOKE_OUTDIR/config.json"

echo "routing smoke outdir: $SMOKE_OUTDIR"

swift build --disable-sandbox --product modelbridge-daemon

if curl -sS "$HEALTH_URL" >/dev/null 2>&1; then
  echo "Routing smoke port $PORT is already in use; set CC_ROUTER_PORT to a free port and rerun."
  exit 1
fi

# Generate routing config with haiku/sonnet/opus rules
cat > "$CONFIG_PATH" << 'CONFIG_EOF'
{
  "routingTable": {
    "rules": [
      {"match": "haiku", "route": {"upstreamModel": "gpt-5.3-codex-spark", "reasoningEffort": "xhigh", "textVerbosity": "low"}},
      {"match": "sonnet", "route": {"upstreamModel": "gpt-5.4", "reasoningEffort": "high", "textVerbosity": "low"}},
      {"match": "opus", "route": {"upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"}}
    ],
    "fallback": {"upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"}
  },
  "advisorRoute": {"upstreamModel": "gpt-5.4", "reasoningEffort": "xhigh", "textVerbosity": "low"}
}
CONFIG_EOF

env \
  CC_ROUTER_HOST="$HOST" \
  CC_ROUTER_PORT="$PORT" \
  CC_ROUTER_CONFIG_PATH="$CONFIG_PATH" \
  CC_ROUTER_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
  CC_ROUTER_TRACE_PATH="$TRACE_PATH" \
  "$DAEMON_BIN" > "$SMOKE_OUTDIR/daemon.log" 2>&1 &
DAEMON_PID=$!

cleanup() {
  kill "$DAEMON_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 30); do
  if curl -sS "$HEALTH_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -sS "$HEALTH_URL" >/dev/null 2>&1; then
  echo "Health check never succeeded for routing smoke"
  cat "$SMOKE_OUTDIR/daemon.log"
  exit 1
fi

# Send three requests targeting different routing rules
for MODEL in "claude-haiku-4-5-20251001" "claude-sonnet-4-6" "claude-opus-4-7"; do
  PROMPT="$(echo "$MODEL" | cut -d- -f2 | tr '[:lower:]' '[:upper:]')."
  env \
    ANTHROPIC_BASE_URL="http://$HOST:$PORT" \
    ANTHROPIC_AUTH_TOKEN="$GATEWAY_TOKEN" \
    ANTHROPIC_MODEL="$MODEL" \
    expect scripts/run_claude_tui_smoke.expect \
      "$PROMPT" \
      "$SMOKE_OUTDIR/response-$MODEL.txt" \
      "$TRACE_PATH" \
      "" \
    > "$SMOKE_OUTDIR/expect-$MODEL.log" 2>&1 || true
done

# Assertions

# Each claude model must appear in trace
for MODEL in "claude-haiku-4-5-20251001" "claude-sonnet-4-6" "claude-opus-4-7"; do
  if ! jq -e --arg m "$MODEL" 'select(.claude_model == $m)' "$TRACE_PATH" >/dev/null 2>&1; then
    echo "Missing trace for claude_model=$MODEL"
    exit 1
  fi
done

# upstream_model must have at least 2 distinct values (haiku->spark vs sonnet/opus->gpt-5.4)
UPSTREAM_MODELS=$(jq -r 'select(.upstream_model != null) | .upstream_model' "$TRACE_PATH" 2>/dev/null | sort -u)
UPSTREAM_COUNT=$(echo "$UPSTREAM_MODELS" | wc -l | tr -d ' ')
if [[ "${UPSTREAM_COUNT:-0}" -lt 2 ]]; then
  echo "Expected >=2 distinct upstream_model values, got $UPSTREAM_COUNT: $UPSTREAM_MODELS"
  exit 1
fi

echo "Routing e2e smoke passed. Upstream models hit: $UPSTREAM_MODELS"
echo "Artifacts: $SMOKE_OUTDIR"
