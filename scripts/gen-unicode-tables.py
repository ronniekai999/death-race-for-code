#!/usr/bin/env python3
"""Generates Packages/DeathRaceKit/Sources/VTCore/Unicode/UnicodeTables.swift from the
Unicode Character Database.

Usage: scripts/gen-unicode-tables.py [--version 18.0.0] [--cache DIR]

The output records the UCD version and the SHA-256 of every input file, so a review can
confirm exactly what the tables were built from. Width rules (what a terminal cell grid
needs, following the de-facto wcwidth behaviour Ghostty, kitty and foot share):

  width 0: nonspacing and enclosing marks (Mn, Me), format controls (Cf) except U+00AD SOFT
           HYPHEN, Hangul Jamo medial vowels and final consonants (U+1160..U+11FF,
           U+D7B0..U+D7FF), variation selectors, and the zero-width space family.
  width 2: East Asian Width W or F, and anything with Emoji_Presentation=Yes.
  width 1: everything else that is printable.

Grapheme properties emitted for clustering: Extended_Pictographic, Emoji_Modifier,
Regional_Indicator and Grapheme_Extend.

Everything is packed into one property byte per scalar and stored as a two-stage table:
the scalar's high bits pick one of the distinct 256-scalar blocks, the low bits the byte
within it. Looking up any property is two array loads, which is what keeps non-ASCII output
fast. The bytes fit in 6 bits, so both stages are emitted as string literals over a 64-symbol
alphabet (the stage-1 index takes two symbols per block): the Swift compiler handles large
string literals far better than large array literals.
"""

import argparse
import hashlib
import os
import sys
import urllib.request

FILES = {
    "EastAsianWidth.txt": "ucd/EastAsianWidth.txt",
    "DerivedGeneralCategory.txt": "ucd/extracted/DerivedGeneralCategory.txt",
    "emoji-data.txt": "ucd/emoji/emoji-data.txt",
    "DerivedCoreProperties.txt": "ucd/DerivedCoreProperties.txt",
}

OUT = os.path.join(os.path.dirname(__file__), "..", "Packages", "DeathRaceKit", "Sources",
                   "VTCore", "Unicode", "UnicodeTables.swift")


def fetch(version, cache):
    os.makedirs(cache, exist_ok=True)
    texts, digests = {}, {}
    for name, path in FILES.items():
        local = os.path.join(cache, f"{version}-{name}")
        if not os.path.exists(local):
            url = f"https://www.unicode.org/Public/{version}/{path}"
            print(f"downloading {url}", file=sys.stderr)
            with urllib.request.urlopen(url) as response, open(local, "wb") as out:
                out.write(response.read())
        data = open(local, "rb").read()
        digests[name] = hashlib.sha256(data).hexdigest()
        texts[name] = data.decode("utf-8")
    return texts, digests


def parse(text):
    """Yields (start, end, fields) for each data line."""
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        cols = [c.strip() for c in line.split(";")]
        span = cols[0]
        if ".." in span:
            a, b = span.split("..")
            start, end = int(a, 16), int(b, 16)
        else:
            start = end = int(span, 16)
        yield start, end, cols[1:]


def collect(text, predicate):
    out = set()
    for start, end, fields in parse(text):
        if predicate(fields):
            out.update(range(start, end + 1))
    return out


def ranges(points):
    """Merges a set of code points into sorted inclusive ranges."""
    out = []
    for cp in sorted(points):
        if out and cp == out[-1][1] + 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"

# Property byte layout; CharacterWidth reads the same bits.
WIDTH_MASK, PICTOGRAPHIC, MODIFIER, REGIONAL, EXTEND = 0b11, 1 << 2, 1 << 3, 1 << 4, 1 << 5


def two_stage(prop):
    """Splits the property of every scalar into (stage1, stage2): block indexes, and the
    distinct 256-byte blocks laid end to end."""
    blocks, stage1, stage2 = {}, [], []
    for b in range(0x110000 >> 8):
        block = tuple(prop((b << 8) | i) for i in range(256))
        if block not in blocks:
            blocks[block] = len(blocks)
            stage2.extend(block)
        stage1.append(blocks[block])
    return stage1, stage2


def swift_string(name, symbols, doc):
    lines = [f"    /// {doc}", f"    static let {name}: StaticString = \"\"\""]
    for i in range(0, len(symbols), 96):
        lines.append("        " + symbols[i:i + 96] + "\\")
    lines[-1] = lines[-1][:-1]  # no line continuation after the last chunk
    lines.append('        """')
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="18.0.0")
    ap.add_argument("--cache", default=os.path.join(os.path.dirname(__file__), "..", ".build", "ucd"))
    args = ap.parse_args()
    texts, digests = fetch(args.version, args.cache)

    gc = texts["DerivedGeneralCategory.txt"]
    marks = collect(gc, lambda f: f[0] in ("Mn", "Me"))
    formats = collect(gc, lambda f: f[0] == "Cf") - {0x00AD}
    hangul_trailing = set(range(0x1160, 0x1200)) | set(range(0xD7B0, 0xD800))
    zero_width_space = {0x200B}
    zero = marks | formats | hangul_trailing | zero_width_space

    eaw = texts["EastAsianWidth.txt"]
    east_asian_wide = collect(eaw, lambda f: f[0] in ("W", "F"))
    emoji = texts["emoji-data.txt"]
    emoji_presentation = collect(emoji, lambda f: f[0] == "Emoji_Presentation")
    wide = (east_asian_wide | emoji_presentation) - zero

    extended_pictographic = collect(emoji, lambda f: f[0] == "Extended_Pictographic")
    emoji_modifier = collect(emoji, lambda f: f[0] == "Emoji_Modifier")
    grapheme_extend = collect(texts["DerivedCoreProperties.txt"], lambda f: f[0] == "Grapheme_Extend")

    def prop(cp):
        if cp < 0x20 or 0x7F <= cp < 0xA0 or cp in zero:
            value = 0
        elif cp in wide:
            value = 2
        else:
            value = 1
        if cp in extended_pictographic:
            value |= PICTOGRAPHIC
        if cp in emoji_modifier:
            value |= MODIFIER
        if 0x1F1E6 <= cp <= 0x1F1FF:
            value |= REGIONAL
        if cp in grapheme_extend:
            value |= EXTEND
        return value

    stage1, stage2 = two_stage(prop)
    assert max(stage1) < 64 * 64 and max(stage2) < 64
    stage1_symbols = "".join(ALPHABET[i // 64] + ALPHABET[i % 64] for i in stage1)
    stage2_symbols = "".join(ALPHABET[v] for v in stage2)

    header = [
        f"// Generated by scripts/gen-unicode-tables.py from the Unicode Character Database {args.version}.",
        "// Do not edit by hand; rerun the script. Inputs (SHA-256):",
    ]
    header += [f"//   {name}: {digests[name]}" for name in FILES]
    body = [
        "",
        "// swift-format-ignore-file",
        "",
        "enum UnicodeTables {",
        f'    static let version = "{args.version}"',
        "",
        "    /// The 64 symbols the tables below are written in, in value order.",
        f'    static let alphabet: StaticString = "{ALPHABET}"',
        "",
        "    /// Property bits, as `CharacterWidth` reads them.",
        f"    static let widthMask: UInt8 = {WIDTH_MASK}",
        f"    static let pictographic: UInt8 = {PICTOGRAPHIC}",
        f"    static let modifier: UInt8 = {MODIFIER}",
        f"    static let regional: UInt8 = {REGIONAL}",
        f"    static let extend: UInt8 = {EXTEND}",
        "",
        swift_string("blockIndexes", stage1_symbols,
                     f"Stage 1: for each 256-scalar block, its index in `blocks`, two symbols each ({len(stage1)} blocks)."),
        "",
        swift_string("blocks", stage2_symbols,
                     f"Stage 2: {len(stage2) // 256} distinct blocks of 256 property bytes, one symbol each."),
        "}",
        "",
    ]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as out:
        out.write("\n".join(header + body))
    print(f"wrote {os.path.relpath(OUT)}: {len(stage2) // 256} distinct blocks, "
          f"{len(stage1) * 2 + len(stage2)} symbols", file=sys.stderr)


if __name__ == "__main__":
    main()
