#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"

DAEMON_BIN="$ROOT_DIR/.build/debug/modelbridge-daemon"
HOST="${CC_ROUTER_HOST:-127.0.0.1}"
PORT="${CC_ROUTER_PORT:-4417}"
HEALTH_URL="http://$HOST:$PORT/health"
CONFIG_PATH="${CC_ROUTER_CONFIG_PATH:-/tmp/modelbridge-smoke-config.json}"
GATEWAY_TOKEN="${CC_ROUTER_GATEWAY_TOKEN:-modelbridge-smoke-token}"

if [[ ! -x "$DAEMON_BIN" ]]; then
  swift build --disable-sandbox --product modelbridge-daemon
fi

if curl -sS "$HEALTH_URL" >/tmp/modelbridge-smoke-health.json 2>/dev/null; then
  echo "Smoke port $PORT is already in use; set CC_ROUTER_PORT to a free port and rerun."
  exit 1
fi

env \
  CC_ROUTER_HOST="$HOST" \
  CC_ROUTER_PORT="$PORT" \
  CC_ROUTER_CONFIG_PATH="$CONFIG_PATH" \
  CC_ROUTER_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
  "$DAEMON_BIN" >/tmp/modelbridge-smoke-daemon.log 2>&1 &
DAEMON_PID=$!

cleanup() {
  kill "$DAEMON_PID" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

for _ in $(seq 1 30); do
  if curl -sS "$HEALTH_URL" >/tmp/modelbridge-smoke-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! test -f /tmp/modelbridge-smoke-health.json; then
  echo "Health check never succeeded"
  exit 1
fi

env \
  ANTHROPIC_BASE_URL="http://$HOST:$PORT" \
  ANTHROPIC_AUTH_TOKEN="$GATEWAY_TOKEN" \
  claude --bare -p --output-format json 'Reply exactly SMOKEOK.' >/tmp/modelbridge-smoke-result.json

if ! rg -q '"result":"SMOKEOK"' /tmp/modelbridge-smoke-result.json; then
  echo "Smoke command did not return SMOKEOK"
  cat /tmp/modelbridge-smoke-result.json
  exit 1
fi

echo "Smoke validation passed"
