# Implementation review and remaining plan

Review date: 2026-10-10. Baseline: `4b5a3831be5d8f025323cf7dac07f518455f77e8`.

The six approved workstreams are implemented. Portable and native macOS verification
pass, with hardware acceptance tracked separately below. Six native PNG baselines have
been visually reviewed and committed. No unchecked manual item, privacy result or real
notarization result is counted as completed.

| Approved work | Result | Evidence / acceptance |
| --- | --- | --- |
| SFTP correctness | Fresh destination checks, explicit overwrite approval, exclusive creates, request deadlines, cancellation cleanup and safe late replies | Portable lifecycle and Maze regressions, real SSH/SFTP integration |
| Mac acceptance | Commit-bound evidence capture and verification of logs, full checklist, baseline hashes, privacy verdict and performance budgets | `make accept-mac` / `make verify-mac`; real Mac run remains open |
| Transfer performance | Bounded descriptor IO, 32 KiB chunks, eight-request pipeline, staged downloads and monotonic progress capped at 20 Hz | Reordered replies, local publish race and cancellation regressions; hardware large-file measurement remains open |
| Usability and restoration | History find, UTF-16 accessible viewport, persisted split axes/ratios/focus/zoom/tabs/window frame | Portable Unicode/search/codec/restoration tests; AppKit/VoiceOver acceptance remains open |
| Phase 9 rendering | Bounded direct Kitty RGB/RGBA/PNG graphics, off-thread decoding, snapshot rendering and opt-in XDR with energy fallback | Parser, delta, policy and native pixel/shader tests pass; real XDR display acceptance remains open |
| Maintenance and release | Separate workspace/conversation controller extensions, GPU p50/p95, matched repeated performance comparisons, versioned Developer ID/notarized release workflow | Formatter/import checks, script preflights; real certificate/notary execution remains open |

## Phase status

| Phase | Implementation | Acceptance still required |
| --- | --- | --- |
| 0–1 | Existing scaffold, engine and conformance tooling retained | Existing intentional conformance exclusions remain documented |
| 2 | Existing renderer/input plus accessible terminal text and find; six reviewed PNG baselines committed | Real input methods, VoiceOver, display latency, idle behavior and target-GPU baseline comparison |
| 3–5 | Existing window/host/SSH/tunnel/snippet/quick-terminal features retained | Existing manual UI, Keychain, Touch ID and notch/display checks |
| 6 | Maze and streaming transfer fixes implemented | Large-file responsiveness and cancellation on an actual remote connection; dragging out to Finder remains deferred |
| 7 | Daemon transport and complete workspace metadata implemented | macOS privacy inheritance before/after quitting and real multi-window reattach |
| 8 | Existing shell integration retained and exercised on Linux | Native block chrome, command notifications and prompt-navigation checks |
| 9 | Ligatures, glow, bounded Kitty images and opt-in XDR implemented | Full graphics protocol extras are outside scope; real rendering/energy/performance exit criteria remain open |

## Post-implementation review

The review follows transfers through transport deadlines and publication, search through
worker/IPC/UI coordinates, workspace metadata through save/reattach, and images through
parser/delta/texture/readback. Findings corrected during this pass:

- Detached local IO now propagates cancellation, with cancellation checks before and after
  fsync so a cancelled staged download does not publish while flushing.
- Resetting graphics preserves the graphics revision and uses unique asset revisions.
  Reusing an image ID after reset cannot retain an old mirror asset or cached texture.
- Offscreen exports drain the bounded decoder and include inline images. Native tests cover
  raw/PNG orientation and both SDR and floating-point shader pipelines. The new pixel test
  caught a flipped PNG path; removing the extra CGContext flip fixed it without weakening
  the test. Native compilation also corrected the NSScreen display-headroom property.
- Search pagination overlaps enough rows for wide characters; the find bar reports an
  unavailable session instead of leaving “Searching…” indefinitely and caps highlight layers.
  A query captures its last history line across the worker/IPC seam, so continuous output
  cannot keep it following new pages forever. Reopening the find bar refreshes its retained
  query rather than displaying an old count with cleared matches.
- Pane focus, divider/split/zoom changes, selected tabs and window changes trigger workspace
  persistence; duplicate layout writes are suppressed.
- Mac acceptance rejects omitted/stale checklist entries, changed baselines, missing logs
  and skipped GPU comparisons. It does not synthesize successful hardware evidence.
- Benchmark comparison rejects missing machine/toolchain metadata, unsupported schemas,
  inconsistent round counts and invalid samples before assessing performance.
- The README follows the structure reviewed in AuroraPro.App and Byte, with an original
  banner, native dark/light fixture previews, verified shortcuts/settings/data paths,
  practical setup and troubleshooting, and explicit release-readiness limits.

The Kitty graphics implementation intentionally supports a bounded subset. External file
and shared-memory transports, compression, cropping, animation, virtual placements, Sixel
and iTerm image protocols are not implemented. Unsupported commands fail; placements keep
absolute grid coordinates across resize. Search collects at most 1,000 results and is a
query-time view of history, rather than an unbounded live index.

## Verification record

- Final local Linux Swift 6.3.3: 1,352 tests in 176 suites passed with real sshd/SFTP
  integration and zsh, bash and fish enabled, including the added history-bound regression.
- Earlier
  [Linux CI 38085048147](https://github.com/ronniekai999/death-race-for-code/actions/runs/38085048147)
  passed its 1,351 tests, including the sanitizer pass, formatter, three static checks,
  PTY smoke, esctest ratchet and one minute of fuzzing (67,705 inputs).
- [macOS CI 38085048125](https://github.com/ronniekai999/death-race-for-code/actions/runs/38085048125)
  passed 71 window tests in three suites and 1,384 other tests in 184 suites. It also passed
  native build/shaders, six corpus renders, all eight theme previews, the bundled smoke
  test and app/helper signature checks. It used macOS 26.6.2, Xcode 26.6, Swift 6.3.3 and
  Apple's Paravirtual Metal device. CI signing was ad-hoc, not Developer ID notarization.
- Six unmodified corpus PNGs were visually inspected and committed with provenance.
  macOS CI now explicitly compares the reviewed baselines and rejects skipped comparisons.
  The first comparison run passed all six images; its wrapper and acceptance verifier were
  corrected to recognize Swift Testing's parameterized “with 5 test cases passed” summary.
- Python and release/bundle shell syntax, workflow YAML, README links/assets, and Linux
  preflight failures passed. Structural acceptance-verifier checks used the actual native
  render-summary format: a simulated valid fixture passed and 12 invalid/incomplete fixtures
  were rejected. Benchmark validation rejected 18 invalid/noisy/regressing reports.
- Three repeated release-engine comparisons returned **inconclusive** because shared host
  variance exceeded 15%. This is not a passing performance or M5 acceptance result.

## Remaining execution plan

1. On a real Mac, execute the privacy spike first. If the inherited permissions fail,
   change the daemon default/design and rerun the before/after-quit evidence.
2. Review and compare the six committed render PNG baselines on the target GPU, then run
   all 227 manual checks with search, VoiceOver, workspace restoration, large transfers,
   images and XDR enabled. The CI previews alone do not establish physical-display acceptance.
3. Record target-Mac throughput, wakeups, frame counts, memory, key latency and GPU timings.
   Compare repeated matched release builds and require the documented 10% regression budget.
4. Run `make verify-mac` for the clean release candidate. Configure the release environment
   credentials, produce the signed/notarized/stapled draft and validate it on a clean Mac.
5. Close the remaining phase acceptance items and publish only after the evidence passes.

The largest remaining uncertainty is hardware acceptance. Controller decomposition is a
modest first step; the main window controller remains large. Future changes should keep
portable orchestration outside AppKit and extract cohesive UI responsibilities as they
change, rather than split files solely to lower line counts.
