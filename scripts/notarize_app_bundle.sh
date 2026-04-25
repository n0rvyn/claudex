#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${CLAUDEX_APP_PATH:-$ROOT_DIR/dist/Claudex.app}"
ZIP_PATH="${CLAUDEX_ZIP_PATH:-$ROOT_DIR/dist/Claudex.zip}"
NOTARY_PROFILE="${CLAUDEX_NOTARY_PROFILE:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle at: $APP_PATH"
  exit 1
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Missing CLAUDEX_NOTARY_PROFILE"
  exit 1
fi

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
echo "Notarized app bundle: $APP_PATH"
