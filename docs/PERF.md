# Performance and energy budgets

Measured, not assumed. Each budget names the tool that checks it. Numbers are for the M5
MacBook Pro this app is built on; regressions in CI are tracked relative to the last run.

| Metric | Target | How to measure |
| --- | --- | --- |
| Idle wakeups | ≤ 0.5/s over 60 s, cursor blinking | `sudo powermetrics --samplers tasks`, `top -stats pid,command,idlew,power` |
| Frames when idle or tab hidden | 0 | os_signpost frame counter; Instruments › Metal System Trace |
| Parser throughput (no PTY) | ≥ 300 MB/s ASCII, ≥ 100 MB/s mixed SGR/UTF-8 | `vthost bench` on vtebench payloads |
| End-to-end throughput | ≤ 1.5× Ghostty's time | vtebench run inside both apps |
| Keypress → frame on screen (app's share) | p95 ≤ one refresh + 3 ms | signposts from keyDown to `addPresentedHandler` |
| Memory | ≤ 50 MB per idle tab | `footprint <pid>` |
| Hitches | 0 at 120 Hz | Instruments › Animation Hitches |
| Benchmark regression | ≤ 10% | `make bench` before and after engine changes (not run in CI) |

## Engine throughput, measured

`make bench` (`vthost bench`, release build) feeds 4 MiB workloads to a 120×40 terminal for
two seconds each. These numbers are from the Linux CI container (4 vCPUs), not the M5, so
treat them as relative. The M5 budget above is checked on the Mac.

| Workload | What it is | First run | Now |
| --- | --- | ---: | ---: |
| ascii | log lines, like `cat` and build output | 80 MB/s | 190–200 MB/s |
| sgr | colored diagnostics: truecolor, 256-color, curly underlines | 44 MB/s | 84–87 MB/s |
| unicode | CJK, accents, skin tones, ZWJ families, flags | 13 MB/s | 31 MB/s |
| cursor | full-screen redraws: CUP, SGR, short writes, EL | 12.5 MB/s | 54 MB/s |

**The container is not a constant, and these numbers are not a budget.** Measured again during
the left-and-right-margin work, on the same image and the same build, ascii ran at 119–129 MB/s
against the 190–200 above, while sgr, unicode and cursor landed within a few percent of theirs.
Nothing in the engine accounts for that, so read the absolute figures as this container on the
day it was written. What is worth comparing is two runs an hour apart on one machine, which is
how the margin work was checked for a regression — three runs each way, no regression, and the
difference between the two sides smaller than the difference between runs on one side.

Against SwiftTerm, the engine most Swift terminals embed (`make vtdiff`: the same workloads,
both engines, release builds, same container):

| Workload | VTCore | SwiftTerm v1.20.0 | |
| --- | ---: | ---: | ---: |
| ascii | 187 MB/s | 35 MB/s | 5.3× |
| sgr | 101 MB/s | 14 MB/s | 7.2× |
| unicode | 35 MB/s | 5.2 MB/s | 6.8× |
| cursor | 64 MB/s | 9.9 MB/s | 6.5× |

What moved the numbers, found with `perf`:

- **Runtime exclusivity checks off in VTCore release builds** (about 2×). They cost a third
  of the time on class property access. Debug builds, where every test runs, keep them.
- **Rows move by `consuming` ownership** into scrollback and the spare pool, and recycled
  rows are cleared with a zero fill (a default blank cell is all zero bits).
- **Erasing fills a range in one pass** instead of writing cell by cell through a class
  property.
- **The parser's handler holds the terminal strongly.** Calls through an
  `unowned(unsafe)` reference retain and release it every time.
- **Width and grapheme properties come from a two-stage table**, two array loads instead
  of binary searches.
- **Graphemes are only looked up for cells whose grapheme bit is set.**

Tried and reverted: `unowned(unsafe)` locals for the screen and rows in the print path made
everything 25–60% slower, because each use copies a strong reference.

Still to do: the per-character path retains and releases rows on every cell access. That
needs restructuring, done when the M5 measurements say it matters.

**After OSC 8 links (Phase 3).** Every print path now looks up the open link once per row
segment and stamps it on each cell. Three runs in the same container:

| Workload | Runs (MB/s) |
| --- | --- |
| ascii | 185, 178, 198 |
| sgr | 92, 94, 91 |
| unicode | 27, 32, 31 |
| cursor | 60, 61, 65 |

All are within run-to-run noise of the numbers above.

**After Conversations (Phase 8).** The engine's hot path gained the `OSC 133` parameter walk and
`OSC 633;E`, both of which run once per command rather than per cell, and `CommandRecord` on the
row, which `Row.estimatedBytes` now counts toward the scrollback cap. Nothing per-character
changed, and the benchmark numbers above are unmoved.

What the phase deliberately does **not** spend:
- **The rail and the band rebuild no rows.** Both are applied after `FrameBuilder`'s row cache,
  exactly as the hovered link's underline is, so `rebuiltRows` stays 0 while they are on screen —
  asserted by a test rather than hoped for.
- **The badge is a layer the Metal pass never sees.** It moves inside the same `CATransaction`
  as the frame's `present()`, so it cannot shear against scrolling text, and its gradient text is
  drawn into an image once and cached by `(text, scale)`.
- **Finding a prompt is one query per keypress, not per frame.** `promptSpan` scans the
  scrollback the engine already keeps, bounded at 50,000 lines, and only when ⌘↑/⌘↓ or a block
  selection asks.
- **The bests file is written at most once every three seconds**, and only when a record
  actually changed — a loop of distinct commands writes it a few times, not a thousand.

## Measuring on the Mac

The Phase 2 budgets above are checked by hand on the M5, with a debug build
(`CONFIG=debug make run`); [MANUAL-TESTS.md](MANUAL-TESTS.md) lists them with the rest.

- **Debug › Log Frame Stats** shows, for the focused tab:
  - the frames drawn and how often the display link started;
  - the main thread's time per frame, as p50 and p95;
  - key to screen, as p50 and p95: from a key press to the moment the next frame was
    presented (`addPresentedHandler`).

  It writes the same to the log: `log stream --predicate 'subsystem == "local.deathraceforcode.DeathRace"'`.
- **Signposts** under the same subsystem:
  - intervals: `Frame` and `DeltaApply`;
  - events: `LinkResumed`, `LinkPaused`, `KeyToScreen` and `Bell`.

  Record them with `xcrun xctrace record --template 'Time Profiler' --attach DeathRace`, or
  in Instruments with the Points of Interest, Metal System Trace and Animation Hitches
  templates.
- **Idle wakeups.** Run `sudo powermetrics --samplers tasks -i 60000 -n 1 | grep -i death`
  with one idle window and the cursor blinking. While the window is idle, the frame count
  in Log Frame Stats should not move.
- **Memory.** Run `footprint $(pgrep -n DeathRace)` with one idle tab, then with eleven.
- **Idle with WRLD** (Phase 4's exit criterion 7). Show the sidebar, connect to two hosts and
  open a tunnel, then leave it for a minute: no frames, and at most 0.5 wakeups a second for
  the app (the `ssh` processes are counted apart, and their keepalives are yours). Then hide
  the sidebar and close the WRLD window: `log stream --level debug --predicate 'subsystem ==
  "local.deathraceforcode.DeathRace" AND category == "WRLD"'` should show no "Checking how
  quickly…" line from then on.

## Where the energy goes, and where it doesn't

- **Idle is free.** Session threads block in `poll`; the display link pauses after a few empty
  ticks; cursor blink is a Core Animation animation that never wakes the app.
- **Background tabs never draw.** Their sessions keep parsing on utility QoS, so macOS can
  schedule them on the efficiency cores. The app takes their updates at most four times a
  second, enough for titles, bells and the shell's exit, and the session merges what
  arrives in between.
- **Output floods coalesce.** The session thread publishes at most one delta per frame and
  never waits on the renderer.
- **The chrome draws nothing per frame.**
  - The NeonBorder and the pills are layers drawn once.
  - The glow is a shadow with a fixed path.
  - Panes not in use are dimmed inside the terminal's own shader.
  - The starfield is drawn once per size on the ground, and by the background shader
    behind the text.
  - The equalizer is a Core Animation animation that stops a moment after output does.
  - Nothing in the chrome runs a timer.
- **Output draws no faster than it is read.**
  - Busy output is capped at 60 frames a second (`output-frame-rate-cap`), while typing,
    scrolling and selecting keep the display's full rate for a second after each.
  - Low Power Mode lowers output to 30 (`follow-low-power-mode`), and a serious thermal state
    caps everything at 30.
  - The display link's range is set only when the answer changes, from notifications rather
    than polling.
- **The session daemon is free at rest.** Every thread in `legendsd` is parked in `poll` with
  no timeout: the listener, one per control connection, one per session loop, one per session
  bridge. There are no timers and nothing periodic, so idle cost is zero by construction
  rather than by tuning. A detached session stops building deltas at all, so a `yes` nobody
  is watching costs the parser and no more — what would otherwise be spent is a full-viewport
  delta on every publish, since nothing is taking them and `delivered` would never advance
  (and in debug builds each one round-tripped through `DeltaCodec`). The app's thread count is
  unchanged: a bridge thread stands where a session thread stood.
  - Measured on Linux CI on every push, from `/proc/<pid>/stat`: three sessions, the client
    killed, and the processor time the daemon spends over two seconds. The budget is loose on
    purpose and the comment says what the test actually proves — that nothing polls — rather
    than pretending a millisecond count is a law.
  - On the Mac: `sudo powermetrics --samplers tasks` with the app quit and sessions held.
- **Reattaching costs one snapshot a session.** The app never holds scrollback, so coming back
  is connect, list, adopt, one snapshot each; scrolling up afterwards reaches the daemon's
  history through `scroll(by:)` like any other scroll.
- **Where each session sits is written on a move, not on a clock.** Tabs and panes moving is
  something someone did, so the record is written then; a title changing never writes, which
  matters because a program can rewrite its title many times a second.
- **Settings and the palette cost nothing when closed.** Both are made when they open and
  released when they close.
  - The settings file is watched with kernel event sources.
  - The Energy page samples every two seconds only while it is on screen, and leaves its own
    wakeup out of what it shows.
- **The quick terminal is free while hidden.** Lucid Dreams is one panel the app keeps across
  hide and show. Hiding is `orderOut`: the surface stops drawing at once, and the shell behind
  it only wakes the app when it has output, exactly like a background tab. Summoning is meant to
  beat 100 ms — a signpost from the hotkey to the first frame measures it — and nothing animates
  once the panel is at rest.
- **WRLD waits; it never polls.**
  - Each master is an `ssh` the app waits on with one thread blocked in `poll`: on its
    pipes, and on an exit watch (a kqueue on macOS, a pidfd on Linux). It is ready when it
    prints the marker its `LocalCommand` echoes, so nothing knocks on its socket to find
    out. A master with no panes or tunnels left ends ten minutes later, from one sleeping
    task.
  - Keepalives are ssh's own (your `ServerAliveInterval`); the app sends nothing to keep a
    connection open.
  - The askpass broker blocks in `poll` on its socket and a wake pipe, and answers only
    when ssh asks.
  - Come & Go keeps no counters and runs no `-O check` on a timer: OpenSSH reports no
    traffic counts, and the app is the record of what it opened.
  - Latency checks run only for Legends, only while the sidebar or the WRLD window is on
    screen and not covered: one timer every five minutes with a minute's tolerance, so
    macOS can fold it in with other wakeups, plus `NWPathMonitor` for network changes. A
    check is a TCP connect that sends nothing and gives up after two seconds. When the last
    viewer goes, the timer and the monitor go too.
  - A host's OS is read at most once a week, over a master that is already connected,
    after you've had a session there.
  - `wrld.json` and `~/.ssh/config` are watched with kernel event sources, as the settings
    file is.
  - The WRLD window is made when it opens and released when it closes. The sidebar draws
    its rows itself, and only when WRLD, its tunnels or the window change.
- **Armed and Dangerous costs a few bytes per key.** Each armed pane encodes what was typed
  for its own program; the banner and the borders are layers drawn once.
- **Maze is free when no file is moving.** The transport's reader thread blocks in `poll` on
  the subsystem's pipes and the writer waits on a condition, so an open window with nothing in
  flight costs nothing and draws no frames: both panes are lists that change only when you
  ask for a folder. During a transfer the chunk is 32 KiB — OpenSSH caps a single
  `READ`/`WRITE` payload there over the default channel window, so a larger request would
  just be split — and each chunk hops to the main actor to move the bar.
  - **Still to do.** Nothing throttles that: a 2 GiB transfer is about 65,000 hops, one per
    chunk, each its own task, so the ordering between two of them isn't guaranteed and the
    bar can step backwards. A transfer is I/O-bound enough that this hasn't shown up as cost,
    but it should be coalesced to one update a frame rather than one a chunk. The window holds the host's master while it is open; closing it ends
  the subsystem and lets the master idle out as a pane's would.
  - **Still to do.** Maze sends one chunk at a time and waits for its `STATUS` before the
    next, so throughput is bounded by the round trip: about a megabyte a second on a 30 ms
    link, where OpenSSH's own `sftp` pipelines 64 requests and saturates the link. The client
    already correlates replies by request id, so a window of outstanding chunks is the change;
    it waits on a measurement from a real transfer on the M5 rather than a guess here.
- **Phase 9's effects ride existing frames.** Text glow and XDR Neon draw only on frames that
  output, typing or scrolling already caused, and Low Power Mode or thermal pressure at
  `serious` or worse turns them off, through `EffectsPolicy` beside `FrameRatePolicy` so the two
  agree about what "spend less" and "hot" mean.

  **Not battery**, and that is a narrowing of what this line used to promise rather than a gap
  left open. There is no power-source API anywhere in the repo and adding one would mean IOKit
  and a second notification source, for behaviour nobody asked for, that would ship unexercised
  — a runner has no battery. Low Power Mode is the explicit "spend less" signal and is already
  read; a MacBook on battery at full charge has power to spare, and silently removing the app's
  signature visual because a cable came out would surprise people more than it would save them.

  `recentInput` is deliberately **not** an input to the effects policy, though it is to the
  frame rate's: the conditions are rebuilt on every key press, so a glow keyed off it would
  blink on and off as you type. A test pins that it changes nothing under every other condition.

- **The glow costs fragments and no CPU at all, which is why `frameTime` will not move.** Said
  plainly rather than papered over: it is one more instanced draw over the `frame.glyphs` buffer
  the next draw already uses, so there is nothing new to build, no row to rebuild and no buffer
  to fill. `FrameStats` measures main-thread work per frame, so it cannot see this at all and
  the energy criterion is written against `powermetrics` and Instruments' GPU timeline instead.
  A `gpuTime` counter fed from `MTLCommandBuffer.gpuStartTime` is the cheap follow-up, and is
  deliberately not in this change.

  What it does cost: a vertex-stage test per glyph, which culls a non-emitting glyph to a
  zero-area quad outside the clip volume so no fragment runs for it, and 13 texel reads per
  fragment for the glyphs that do emit, over a quad grown by the radius plus one. Measured
  against the alternative rather than assumed: a half-resolution separable blur costs about
  6.4M texel reads *regardless of content*, plus four more encoders, two viewport textures and
  a sampler this renderer does not otherwise have; the scatter costs about 2.2M in the realistic
  case of a tenth of the screen being bright, and about 22M only when every cell is. So the
  separable route is three times worse normally and better only in the pathological case. It is
  the documented fallback if a real profile on the M5 demands it, along with a pre-blurred atlas
  — about fifty times cheaper on the GPU, at the cost of a wider `GlyphInstance`.
- **Ligatures cost atlas, not frames.** A run is scanned in `buildRow`, which runs only for rows
  that are dirty, so a screen that is not changing does no shaping work at all and the frame
  count is untouched. What it does cost is the atlas: a run is its own key, its bitmap is two to
  eight cells wide, and `ShelfAtlas` buckets by height only — so run bitmaps land on the same
  shelves as ordinary text and use them up several times faster.

  It also costs *shaping*, and that one has a bad case worth naming rather than hiding. The
  scanner asks the shaper up to `maxCells - 1` questions for each candidate column, and the set
  of distinct questions is every substring of the alphabet up to that length — so the cap is an
  exponent, not a detail. Measured on an 80 by 24 screen of varied punctuation: about 10,800
  questions for one full rebuild with the cap at eight, against sixteen for a screen of ordinary
  source code. That is the cap's whole reason for being five: four questions a column instead of
  seven, a key space orders of magnitude smaller, and every ligature either bundled family has
  still inside it, the widest being four characters. The memo starts again at its bound rather
  than stopping, so even the bad case cannot leave every later question reaching the font.

  Worth measuring on the Mac, and measurable here too, since `GlyphCache` and `ShelfAtlas` are
  portable: replay a corpus recording of source code with shaping off and on, and compare the
  shelf count and the number of `epoch` bumps. An `epoch` bump is the expensive one — it makes
  every row look its glyphs up again. Asking CoreText whether a face ligates two characters costs
  far more than drawing the answer, so `MemoizedRunShaping` pays it once per distinct run per
  face; on Monaspace about half of all punctuation pairs and triples shape differently, so the
  memo settles at a few hundred answers rather than growing.
- **Shaping off is free, and that is asserted rather than assumed.** With the setting off no
  shaper exists, the scanner never runs, and a test compares the frame's glyph and decoration
  instances built with no parameter against the same frame built with an explicit nil.
- **XDR Neon is opt-in.** Extended dynamic range uses more bandwidth and power; Apple's guidance
  is to enable it only when the user will see the difference.
