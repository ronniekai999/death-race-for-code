# Mac acceptance

The code can be implemented and CI can pass while a phase's hardware acceptance remains
open. This procedure records evidence for a particular clean commit; it never marks the
privacy spike or a manual check passed automatically.

1. Use macOS 26 on a real Mac with a display and Metal GPU. Run the privacy investigation
   in [SPIKE.md](SPIKE.md) first. Keep its before/after-quit reports. If the spawned daemon
   does not inherit the app's permissions, change the daemon default or architecture before
   closing Phase 7. The acceptance script does not reset privacy permissions.
2. Run `make test-render`. Missing PNGs are written and the tests fail deliberately. Review
   all six images in `Packages/DeathRaceKit/Tests/Fixtures/render`, commit the approved PNGs
   and rerun. Never approve a baseline solely because it was generated.
3. From a clean committed tree, run `make accept-mac`. It captures OS, machine, toolchain,
   commit, full tests, render comparisons, throughput logs and baseline hashes in
   `build/mac-acceptance`. Build output is ignored by git. Any failed command remains failed
   in the report; completing the manual file cannot override it.
4. Fill `manual.json` with observed results for every entry in
   [MANUAL-TESTS.md](MANUAL-TESTS.md). Record useful evidence references, privacy report paths
   relative to the evidence directory and measurements from [PERF.md](PERF.md). Set
   `goldens_reviewed` only after inspecting every baseline. `real_hardware` records the
   actual test environment, not a CI runner.
5. Run `make verify-mac`. It requires a matching clean commit, completed test logs, reviewed
   unchanged PNGs, the full current checklist, the successful privacy verdict and the
   numerical budgets. A missing/stale entry or skipped GPU comparison leaves acceptance
   open. Archive the evidence with the release candidate.

When code or the checklist changes, rerun from the new clean commit and reconcile the
manual evidence. An older report does not accept a new build. Absolute throughput targets
still require the documented target Mac; Linux throughput is only regression evidence.
