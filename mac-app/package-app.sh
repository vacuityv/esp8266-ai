#!/bin/zsh
# Build a release binary and assemble it into AIClockBridge.app.
#
# SwiftPM's Bundle.module looks for the resource bundle at
#   Bundle.main.bundleURL/AIClockBridge_AIClockBridge.bundle
# which for a .app is <App>.app/AIClockBridge_AIClockBridge.bundle (app root),
# so that's where we copy it — otherwise the logo/sprite resources won't load.
set -e
cd "$(dirname "$0")"

APP_NAME="AIClockBridge"
VERSION="0.4.2"
BUNDLE_ID="me.qust.aiclockbridge"
OUT=".build/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/${APP_NAME}"
RESBUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"
[ -x "$BIN" ] || { echo "missing binary: $BIN"; exit 1; }

echo "==> assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$BIN" "$OUT/Contents/MacOS/${APP_NAME}"
# Resource PNGs go into Contents/Resources so the .app is a clean, codesign-able
# bundle (nothing unsealed at the root). AppResources.image loads them via
# Bundle.main; SwiftPM's Bundle.module is only the `swift run` fallback.
[ -d "$RESBUNDLE" ] && cp "$RESBUNDLE"/*.png "$OUT/Contents/Resources/" 2>/dev/null || true

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>AI Clock Bridge</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <!-- This tool talks to the ESP8266 clock and the self-hosted relay over
         plaintext HTTP (the device can't do HTTPS), so App Transport Security
         must allow arbitrary (non-TLS) loads or every request is blocked. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key> <true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> codesign"
# A STABLE signing identity keeps the app's designated requirement constant
# across rebuilds, so macOS Keychain "Always Allow" grants (e.g. for reading the
# Claude Code credential) persist instead of being revoked on every re-sign.
# Create one once with:  ./make-signing-cert.sh   (falls back to ad-hoc if absent).
IDENTITY="AIClock Self Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$OUT" && echo "    signed with stable identity: $IDENTITY"
else
  codesign --force --sign - "$OUT" 2>/dev/null \
    && echo "    ad-hoc signed (run ./make-signing-cert.sh for a stable identity so Keychain grants persist)"
fi

echo "==> done: $OUT"
