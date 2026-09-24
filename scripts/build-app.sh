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
MIN_MACOS="14.0"
APP="${APP_NAME}.app"
BIN=".build/release/${APP_NAME}"
ICON_SRC="Resources/AppIcon.icon"

echo "▸ Building release binary…"
swift build -c release

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Xcode 26+'s actool compiles the Icon Composer document into Assets.car: the layered
# Liquid Glass icon macOS 26 renders in light/dark/tinted/clear, plus flattened renditions
# for macOS 14–15. Without it (Command Line Tools only, or an older Xcode), fall back to the
# pre-rendered AppIcon.icns that scripts/make-icon.sh keeps alongside the source.
echo "▸ Adding app icon…"
xcrun actool "$ICON_SRC" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
    --output-partial-info-plist ".build/AppIcon-partial.plist" >/dev/null 2>&1 || true
if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo "  actool can't compile ${ICON_SRC} here — using the pre-rendered Resources/AppIcon.icns"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
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
