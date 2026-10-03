#!/usr/bin/env bash
# Builds "Death Race for Code.app" from the SwiftPM package and signs it.
#
# Signing identity, in order:
#   1. $SIGN_IDENTITY, if set ("-" forces ad-hoc);
#   2. the first "Apple Development" identity in your keychain, the one MenuGlance uses;
#   3. ad-hoc, with a warning.
# A stable identity matters: an ad-hoc signature changes with every build, which resets
# Keychain access, privacy permissions and login-item approval each time.
#
# CONFIG=debug|release (default release). Output: build/Death Race for Code.app
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/DeathRaceKit"
APP="$ROOT/build/Death Race for Code.app"

swift build --package-path "$PKG" -c "$CONFIG" --product DeathRace
BIN="$(swift build --package-path "$PKG" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DeathRace" "$APP/Contents/MacOS/DeathRace"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM resource bundles: Bundle.module finds them in Contents/Resources.
shopt -s nullglob
for bundle in "$BIN"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob
if [ -f "$ROOT/App/AppIcon.icns" ]; then
  cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')" || true
fi
if [ -z "$IDENTITY" ]; then
  echo "warning: no Apple Development identity found; signing ad-hoc." >&2
  echo "         Keychain and privacy approvals will not survive rebuilds." >&2
  IDENTITY="-"
fi

codesign --force --options runtime --timestamp=none \
  --entitlements "$ROOT/App/DeathRace.entitlements" \
  --sign "$IDENTITY" "$APP"

echo "built $APP"
echo "signed with: $IDENTITY"
