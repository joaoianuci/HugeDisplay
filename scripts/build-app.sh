#!/usr/bin/env bash
# Builds HugeDisplay.app (release by default) into ./build and ad-hoc signs it.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/HugeDisplay.app"

cd "$ROOT"
swift build -c "$CONFIG" --product HugeDisplay
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/HugeDisplay"
CORE_BUNDLE="$BIN_DIR/HugeDisplay_HugeDisplayCore.bundle"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HugeDisplay"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Localizations. SwiftUI Text/Button/... look strings up in Bundle.main, so the app target's
# <lang>.lproj folders (Localizable.strings, InfoPlist.strings) go straight into Contents/Resources.
for lproj in "$ROOT"/Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# HugeDisplayCore's strings live in its SwiftPM resource bundle. The generated Bundle.module accessor
# looks for it in Bundle.main.resourceURL (= Contents/Resources) and fatalErrors when it is missing,
# so it must be copied in, and before codesign so that it is part of the signed resources.
if [ ! -d "$CORE_BUNDLE" ]; then
    echo "error: missing SwiftPM resource bundle $CORE_BUNDLE" >&2
    exit 1
fi
cp -R "$CORE_BUNDLE" "$APP/Contents/Resources/"

# Older SwiftPM toolchains (e.g. Swift 6.1 on CI) emit lowercased region folders such as pt-br.lproj,
# which Foundation won't match against the user's "pt-BR". Rename to the canonical names and refuse
# to ship a bundle that is missing a language.
CORE_RES="$APP/Contents/Resources/HugeDisplay_HugeDisplayCore.bundle/Contents/Resources"
[ -d "$CORE_RES" ] || CORE_RES="$APP/Contents/Resources/HugeDisplay_HugeDisplayCore.bundle"
for lang in en es pt-BR; do
    found="$(find "$CORE_RES" -maxdepth 1 -iname "$lang.lproj" | head -1)"
    if [ -z "$found" ]; then
        echo "error: $lang.lproj missing from HugeDisplayCore resources" >&2
        exit 1
    fi
    if [ "$(basename "$found")" != "$lang.lproj" ]; then
        mv "$found" "$CORE_RES/$lang.tmp" && mv "$CORE_RES/$lang.tmp" "$CORE_RES/$lang.lproj"
    fi
done

# A stable designated requirement keeps the Screen Recording grant across rebuilds
# as long as the same identity signs it; ad-hoc ("-") is fine for local beta use.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier io.github.joaoianuci.HugeDisplay "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
