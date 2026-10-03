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
| Linux benchmark regression | ≤ 10% | `linux.yml` VTBench job |

## Where the energy goes, and where it doesn't

- **Idle is free.** Session threads block in `poll`; the display link pauses after a few empty
  ticks; cursor blink is a Core Animation animation that never wakes the app.
- **Background tabs never draw.** Their sessions keep parsing on utility QoS, so macOS can
  schedule them on the efficiency cores.
- **Output floods coalesce.** The session thread publishes at most one delta per frame and
  never waits on the renderer.
- **Effects ride existing frames.** Glow and starfield parallax draw only on frames that output,
  typing or scrolling already caused. Low Power Mode, battery and thermal pressure turn them off.
- **XDR Neon is opt-in.** Extended dynamic range uses more bandwidth and power; Apple's guidance
  is to enable it only when the user will see the difference.
