#!/usr/bin/env bash
#
# dist.sh — production build of FanDeck.app for `pultik ship`.
#
# tuist generate → xcodebuild Release (FanDeck + helper) → embed the
# genesis-fan-control-helper next to the app binary (HelperInstaller looks
# for it as a sibling of the running executable) → ad-hoc re-sign → zip.
#
# Output: dist/FanDeck.zip
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=.build/DerivedData
DIST=dist
APP="$DERIVED/Build/Products/Release/FanDeck.app"
# Tuist sanitizes the commandLineTool product name to underscores; it gets
# copied into the bundle under the hyphenated name HelperInstaller expects.
HELPER="$DERIVED/Build/Products/Release/genesis_fan_control_helper"

echo "▸ tuist install + generate"
tuist install
tuist generate --no-open

echo "▸ xcodebuild Release: FanDeck"
xcodebuild -workspace GenesisFans.xcworkspace -scheme FanDeck \
    -configuration Release -derivedDataPath "$DERIVED" \
    -quiet build

echo "▸ xcodebuild Release: genesis-fan-control-helper"
xcodebuild -workspace GenesisFans.xcworkspace -scheme genesis-fan-control-helper \
    -configuration Release -derivedDataPath "$DERIVED" \
    -quiet build

[[ -d "$APP" ]] || { echo "× missing $APP" >&2; exit 1; }
[[ -x "$HELPER" ]] || { echo "× missing $HELPER" >&2; exit 1; }

echo "▸ embed helper + re-sign (ad-hoc)"
cp "$HELPER" "$APP/Contents/MacOS/genesis-fan-control-helper"
codesign --force -s - "$APP/Contents/MacOS/genesis-fan-control-helper"
codesign --force -s - "$APP"

echo "▸ package dist/FanDeck.zip"
rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/FanDeck.zip"
echo "✓ $DIST/FanDeck.zip"
