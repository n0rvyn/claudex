#!/bin/bash

# Phase 7 e2e smoke: PNG base64 image input via /v1/messages.
# Independent port (4419) and trace path; does not pollute production trace.
# Crystal D-001..D-005: one-liner env vars, subshell daemon, isolated trace + port.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DAEMON_BIN="$ROOT_DIR/.build/debug/modelbridge-daemon"
HOST="${CC_ROUTER_HOST:-127.0.0.1}"
PORT="${CC_ROUTER_PORT:-4419}"
HEALTH_URL="http://$HOST:$PORT/health"
GATEWAY_TOKEN="${CC_ROUTER_GATEWAY_TOKEN:-modelbridge-smoke-token}"

SMOKE_OUTDIR="${SMOKE_OUTDIR:-$(mktemp -d -t modelbridge-multimodal.XXXXXX)}"
TRACE_PATH="$SMOKE_OUTDIR/trace.jsonl"
CONFIG_PATH="$SMOKE_OUTDIR/config.json"

echo "multimodal smoke outdir: $SMOKE_OUTDIR"

swift build --disable-sandbox --product modelbridge-daemon

if curl -sS "$HEALTH_URL" >/dev/null 2>&1; then
  echo "Multimodal smoke port $PORT is already in use; set CC_ROUTER_PORT to a free port and rerun."
  exit 1
fi

# Minimal config (no special routing needed for image test)
cat > "$CONFIG_PATH" << 'CONFIG_EOF'
{
  "routingTable": {
    "rules": [],
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
  echo "Health check never succeeded for multimodal smoke"
  cat "$SMOKE_OUTDIR/daemon.log"
  exit 1
fi

# PNG base64 from scripts/probe_image_wire.py:34-36
PNG_BASE64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

PAYLOAD=$(jq -n --arg b64 "$PNG_BASE64" '{
    model: "claude-opus-4-7",
    max_tokens: 1024,
    messages: [
        {
            role: "user",
            content: [
                {
                    type: "image",
                    source: { type: "base64", media_type: "image/png", data: $b64 }
                },
                { type: "text", text: "Describe this image in one word." }
            ]
        }
    ]
}')

RESPONSE_FILE="$SMOKE_OUTDIR/response.txt"
HTTP_CODE=$(curl -sS -w "%{http_code}" -X POST "http://$HOST:$PORT/v1/messages" \
  -H "Authorization: Bearer $GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d "$PAYLOAD" \
  -o "$RESPONSE_FILE")

echo "Multimodal HTTP response code: $HTTP_CODE"

# Assertions

# (a) Response must contain message markers (SSE or JSON type=message)
if ! grep -qE "message_stop|\"type\":\"message\"" "$RESPONSE_FILE" 2>/dev/null; then
  echo "Multimodal smoke: response missing expected Anthropic message markers"
  cat "$RESPONSE_FILE"
  exit 1
fi

# (b) Trace must have structured image input evidence in anthropic_in
if ! jq -e 'select(.stage == "anthropic_in") | select(.has_image == true) | select((.content_block_types // []) | index("image"))' "$TRACE_PATH" >/dev/null 2>&1; then
  echo "Multimodal smoke: anthropic_in trace missing image block reference"
  cat "$TRACE_PATH"
  exit 1
fi

# (c) Upstream /responses call must have completed (content_block_delta present)
if ! jq -e 'select(.stage == "responses_in_event") | select(tostring | contains("response.completed") or contains("message_stop"))' "$TRACE_PATH" >/dev/null 2>&1; then
  echo "Multimodal smoke: upstream response did not complete"
  exit 1
fi

echo "Multimodal smoke passed"
echo "Artifacts: $SMOKE_OUTDIR"
