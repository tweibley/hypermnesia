#!/bin/bash
# Build a release Hypermnesia.app: universal (arm64+x86_64) optimized build, the bundled
# `hypermnesia` CLI, hardened-runtime code signing, optional notarization, and a
# Homebrew-cask-ready zip + sha256. See docs/PACKAGING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Hypermnesia.app"
BUNDLE_ID="app.hypermnesia"
VERSION="$(tr -d '[:space:]' < VERSION)"
DIST="dist"
UNIVERSAL="${UNIVERSAL:-1}"          # 1 = universal binary (ship this); 0 = native arch only (faster, local)

ARCHFLAGS=""
[ "$UNIVERSAL" = "1" ] && ARCHFLAGS="--arch arm64 --arch x86_64"

echo "▸ Building release${ARCHFLAGS:+ (universal)}…"
swift build -c release $ARCHFLAGS --product HypermnesiaApp
swift build -c release $ARCHFLAGS --product hypermnesia
BUILD_DIR="$(swift build -c release $ARCHFLAGS --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/HypermnesiaApp" "$APP/Contents/MacOS/Hypermnesia"
cp "$BUILD_DIR/hypermnesia"    "$APP/Contents/Resources/hypermnesia"   # bundled CLI — the cask symlinks this onto PATH
cp LICENSE THIRD-PARTY-LICENSES.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hypermnesia</string>
  <key>CFBundleDisplayName</key><string>Hypermnesia</string>
  <key>CFBundleExecutable</key><string>Hypermnesia</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Pick the best available signing identity.
find_id() { security find-identity -v -p codesigning | grep -m1 "$1" | grep -oE '[0-9A-F]{40}' || true; }
IDENTITY="$(find_id 'Developer ID Application')"; TYPE="Developer ID (distributable)"
if [ -z "$IDENTITY" ]; then IDENTITY="$(find_id 'Apple Development')"; TYPE="Apple Development (local only)"; fi
if [ -z "$IDENTITY" ]; then IDENTITY="$(find_id 'Mac Developer')"; TYPE="Mac Developer (local only)"; fi
if [ -z "$IDENTITY" ]; then IDENTITY="-"; TYPE="ad-hoc (local only)"; fi

echo "▸ Signing — $TYPE"
# Sign nested Mach-O (the CLI) first, then the outer app bundle. Both need hardened runtime
# (--options runtime) so notarization accepts every executable in the bundle.
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1" 2>/dev/null \
       || codesign --force --options runtime --sign "$IDENTITY" "$1"; }   # retry without timestamp if offline
sign "$APP/Contents/Resources/hypermnesia"
sign "$APP"
codesign --verify --verbose=1 "$APP" && echo "  ✓ signature valid"

# Notarize only with a Developer ID cert and a stored notarytool credential profile.
if [[ "$TYPE" == Developer\ ID* && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ Notarizing via profile '$NOTARY_PROFILE'…"
  ditto -c -k --keepParent "$APP" /tmp/Hypermnesia-notarize.zip
  xcrun notarytool submit /tmp/Hypermnesia-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  echo "  ✓ notarized + stapled — ready to distribute"
else
  echo "  ℹ Skipped notarization (needs a Developer ID Application cert + NOTARY_PROFILE)."
  echo "    An un-notarized zip still installs via cask, but Gatekeeper blocks first launch."
  echo "    See docs/PACKAGING.md to set that up."
fi

# Package the (stapled) app into a versioned, cask-ready zip and print its checksum.
mkdir -p "$DIST"
ZIP="$DIST/Hypermnesia-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
# Version-less alias for the site's stable releases/latest/download URL.
cp "$ZIP" "$DIST/Hypermnesia.zip"

echo "▸ Packaged $ZIP  ($(du -h "$ZIP" | awk '{print $1}'))"
echo ""
echo "  version:  $VERSION"
echo "  sha256:   $SHA"
echo ""
echo "  Publish + wire up the cask:"
echo "    gh release create v$VERSION \"$ZIP\" --title \"v$VERSION\" --notes-file CHANGELOG.md"
echo "    # then set version \"$VERSION\" and sha256 \"$SHA\" in your tap's Casks/hypermnesia.rb"
echo "    # (packaging/homebrew/hypermnesia.rb is the source-of-truth copy)"
