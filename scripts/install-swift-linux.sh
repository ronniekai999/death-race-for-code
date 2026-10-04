#!/usr/bin/env bash
# Installs the swift.org toolchain on Ubuntu so the portable targets
# (VTCore, ScreenProtocol, SessionKit, SFTPKit) build, test and fuzz on Linux.
#
# The version tracks the Swift that ships in the Xcode used by macOS CI
# (Xcode 26.6 -> Swift 6.3), so Linux and macOS compile the same language.
# swift.org toolchains also carry the libFuzzer runtime that Xcode's lacks.
#
# Idempotent: exits early when the toolchain is already installed.
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"
PREFIX="${SWIFT_PREFIX:-/opt/swift-${SWIFT_VERSION}}"

if [ -x "${PREFIX}/usr/bin/swift" ]; then
  echo "swift ${SWIFT_VERSION} already installed at ${PREFIX}"
  exit 0
fi

. /etc/os-release
case "${VERSION_ID:-}" in
  24.04) plat="ubuntu2404"; file_plat="ubuntu24.04"; gcc_ver=13 ;;
  22.04) plat="ubuntu2204"; file_plat="ubuntu22.04"; gcc_ver=12 ;;
  *) echo "unsupported distribution: ${PRETTY_NAME:-unknown}" >&2; exit 1 ;;
esac
suffix=""
[ "$(uname -m)" = "aarch64" ] && suffix="-aarch64"

base="https://download.swift.org/swift-${SWIFT_VERSION}-release/${plat}${suffix}/swift-${SWIFT_VERSION}-RELEASE"
tarball="swift-${SWIFT_VERSION}-RELEASE-${file_plat}${suffix}.tar.gz"

# Runtime dependencies listed on swift.org for this distribution.
deps=(binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 "libgcc-${gcc_ver}-dev"
      libncurses-dev libpython3-dev libsqlite3-0 "libstdc++-${gcc_ver}-dev" libxml2-dev
      libz3-dev pkg-config tzdata unzip zlib1g-dev)
missing=()
for p in "${deps[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "installing: ${missing[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
echo "downloading ${tarball}"
curl -fsSL "${base}/${tarball}" -o "${work}/swift.tar.gz"
curl -fsSL "${base}/${tarball}.sig" -o "${work}/swift.tar.gz.sig"

# Verify the PGP signature against swift.org's published keys before unpacking.
export GNUPGHOME="${work}/gnupg"
mkdir -m 700 "${GNUPGHOME}"
curl -fsSL --compressed https://www.swift.org/keys/all-keys.asc | gpg --batch --quiet --import
gpg --batch --verify "${work}/swift.tar.gz.sig" "${work}/swift.tar.gz"

mkdir -p "${PREFIX}"
tar -xzf "${work}/swift.tar.gz" -C "${PREFIX}" --strip-components=1
"${PREFIX}/usr/bin/swift" --version
echo "installed to ${PREFIX}; add ${PREFIX}/usr/bin to PATH"
