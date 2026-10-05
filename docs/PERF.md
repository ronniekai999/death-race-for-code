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
- **Phase 9's effects ride existing frames.** Text glow and XDR Neon will draw only on frames
  that output, typing or scrolling already caused, and Low Power Mode, battery and thermal
  pressure will turn them off.
- **XDR Neon is opt-in.** Extended dynamic range uses more bandwidth and power; Apple's guidance
  is to enable it only when the user will see the difference.
