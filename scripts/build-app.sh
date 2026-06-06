#!/usr/bin/env bash
#
# Build a standalone MacSportsBar.app from the SwiftPM executable so it can be launched
# like a normal menu-bar app (no dock icon, no terminal) instead of `swift run`.
#
# Usage:
#   ./scripts/build-app.sh            # build MacSportsBar.app in the repo root
#   ./scripts/build-app.sh --install  # also copy it to /Applications
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacSportsBar"
BUNDLE_ID="com.revelationhosting.macsportsbar"
VERSION="0.1.0"
APP="${APP_NAME}.app"
BIN=".build/release/${APP_NAME}"

echo "▸ Building release binary…"
swift build -c release

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Revelation Hosting. MIT licensed.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the app runs on Apple Silicon (Gatekeeper still warns on first launch
# since it isn't Developer-ID signed — that's expected for a build-from-source app).
echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP" >/dev/null

if [[ "${1:-}" == "--install" ]]; then
    echo "▸ Installing to /Applications…"
    rm -rf "/Applications/${APP}"
    cp -R "$APP" "/Applications/${APP}"
    TARGET="/Applications/${APP}"
else
    TARGET="$(pwd)/${APP}"
fi

cat <<DONE

✓ Built ${TARGET}

Run it now:        open "${TARGET}"
Quit it:           use the menu-bar item's "Quit" action

First launch is blocked because the app isn't signed by an identified developer.
Approve it once via: right-click the app ▸ Open  (or System Settings ▸ Privacy &
Security ▸ Open Anyway). After that it launches normally — including at login if you
add it to System Settings ▸ General ▸ Login Items.
DONE
