#!/bin/bash
# Build Hypermnesia.app — a real macOS app bundle around the SwiftPM executable.
# Reliable window/menu-bar behavior (unlike `swift run`), and double-clickable.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="$(tr -d '[:space:]' < VERSION)"
echo "Building HypermnesiaApp ($CONFIG)…"
swift build -c "$CONFIG" --product HypermnesiaApp
swift build -c "$CONFIG" --product hypermnesia

BIN=".build/$CONFIG/HypermnesiaApp"
APP="Hypermnesia.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hypermnesia"
# Bundle the CLI like release.sh does — the app installs hooks via this copy when nothing put
# `hypermnesia` on PATH (the direct-download install path).
cp ".build/$CONFIG/hypermnesia" "$APP/Contents/Resources/hypermnesia"
cp LICENSE THIRD-PARTY-LICENSES.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hypermnesia</string>
  <key>CFBundleDisplayName</key><string>Hypermnesia</string>
  <key>CFBundleExecutable</key><string>Hypermnesia</string>
  <key>CFBundleIdentifier</key><string>app.hypermnesia</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy launching a locally-built bundle.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP — launch with:  open $APP"
