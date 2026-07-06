#!/usr/bin/env bash
#
# package.sh — build a signed SiteBlock.app from the SwiftPM products.
#
# SMAppService (the privileged-helper mechanism) requires a *signed .app bundle* with the
# helper binary and its launchd plist embedded — `swift build` alone only emits loose
# executables. This script assembles that bundle and codesigns it with a local Apple
# Development identity so SiteBlock can register its daemon and edit /etc/hosts.
#
# Usage:
#   Scripts/package.sh                 # auto-detect signing identity + team
#   SIGN_ID="Apple Development: ..." TEAM_ID=XXXXXXXXXX Scripts/package.sh
#
# Output: ./build/SiteBlock.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="SiteBlock"
APP_ID="today.siteblock.SiteBlock"
HELPER_ID="today.siteblock.helper"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONFIG="release"

# --- resolve signing identity + team id -----------------------------------------------------
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
fi
if [[ -z "${SIGN_ID:-}" ]]; then
  echo "error: no 'Apple Development' codesigning identity found (need one for SMAppService)." >&2
  echo "       Open Xcode > Settings > Accounts and add your Apple ID to create one." >&2
  exit 1
fi
if [[ -z "${TEAM_ID:-}" ]]; then
  # Team ID is the (XXXXXXXXXX) suffix of the identity's common name.
  TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"$SIGN_ID")"
fi
if [[ -z "${TEAM_ID:-}" ]]; then
  echo "error: could not derive TEAM_ID from '$SIGN_ID'. Set TEAM_ID=XXXXXXXXXX and re-run." >&2
  exit 1
fi
echo "==> signing identity: $SIGN_ID"
echo "==> team id:          $TEAM_ID"

# --- build ----------------------------------------------------------------------------------
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

for f in "$APP_NAME" "SiteBlockHelper"; do
  [[ -f "$BIN/$f" ]] || { echo "error: missing build product $BIN/$f" >&2; exit 1; }
done

# --- assemble bundle ------------------------------------------------------------------------
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Library/LaunchDaemons" \
         "$APP/Contents/Resources"

cp "$BIN/$APP_NAME"       "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN/SiteBlockHelper" "$APP/Contents/MacOS/SiteBlockHelper"

# Bundle.module resources for the statically-linked SiteBlockCore library.
if [[ -d "$BIN/SiteBlock_SiteBlockCore.bundle" ]]; then
  cp -R "$BIN/SiteBlock_SiteBlockCore.bundle" "$APP/Contents/Resources/"
fi

# --- Info.plist -----------------------------------------------------------------------------
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>SiteBlock</string>
    <key>CFBundleIdentifier</key><string>$APP_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>SiteBlock</string>
</dict>
</plist>
PLIST

# --- helper launchd plist (inject real TEAM_ID for the TEAMID placeholder) -------------------
sed "s/TEAMID/$TEAM_ID/g" "$ROOT/Packaging/$HELPER_ID.plist" \
  >"$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist"

# --- codesign: helper first (its own designated requirement), then the whole app ------------
echo "==> codesign helper"
codesign --force --sign "$SIGN_ID" --timestamp=none \
  --identifier "$HELPER_ID" \
  "$APP/Contents/MacOS/SiteBlockHelper"

echo "==> codesign app"
codesign --force --sign "$SIGN_ID" --timestamp=none \
  --identifier "$APP_ID" \
  "$APP"

echo "==> verify"
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "Built: $APP"
echo "Run:   open \"$APP\"   (or drag it to /Applications first)"
