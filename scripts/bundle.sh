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
# SPIKE=1 also embeds the legendsd spike: its helper and LaunchAgent (docs/SPIKE.md).
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/DeathRaceKit"
APP="$ROOT/build/Death Race for Code.app"

RELEASE="${RELEASE:-0}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || { echo "Invalid APP_VERSION or BUILD_NUMBER." >&2; exit 1; }
TIMESTAMP=(--timestamp=none)
if [[ "$RELEASE" == 1 ]]; then
  [[ "${SIGN_IDENTITY:-}" == "Developer ID Application:"* && "$CONFIG" == release && "${SPIKE:-0}" == 0 ]] \
    || { echo "Release requires Developer ID Application, CONFIG=release, and no SPIKE helper." >&2; exit 1; }
  TIMESTAMP=(--timestamp)
fi

SPIKE="${SPIKE:-0}"
swift build --package-path "$PKG" -c "$CONFIG" --product DeathRace
# ssh's SSH_ASKPASS: it hands ssh's questions to the app (SSHKit's AskpassBroker).
swift build --package-path "$PKG" -c "$CONFIG" --product deathrace-askpass
# Legends Never Die: the session daemon the app starts, which holds the shells so they
# outlive it. The app finds it beside itself, as it does the askpass helper.
swift build --package-path "$PKG" -c "$CONFIG" --product legendsd
if [ "$SPIKE" = "1" ]; then
  swift build --package-path "$PKG" -c "$CONFIG" --product legendsd-spike
fi
BIN="$(swift build --package-path "$PKG" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DeathRace" "$APP/Contents/MacOS/DeathRace"
cp "$BIN/deathrace-askpass" "$APP/Contents/MacOS/deathrace-askpass"
cp "$BIN/legendsd" "$APP/Contents/MacOS/legendsd"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
python3 - "$APP/Contents/Info.plist" "$APP_VERSION" "$BUILD_NUMBER" <<'PYPLIST'
import plistlib, sys
path, version, build = sys.argv[1:]
with open(path, "rb") as file:
    info = plistlib.load(file)
info["CFBundleShortVersionString"] = version
info["CFBundleVersion"] = build
with open(path, "wb") as file:
    plistlib.dump(info, file)
PYPLIST

# SwiftPM resource bundles: Bundle.module finds them in Contents/Resources.
shopt -s nullglob
for bundle in "$BIN"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob
# The bundled fonts and their licenses (scripts/fetch-fonts.sh pins each download).
"$ROOT/scripts/fetch-fonts.sh"
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$ROOT"/build/fonts/* "$APP/Contents/Resources/Fonts/"

# The shell integration, committed rather than fetched: three small scripts that tell the app
# where each prompt and command begins and ends. Found at runtime by ShellIntegration.directory,
# which looks here first and falls back to App/shell-integration for a run from the repository.
rm -rf "$APP/Contents/Resources/shell-integration"
mkdir -p "$APP/Contents/Resources/shell-integration"
cp -R "$ROOT"/App/shell-integration/. "$APP/Contents/Resources/shell-integration/"

# Icon B, drawn by the app itself (AppIcon.swift) at every size and packed by iconutil.
ICON="$ROOT/build/icon"
rm -rf "$ICON"
mkdir -p "$ICON"
"$BIN/DeathRace" --write-icon "$ICON"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICON/AppIcon.iconset"
if [ "$SPIKE" = "1" ]; then
  cp "$BIN/legendsd-spike" "$APP/Contents/MacOS/legendsd-spike"
  mkdir -p "$APP/Contents/Library/LaunchAgents"
  cp "$ROOT/App/LaunchAgents/local.deathraceforcode.legendsd-spike.plist" "$APP/Contents/Library/LaunchAgents/"
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

# Nested code first: the app's signature seals what is inside it.
codesign --force --options runtime "${TIMESTAMP[@]}" \
  --identifier local.deathraceforcode.deathrace-askpass \
  --sign "$IDENTITY" "$APP/Contents/MacOS/deathrace-askpass"
# Its identifier is what the daemon's own peer check expects of us and what legendsd is
# pinned by in turn, so it is set here rather than left to the binary's name.
codesign --force --options runtime "${TIMESTAMP[@]}" \
  --identifier local.deathraceforcode.legendsd \
  --sign "$IDENTITY" "$APP/Contents/MacOS/legendsd"
if [ -f "$APP/Contents/MacOS/legendsd-spike" ]; then
  codesign --force --options runtime "${TIMESTAMP[@]}" \
    --identifier local.deathraceforcode.legendsd-spike \
    --sign "$IDENTITY" "$APP/Contents/MacOS/legendsd-spike"
fi
codesign --force --options runtime "${TIMESTAMP[@]}" \
  --entitlements "$ROOT/App/DeathRace.entitlements" \
  --sign "$IDENTITY" "$APP"

echo "built $APP"
echo "signed with: $IDENTITY"
