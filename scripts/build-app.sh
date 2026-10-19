#!/usr/bin/env bash
# Builds HugeDisplay.app (release by default) into ./build and ad-hoc signs it.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/HugeDisplay.app"

cd "$ROOT"
swift build -c "$CONFIG" --product HugeDisplay
BIN="$(swift build -c "$CONFIG" --show-bin-path)/HugeDisplay"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HugeDisplay"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# A stable designated requirement keeps the Screen Recording grant across rebuilds
# as long as the same identity signs it; ad-hoc ("-") is fine for local beta use.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier br.com.techfx.HugeDisplay "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
