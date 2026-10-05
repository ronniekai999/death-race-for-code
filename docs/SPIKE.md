# The legendsd spike

Phase 7 moves shells out of the app into `legendsd`, a LaunchAgent that keeps sessions
alive when the app quits ("Legends Never Die"). macOS privacy protection (TCC) decides what
a process may read by asking about its **responsible process**. Today that is Death Race
for every shell, because shells are the app's children. A LaunchAgent is started by
launchd and can be its own responsible process. In that case its shells would not get the
grants you gave Death Race, and the prompts would name something else. On macOS 26.3.1 a
PTY host re-parented to launchd has also been reported to fail with *"Failed to create
Attribution Chain"*.

There is a third way to start a daemon that the question above skips: the **app** can spawn
it, in a session of its own, so it outlives the app without launchd ever being involved. TCC
responsibility passes down through fork and exec and is reassigned only at the top of a tree,
where launchd or LaunchServices starts something — so a daemon the app spawned should inherit
Death Race, and so should its shells. If that holds, Phase 7 needs no LaunchAgent at all. It
is measured here too, because measuring it costs nothing once you are already set up.

This spike answers the question before Phase 7 is designed around it. It takes about an
hour on your Mac. The helper, `legendsd-spike`, lists Desktop, Documents, Downloads,
iCloud Drive, `~/Library/Mail`, `~/Library/Safari` and a mounted volume, first itself and
then from `zsh` on a pseudo-terminal, exactly as the app starts shells. It records each
result and whom macOS holds responsible. Where it is asked to probe twice, it writes one
report per pass: a responsible process that has since exited is itself a result.

## Build

```sh
SPIKE=1 CONFIG=debug scripts/bundle.sh
ditto "build/Death Race for Code.app" "/Applications/Death Race for Code.app"
```

- Sign with your Apple Development identity. `bundle.sh` finds it. An ad-hoc signature
  changes with every build, and TCC grants follow the signature.
- Run the copy in `/Applications`, so the LaunchAgent's path stays put.
- The debug build has a **Debug** menu with the spike's items.

## Steps

Keep a terminal other than Death Race open for the commands, such as Terminal.

1. **Start clean, and watch.**

   ```sh
   tccutil reset All local.deathraceforcode.DeathRace
   tccutil reset All local.deathraceforcode.legendsd-spike
   log stream --style compact --predicate 'subsystem == "com.apple.TCC" OR subsystem == "local.deathraceforcode.DeathRace" OR eventMessage CONTAINS[c] "attribution"' > /tmp/spike-log.txt
   ```

2. **The baseline: the probe as the app's child.** Open the app and choose **Debug › Run
   Spike Probe in App**. For each prompt:
   - Allow Desktop and Downloads; deny Documents.
   - Write down the name the prompt shows, or take a screenshot.

3. **Register the agent.** Choose **Debug › Register Spike Agent**. If macOS asks, approve it
   in System Settings › General › Login Items & Extensions.

4. **Run it as an agent, with the app open.**

   ```sh
   launchctl kickstart gui/$(id -u)/local.deathraceforcode.legendsd-spike
   sudo launchctl procinfo $(pgrep -n legendsd-spike) | grep -i responsible
   ```

   It stays alive for 30 seconds for the second command. Note any prompts and the names
   they show.

5. **Again, with the app quit.** Quit Death Race, then repeat step 4.

6. **As a daemon the app spawned.** Open the app again and choose **Debug › Run Spike Probe
   as a Spawned Daemon**. The app starts the helper itself, with `setsid`, so it outlives the
   app — which is what `legendsd` would be if we started it rather than launchd.

   ```sh
   sudo launchctl procinfo $(pgrep -n legendsd-spike) | grep -i responsible
   ```

   Then **quit Death Race**. The helper waits for the app to go — however long you take —
   probes a second time without it, and writes a report for each pass. Run the `procinfo`
   command again afterwards: by then the pid it names as responsible belongs to a process
   that has exited, which is the one thing this case can get wrong.

7. **Full Disk Access.**
   1. Add Death Race in System Settings › Privacy & Security › Full Disk Access.
   2. Repeat steps 2, 4 and 6.
   3. Add `legendsd-spike` too. It is inside the app, at `Contents/MacOS`; press ⌘⇧G in
      the file dialog to get there.
   4. Repeat step 4.

8. **After a rebuild.**
   1. Build and copy again as in [Build](#build). Grants are meant to survive a rebuild
      signed by the same identity.
   2. Repeat steps 2, 4 and 6.

9. **Clean up.** Choose **Debug › Unregister Spike Agent**.

## What to send back

- The JSON reports, `~/Library/Logs/DeathRace/legendsd-spike-*.json`. Each is named for the
  way the helper was started and which pass it is, and says:
  - whether the helper ran as the app's `child`, as an `agent`, or `spawned` by the app;
  - whether it is the `first` pass or the one `again` after the app had gone;
  - every result, from the helper and from its shell;
  - each one's responsible process.
- `/tmp/spike-log.txt`.
- The names the prompts showed.
- `sw_vers`, since the verdict is recorded with the macOS build.

## The verdict

It goes into [ARCHITECTURE.md](ARCHITECTURE.md#the-legendsd-spike), and decides Phase 7:

| What we see | Verdict | Phase 7 |
|---|---|---|
| The agent's shells are attributed to Death Race: prompts name it, and its grants apply | **As designed** | legendsd as planned |
| The agent is its own responsible process: prompts name `legendsd-spike`, and grants are needed twice | **Grants twice** | Onboarding grants the helper what it needs |
| The agent is its own responsible process, but a daemon the app spawned is attributed to Death Race — on both passes | **Spawn it ourselves** | `legendsd` is the app's own child in a session of its own: no LaunchAgent, no SMAppService, no Login Items approval, no second grant |
| Attribution fails either way, or the shells are denied what the app was granted | **Redesign** | Shells stay in the app; a windowless background app keeps them alive |

`legendsd-spike` reads the responsible process with
`responsibility_get_pid_responsible_for_pid`. That is a private call, the one
`launchctl procinfo` reports. It is fine in a throwaway probe and never belongs in the app.
