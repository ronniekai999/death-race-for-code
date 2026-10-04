#!/usr/bin/env python3
"""Writes a starting corpus for VTFuzz: representative output in the fuzzer's input format
(mode byte, columns, rows, then steps; a step is a length byte and that much output, or
0xFF columns rows for a resize, or 0xFE lines for a scroll)."""
import os
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "corpus"
os.makedirs(out, exist_ok=True)

E = "\x1b"
pieces = [
    "hello world\r\n", "wide 中文 text\r\n", "é café\r\n", "\U0001F468‍\U0001F469‍\U0001F467 family",
    "\U0001F1FA\U0001F1F8 flag ❤️", E + "[31mred" + E + "[0m", E + "[1;38;2;10;20;30mtrue" + E + "[m",
    E + "[38:2::1:2:3m" + E + "[4:3mcurly" + E + "[0m", E + "[2J" + E + "[H", E + "[3;5H*" + E + "[K",
    E + "[2;4r" + E + "[4;1H\n\n\n" + E + "[r", E + "[?1049halt" + E + "[?1049l", E + "[5S" + E + "[2T",
    E + "[3@" + E + "[2P" + E + "[L" + E + "[M" + E + "[4X", E + "(0lqqk" + E + "(B", E + "#8",
    E + "]2;title\x07" + E + "]133;A\x07$ ", E + "]52;c;aGVsbG8=\x07", E + "P$qm" + E + "\\",
    E + "[?2026hsync" + E + "[?2026l", E + "[?45h\x08\x08" + E + "[?1045h\x08", "x" + E + "[5b",
    E + "[?7l" + "a" * 50 + E + "[?7h", "\t\tTAB" + E + "[3g\t", E + "c", E + "[1;1;1;3;3*y",
]

def steps(text):
    data = text.encode("utf-8")
    result = b""
    for i in range(0, len(data), 64):
        chunk = data[i:i + 64]
        result += bytes([len(chunk) - 1]) + chunk
    return result

for n, piece in enumerate(pieces):
    with open(os.path.join(out, f"seed-{n:02}"), "wb") as f:
        f.write(bytes([1, 20, 6]) + steps(piece * 3))
with open(os.path.join(out, "seed-resize"), "wb") as f:
    f.write(bytes([1, 30, 8]) + steps("long line that wraps around " * 4) + bytes([0xFF, 9, 5]) + bytes([0xFE, 2])
            + steps("more\r\n" * 10) + bytes([0xFF, 35, 10]))
print(f"wrote {len(pieces) + 1} seeds to {out}")
