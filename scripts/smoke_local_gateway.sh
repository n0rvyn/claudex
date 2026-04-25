#!/bin/bash

# Phase 7 acceptance mode: CC_ROUTER_TRACE_PATH isolates trace; do not rely on
# production ~/Library/Application Support/ModelBridge/trace.jsonl. See
# docs/11-crystals/2026-04-24-phase-7-e2e-acceptance-crystal.md D-003.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"

DAEMON_BIN="$ROOT_DIR/.build/debug/claudex-daemon"
HOST="${CC_ROUTER_HOST:-127.0.0.1}"
PORT="${CC_ROUTER_PORT:-4417}"
HEALTH_URL="http://$HOST:$PORT/health"
CONFIG_PATH="${CC_ROUTER_CONFIG_PATH:-/tmp/claudex-smoke-config.json}"
GATEWAY_TOKEN="${CC_ROUTER_GATEWAY_TOKEN:-claudex-smoke-token}"
SMOKE_OUTDIR="${SMOKE_OUTDIR:-$(mktemp -d -t claudex-smoke.XXXXXX)}"
TRACE_PATH="$SMOKE_OUTDIR/trace.jsonl"
HEALTH_FILE="$SMOKE_OUTDIR/health.json"
DAEMON_LOG="$SMOKE_OUTDIR/daemon.log"
RESULT_FILE="$SMOKE_OUTDIR/result.txt"

echo "smoke outdir: $SMOKE_OUTDIR"

swift build --disable-sandbox --product claudex-daemon

if curl -sS "$HEALTH_URL" > "$HEALTH_FILE" 2>/dev/null; then
  echo "Smoke port $PORT is already in use; set CC_ROUTER_PORT to a free port and rerun."
  exit 1
fi

env \
  CC_ROUTER_HOST="$HOST" \
  CC_ROUTER_PORT="$PORT" \
  CC_ROUTER_CONFIG_PATH="$CONFIG_PATH" \
  CC_ROUTER_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
  CC_ROUTER_TRACE_PATH="$TRACE_PATH" \
  "$DAEMON_BIN" > "$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

cleanup() {
  kill "$DAEMON_PID" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

for _ in $(seq 1 30); do
  if curl -sS "$HEALTH_URL" > "$HEALTH_FILE" 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! curl -sS "$HEALTH_URL" > "$HEALTH_FILE" 2>/dev/null; then
  echo "Health check never succeeded"
  cat "$DAEMON_LOG"
  exit 1
fi

env \
  ANTHROPIC_BASE_URL="http://$HOST:$PORT" \
  ANTHROPIC_AUTH_TOKEN="$GATEWAY_TOKEN" \
  expect scripts/run_claude_tui_smoke.expect \
    'Return exactly the seven-character token formed by SMOKE followed by OK.' \
    "$RESULT_FILE" \
    "$TRACE_PATH" \
    'SMOKEOK'

if ! rg -q 'SMOKEOK' "$RESULT_FILE"; then
  echo "Smoke command did not return SMOKEOK"
  cat "$RESULT_FILE"
  exit 1
fi

# Phase 7 new: trace field assertions
if [[ ! -f "$TRACE_PATH" ]]; then
  echo "Trace file not created at $TRACE_PATH"
  exit 1
fi

# (a) anthropic_in stage must have claude_model
if ! jq -e 'select(.stage == "anthropic_in") | .claude_model' "$TRACE_PATH" >/dev/null; then
  echo "Trace missing anthropic_in.claude_model"
  cat "$TRACE_PATH"
  exit 1
fi

# upstream_model in responses_out stage
if ! jq -e 'select(.stage == "responses_out_initial" or .stage == "responses_out") | .upstream_model' "$TRACE_PATH" >/dev/null; then
  echo "Trace missing responses_out upstream_model"
  cat "$TRACE_PATH"
  exit 1
fi

# (b) prompt_cache_key must be present
if ! jq -e 'select(.prompt_cache_key != null) | .prompt_cache_key' "$TRACE_PATH" >/dev/null; then
  echo "Trace missing prompt_cache_key"
  exit 1
fi

# (c) real streaming delta exists
if ! jq -e 'select(.stage == "responses_in_event")' "$TRACE_PATH" >/dev/null; then
  echo "Trace missing per-event responses_in_event stage (real streaming not wired)"
  exit 1
fi

echo "Smoke validation passed with trace assertions"
echo "Trace retained at: $TRACE_PATH"
