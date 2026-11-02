#!/usr/bin/env bash
# Build TrackerLite and assemble a runnable .app bundle (menu-bar agent).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="TrackerLite"
BUNDLE_ID="com.heyodog0.trackerlite"
VERSION="0.1.0"
APP="dist/$APP_NAME.app"

echo "▶ Building release binary…"
swift build -c release

echo "▶ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# TrackerLite needs no TCC grants (it only writes its own JSON), so a stable
# identity isn't required — but sign with one if it's around, ad-hoc otherwise.
SIGN_ID="TrackerLite Self-Signed"
SIGN_KC="$HOME/Library/Keychains/trackerlite-signing.keychain-db"
# .signing.env (gitignored) holds SIGN_KC_PASS for the dedicated signing keychain.
[ -f "$ROOT/.signing.env" ] && source "$ROOT/.signing.env"
[ -f "$SIGN_KC" ] && [ -n "${SIGN_KC_PASS:-}" ] && \
  security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KC" 2>/dev/null || true
# codesign only finds identities in keychains on the user search list.
if [ -f "$SIGN_KC" ] && ! security list-keychains -d user | grep -q "trackerlite-signing"; then
  eval "security list-keychains -d user -s $(security list-keychains -d user | xargs) \"$SIGN_KC\""
fi

if [ -f "$SIGN_KC" ] && \
   codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" "$APP" 2>/dev/null; then
  echo "▶ Signed with stable identity."
else
  codesign --force --sign - "$APP"
  echo "▶ Signed ad-hoc."
fi

echo "✓ Built $APP"
echo "  Run:  open \"$APP\""
