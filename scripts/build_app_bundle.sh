#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA_PATH="${CLAUDEX_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-derived-data}"
APP_ROOT="$ROOT_DIR/dist/Claudex.app"
SOURCE_APP="$DERIVED_DATA_PATH/Build/Products/Release/Claudex.app"

rm -rf "$APP_ROOT"

xcodebuild \
  -project "$ROOT_DIR/Claudex.xcodeproj" \
  -scheme Claudex \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Built app not found at: $SOURCE_APP"
  exit 1
fi

mkdir -p "$ROOT_DIR/dist"
cp -R "$SOURCE_APP" "$APP_ROOT"
codesign --force --deep --sign - "$APP_ROOT"
codesign --verify --deep --strict --verbose=2 "$APP_ROOT"

echo "Created app bundle at: $APP_ROOT"
