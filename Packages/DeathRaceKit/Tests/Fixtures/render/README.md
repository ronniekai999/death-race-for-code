# Reviewed render baselines

The six PNGs were rendered from the committed terminal recordings by `RenderGoldenTests`
in [macOS CI run 38085048125](https://github.com/ronniekai999/death-race-for-code/actions/runs/38085048125)
for source commit `849ac9ec861e845adf1cde43b9a773080cdc1c79` on 2026-10-10.

Environment: macOS 26.6.2, Xcode 26.6, Swift 6.3.3, Apple's Paravirtual Metal device;
SF Mono 13 at 2×; 80 columns × 24 rows; Legends Never Die palette; 1312 × 768 pixels.
The verified render artifact SHA-256 was
`f643a44966628b8c21f0c39f7b2f8646f29dafdec733610bb0e3959e79a292a0`.

Each image was visually inspected before committing: htop's headers and selected row,
Vim's syntax and line numbers, tmux's split borders and status, less's final page, and the
vttest foreground/background matrices with glow off and on. Text was upright, grid-aligned,
and unclipped; the glow case retained the color matrix while adding colored halos.

`make test-render` compares all six with the documented pixel tolerance. macOS CI also
requires both parameterized corpus comparisons and the glow comparison to execute.
These reviewed CI baselines do not complete physical-GPU, XDR, energy or manual acceptance;
review and compare them on the target Mac as described in
[Mac acceptance](../../../../../docs/MAC-ACCEPTANCE.md).
