# Death Race for Code beta

Thanks for trying Death Race for Code early. It is a native macOS terminal with a home for your
servers and sessions that outlive the app. The features below are built and pass CI. What a
beta adds is you, on a real Mac, finding where it falls short.

## Before you install

- **An Apple silicon Mac with macOS 26 or later.** Intel Macs are not supported by beta builds.
- **The beta is not notarized.** It is signed ad-hoc rather than with a Developer ID, so macOS
  needs one step before the first launch, shown below.
- **Approvals reset with each beta.** Every build has a new signature, so after an update
  macOS asks again before the app reads saved passwords from your Keychain or a folder such as
  Documents. Choose **Always Allow** or **Allow**.

## Install

Download `Death-Race-for-Code-<version>.zip` from the
[Releases page](https://github.com/ronniekai999/death-race-for-code/releases). Then, in Terminal
(this example uses beta 1):

```sh
cd ~/Downloads
shasum -a 256 -c Death-Race-for-Code-0.1.0-beta.1.zip.sha256   # optional, if you downloaded it too
ditto -x -k Death-Race-for-Code-0.1.0-beta.1.zip /Applications
xattr -dr com.apple.quarantine "/Applications/Death Race for Code.app"
open "/Applications/Death Race for Code.app"
```

`xattr` clears the download's quarantine from the app and from the two helpers inside it.

Prefer Finder? Open the zip, drag the app into Applications and open it. When macOS says it
cannot verify the app, open **System Settings › Privacy & Security**, choose **Open Anyway** for
Death Race for Code and confirm. Run it from Applications either way, so the session helper
beside it stays where it was started.

## Your first ten minutes

| Try | How |
| --- | --- |
| Make it yours | ⌘, opens Settings: eight themes, fonts, glow. Changes apply live. |
| Tabs and splits | ⌘T, ⌘D (right), ⇧⌘D (down), ⇧⌘Return to zoom a pane, ⌘W to close it. |
| The command palette | ⇧⌘P, **Hear Me Calling**: every action, host, snippet and tunnel by name. |
| Your servers | ⌘O opens **WRLD**. Add a host, or add the hosts `~/.ssh/config` already names from the offer above the cards. Password and host-key questions appear as sheets. A second pane on the same host reuses the login. |
| Files | In a pane on a host, ⇧⌘P › **Open in Maze**. Upload, download, drag between the two sides, or drop Finder files on it. |
| Quick terminal | ⌥Space from any app: **Lucid Dreams** drops down from the notch and keeps its session. |
| Command history | Run a few commands. ⌘↑ and ⌘↓ jump between prompts, ⇧⌘A selects a command with its output, ⌘F searches history. A long command finishing in another tab sends a notification. |
| Sessions that survive | Start `top`, quit with ⌘Q and reopen. **Legends Never Die** puts the shell, its scrollback, your splits and tabs back. |
| Broadcast | ⇧⌘I in a tab with splits sends your typing to every pane in it. The border shows it is armed. Use it carefully. |

zsh and fish get command marks automatically. For bash, the app offers one line to add to your
startup file.

## Known issues and limits

- **Folder access in kept sessions is unconfirmed.** Legends Never Die holds local shells in a
  helper, `legendsd`, so they survive quitting the app. We have not yet confirmed on a real Mac
  that folder access you grant the app (Documents, Desktop, Downloads) carries over to those
  shells after the app quits. If a restored shell is denied a folder, or a permission prompt
  names something other than Death Race for Code, please report it. To turn the feature off,
  clear **Keep local shells running when Death Race quits** in Settings › General, or add
  `legends-never-die = false` to `~/.config/deathrace/config`.
- SSH panes end when the app quits. Only local shells are kept.
- Maze cannot yet drag remote files out to Finder.
- Inline images support the Kitty protocol's direct RGB, RGBA and PNG data only. Sixel and
  iTerm images are not supported.
- **XDR Neon** is off by default (`xdr-neon = true` to try it on an XDR display).
- Performance, energy use and VoiceOver have not been through hands-on acceptance yet. Reports
  of slowness, battery drain or accessibility gaps are especially useful.

## Report what you find

Use the [beta feedback form](https://github.com/ronniekai999/death-race-for-code/issues/new?template=beta-feedback.yml).
It asks for:

- the version in **Death Race › About Death Race for Code**, such as `0.1.0 (1)`;
- your macOS version (`sw_vers -productVersion`) and Mac model;
- what you did, what you expected, and what happened instead.

Logs help with sessions and connections:

```sh
log show --last 15m --style compact --predicate 'subsystem == "local.deathraceforcode.DeathRace"'
cat ~/.deathrace/run/legendsd.log
```

Review anything before you attach it. Host names, snippets and paths can be sensitive, and
`~/.config/deathrace/wrld.json` holds all three.

## Update to a new beta

Kept sessions stay with the previous build's `legendsd` until they end. Close your local panes
first, or end them all with `pkill -x legendsd`. Then replace the app. Remove the old copy first,
because extracting over it can leave stale files that break its signature:

```sh
rm -rf "/Applications/Death Race for Code.app"
ditto -x -k ~/Downloads/Death-Race-for-Code-<version>.zip /Applications
xattr -dr com.apple.quarantine "/Applications/Death Race for Code.app"
```

Your settings, hosts and snippets are kept.

## Uninstall

```sh
pkill -x legendsd                               # ends any kept sessions
rm -rf "/Applications/Death Race for Code.app"
rm -rf ~/.deathrace                             # runtime state, generated ssh config, key handles
rm -rf ~/.config/deathrace                      # settings and WRLD; back up wrld.json to keep hosts
```

Deleting `~/.deathrace/keys` makes any Secure Enclave keys created in the app unusable. Remove
their public halves from your servers' `authorized_keys`. Saved passwords are in Keychain Access
under **Death Race for Code**. If you set `XDG_CONFIG_HOME`, settings live under it instead of
`~/.config`.
