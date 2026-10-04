#!/bin/bash
# Claude Code cloud sessions: install the swift.org toolchain so the portable targets
# (CPTY, PTYKit, VTCore, vthost) build, test and lint on Linux. The container is cached
# after this hook finishes, so the download happens once.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

SWIFT_VERSION="6.3.3"   # matches the Swift in Xcode 26.6, used by macOS CI
SWIFT_BIN="/opt/swift-${SWIFT_VERSION}/usr/bin"
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

SWIFT_VERSION="$SWIFT_VERSION" ./scripts/install-swift-linux.sh

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"${SWIFT_BIN}:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# Warm the build so the first `make test` in the session is quick.
"${SWIFT_BIN}/swift" build --package-path Packages/DeathRaceKit --build-tests > /dev/null
echo "Swift ${SWIFT_VERSION} ready; package built."
