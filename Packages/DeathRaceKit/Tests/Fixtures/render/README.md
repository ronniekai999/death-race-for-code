# Reviewed render baselines

The six PNGs were rendered from the committed terminal recordings by `RenderGoldenTests`
in [macOS CI run 39177508994](https://github.com/ronniekai999/death-race-for-code/actions/runs/39177508994)
for source commit `0fbb32b2b482662a51f14ef1d29dc02e37c4814a` (pull request merge ref
`740561bc952e03a2724b4009ca78128dc6d5872d`) on 2026-10-18, when the terminal's text color
moved from `#EDE7FF` to `#D6CBFA`.

Environment: macOS 26.6.2 (25G83) on the hosted `macos-26-arm64` runner image
20261013.0424.1, Xcode 26.6 (17F113), Swift 6.3.3; SF Mono 13 at 2×; 80 columns × 24 rows;
Legends Never Die palette; 1312 × 768 pixels. The render artifact's SHA-256 was
`9ec73a102bdf30358eb895dbcb6591f73f4593bb423e810fcba083c0c00b3180`, the digest the run
logged when it uploaded it.

Against the previous baselines (run 38085048125, commit `849ac9ec`), every changed pixel in
all six images is the old text color's antialiased blend over the background turned into the
new one's, and nothing else moved: 4,442 pixels in htop, 135,927 in less, 7,721 in tmux,
9,243 in Vim and 30,567 in each vttest matrix, the glow case included, since ordinary text
never glows. Each image was then inspected: htop's headers, meters and selected row; Vim's
syntax and line numbers; tmux's split borders and status; less's final page with its
reverse-video matches; and the vttest foreground/background matrices with glow off and on.
Text was upright, grid-aligned and unclipped; the glow case kept the color matrix with its
colored halos.

`make test-render` compares all six with the documented pixel tolerance. macOS CI also
requires both parameterized corpus comparisons and the glow comparison to execute.
These reviewed CI baselines do not complete physical-GPU, XDR, energy or manual acceptance;
review and compare them on the target Mac as described in
[Mac acceptance](../../../../../docs/MAC-ACCEPTANCE.md).
