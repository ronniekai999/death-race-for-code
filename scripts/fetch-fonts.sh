#!/usr/bin/env bash
# Fetches the fonts Death Race ships into build/fonts, with their licenses:
#   - Monaspace Neon and Radon 1.400, static OTF: regular, bold, italic, bold italic (OFL 1.1);
#   - Symbols Nerd Font Mono 3.5.1, for the icons in Starship and Powerlevel10k prompts. Its
#     icon sets keep their own licenses (MIT, Apache 2.0, OFL 1.1, CC BY 4.0); Nerd Fonts'
#     license audit lists them and ships alongside.
#
# Every download is pinned by address and SHA-256 and kept in build/fonts-cache, so after the
# first run this works offline, and a changed file stops the build instead of shipping.
# The fonts are fetched rather than committed: the repository stays small, and each comes
# from its project's own release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/fonts-cache"
OUT="$ROOT/build/fonts"

MONASPACE_URL="https://github.com/githubnext/monaspace/releases/download/v1.400/monaspace-static-v1.400.zip"
MONASPACE_SHA256="ab66d71be751495f679727332a3345597943bd4d7beebca03f5cde04bf994de7"
MONASPACE_LICENSE_URL="https://raw.githubusercontent.com/githubnext/monaspace/v1.400/LICENSE"
MONASPACE_LICENSE_SHA256="0e84e5f7dd6f05e74a00f2fb828ca43e489d954f5509ff0fa439ea18c0d35fe9"
NERD_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/NerdFontsSymbolsOnly.zip"
NERD_SHA256="fdca3682534f6f65e1ccb2345b0362ccf67d9b8eca7c8025330946e93e2473bc"
NERD_AUDIT_URL="https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.5.1/license-audit.md"
NERD_AUDIT_SHA256="c2a3f634fa1e5001912f4f19a42fa86fdef5654691b70000f936089325aa404f"

sha256() { shasum -a 256 "$1" | awk '{ print $1 }'; }

# fetch URL SHA256 NAME: the file in the cache, downloaded if missing or changed.
fetch() {
  local url="$1" expected="$2" file="$CACHE/$3"
  if [ ! -f "$file" ] || [ "$(sha256 "$file")" != "$expected" ]; then
    echo "fetching $url" >&2
    curl --fail --silent --show-error --location --retry 3 --output "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local actual
  actual="$(sha256 "$file")"
  if [ "$actual" != "$expected" ]; then
    echo "error: $url has SHA-256 $actual, not the pinned $expected" >&2
    rm -f "$file"
    exit 1
  fi
}

mkdir -p "$CACHE"
fetch "$MONASPACE_URL" "$MONASPACE_SHA256" monaspace-static-v1.400.zip
fetch "$MONASPACE_LICENSE_URL" "$MONASPACE_LICENSE_SHA256" Monaspace-LICENSE.txt
fetch "$NERD_URL" "$NERD_SHA256" NerdFontsSymbolsOnly-v3.5.1.zip
fetch "$NERD_AUDIT_URL" "$NERD_AUDIT_SHA256" NerdFonts-license-audit.md

rm -rf "$OUT"
mkdir -p "$OUT"
for family in Neon Radon; do
  for style in Regular Bold Italic BoldItalic; do
    unzip -q -j -o "$CACHE/monaspace-static-v1.400.zip" \
      "Static Fonts/Monaspace $family/Monaspace$family-$style.otf" -d "$OUT"
  done
done
unzip -q -j -o "$CACHE/NerdFontsSymbolsOnly-v3.5.1.zip" SymbolsNerdFontMono-Regular.ttf -d "$OUT"
unzip -q -p "$CACHE/NerdFontsSymbolsOnly-v3.5.1.zip" LICENSE > "$OUT/SymbolsNerdFont-LICENSE.txt"
cp "$CACHE/Monaspace-LICENSE.txt" "$OUT/Monaspace-LICENSE.txt"
cp "$CACHE/NerdFonts-license-audit.md" "$OUT/SymbolsNerdFont-license-audit.md"

echo "fonts in $OUT:" >&2
ls -1 "$OUT" >&2
