#!/usr/bin/env bash
# Builds a versioned, Developer ID signed and notarized distribution. No publishing here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "Release signing needs macOS." >&2; exit 1; }
: "${APP_VERSION:?Set APP_VERSION to a numeric version, e.g. 0.2.0}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to a positive integer}"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || { echo "Invalid version or build number." >&2; exit 1; }
[[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] \
  || { echo "Release signing requires Developer ID Application." >&2; exit 1; }

RELEASE=1 CONFIG=release "$ROOT/scripts/bundle.sh"
APP="$ROOT/build/Death Race for Code.app"
ARCHIVE="$ROOT/build/Death-Race-for-Code-$APP_VERSION.zip"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait --output-format json \
  > "$ROOT/build/notarization.json"
python3 - "$ROOT/build/notarization.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
if report.get("status") != "Accepted":
    raise SystemExit("Notarization was not accepted; inspect build/notarization.json and the submission log.")
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# Archive the stapled app, then hash precisely that final distributable.
ditto -c -k --keepParent "$APP" "$ARCHIVE"
(cd "$ROOT/build" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
echo "Release ready: $ARCHIVE"
