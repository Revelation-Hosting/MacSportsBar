#!/usr/bin/env bash
#
# Regenerate the committed app-icon fallbacks from the Icon Composer source,
# Resources/AppIcon.icon:
#
#   Resources/AppIcon.icns  — used by build-app.sh when Xcode's actool isn't available
#                             (Command Line Tools only, or Xcode older than 26)
#   Resources/AppIcon.png   — the 256 px preview shown in the README
#
# Re-run this after editing the icon in Icon Composer. Requires Xcode 26+, whose actool
# understands .icon documents.
#
# Usage:
#   ./scripts/make-icon.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

ICON_SRC="Resources/AppIcon.icon"
MIN_MACOS="14.0"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Compile the .icon exactly as build-app.sh does, into a throwaway bundle, so AppKit can
# read the flattened renditions (what macOS 14–15 display) back out of its Assets.car.
echo "▸ Compiling ${ICON_SRC}…"
BUNDLE="$WORK/Icon.bundle"
mkdir -p "$BUNDLE/Contents/Resources"
xcrun actool "$ICON_SRC" --compile "$BUNDLE/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
    --output-partial-info-plist "$WORK/partial.plist" >/dev/null
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.revelationhosting.macsportsbar.icon-export</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
</dict>
</plist>
PLIST

echo "▸ Rendering iconset…"
cat > "$WORK/export.swift" <<'SWIFT'
import AppKit

let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let iconset = URL(fileURLWithPath: CommandLine.arguments[2])
guard let icon = bundle.image(forResource: "AppIcon") else {
    fatalError("AppIcon not found in the compiled asset catalog")
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()

        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
SWIFT
swift "$WORK/export.swift" "$BUNDLE" "$WORK/AppIcon.iconset"

iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$WORK/AppIcon.iconset/icon_128x128@2x.png" Resources/AppIcon.png

echo "✓ Wrote Resources/AppIcon.icns and Resources/AppIcon.png"
