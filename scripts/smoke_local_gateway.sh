#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/claudex-modulecache}"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULECACHE_PATH"
exec swift test --scratch-path /tmp/ClaudexSIWCOffline --disable-sandbox --filter 'SIWC|GatewayBoundary|LocalHTTPServerStreamingError'
