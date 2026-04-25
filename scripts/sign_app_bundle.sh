#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${CLAUDEX_APP_PATH:-$ROOT_DIR/dist/Claudex.app}"
IDENTITY="${CLAUDEX_SIGNING_IDENTITY:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle at: $APP_PATH"
  exit 1
fi

if [[ -z "$IDENTITY" ]]; then
  echo "Missing CLAUDEX_SIGNING_IDENTITY"
  exit 1
fi

codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "$IDENTITY" \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Signed app bundle: $APP_PATH"
