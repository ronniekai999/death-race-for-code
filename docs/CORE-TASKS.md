# Core tasks

Five tasks decide whether Death Race for Code feels better than Termius or worse. Each one has
a step count to beat. Until a task meets its target, work on it comes first.

| # | Task | Termius 10.2.1 | Death Race today | Target |
| --- | --- | --- | --- | --- |
| 1 | [New server](#1-new-server) | 7 | 6, met | 6 |
| 2 | [Reconnect](#2-reconnect) | 2 | 3 | 1 |
| 3 | [Folder transfer](#3-folder-transfer) | 4 | Not possible in Maze | 3 |
| 4 | [A snippet on two hosts](#4-a-snippet-on-two-hosts) | 7 | 12; 6 with the sidebar and ⌘-click | 5 |
| 5 | [Quit and relaunch](#5-quit-and-relaunch) | Not measured yet | 0 for local shells; 4 per ssh pane | 0, and 1 per window with ssh panes |

## The rule

- **Core tasks first.** Hardening an edge case waits unless it fixes a crash, lost data, a
  security problem, or one of these tasks.
- **A change to a task's flow counts it.** Its pull request gives the task's step count before
  and after, counted as below.
- **A step added to a core task needs a reason** in the pull request.
- **A task that meets its target stays met.** A later change that puts it back over is a
  regression, like a failing test.

## How to count

A step is one deliberate action: a click, a key chord, a field typed into (however long), or a
Return that submits. Reading, waiting and scrolling don't count. Count from the task's start to
its finish on the path a new user finds from what is on screen. A faster path that only
someone who knows the shortcuts would find is listed beside it, but the target is for the path
on screen.

Termius was measured on 2026-10-24: Termius 10.2.1 for Linux, the same Electron interface as
the Mac app, against a loopback OpenSSH server with password sign-in. Termius 10 opens on an
account sign-in that can't be skipped; that step isn't counted. Death Race's counts are traced
through the code, because the app needs a Mac to run: first at `8f91f66`, then again with quick
connect, when Touch ID was counted too. The first count missed it: a saved password leaves the
Keychain only after Touch ID, or the login password, once per connection. Touch ID is a step
here because it's one more thing to do; Termius asks for nothing there. Confirm the counts on a
Mac with the checks in [MANUAL-TESTS.md](MANUAL-TESTS.md#core-tasks), and record the Mac count
and the macOS build here when you do.

## 1. New server

**Start:** the app open on a terminal; nothing about the server saved. The server is
`wrldjump@127.0.0.1` on port 2222, with password sign-in and a host key never seen before.
**Finish:** a shell on the server, and the server saved with its password, so task 2 needs
neither.

| | Termius: 7 | Death Race: 6, with quick connect |
| --- | --- | --- |
| 1 | Click the `ssh user@hostname -p port` field above the hosts | ⇧⌘P, or the title bar's search button: Hear Me Calling |
| 2 | Type `ssh wrldjump@127.0.0.1 -p 2222` | Type `ssh wrldjump@127.0.0.1 -p 2222`; the first row says "Connect to wrldjump@127.0.0.1:2222" |
| 3 | Return: a tab opens with the user filled in | Return: the host is saved in WRLD and opens in a new tab |
| 4 | Continue & Save | Trust and Connect, in a sheet |
| 5 | Add and continue, the host key, inside the tab | The password, in a sheet |
| 6 | Type the password | Return: a shell. Save in the Keychain is ticked, so the password is saved once it works |
| 7 | Return: a shell, with the host and password saved | |

**Met: 6.** Before quick connect it took 10, through WRLD's New Host with each field typed on
its own and Save in the Keychain ticked by hand.

Termius's field is on its main screen. Death Race's is one step away, behind ⇧⌘P or the title
bar's search button, whose placeholder says to type `ssh user@host`; the welcome and the empty
sidebar say so too.

WRLD's New Host now takes 7: ⌘O, New host, Address `wrldjump@127.0.0.1:2222` (which fills
User and Port), Add host, Trust and Connect, the password, Return.

Unticking Save in the Keychain makes no difference to this count, but task 2 then asks for the
password again.

Typing `ssh -p 2222 wrldjump@127.0.0.1` into a local pane also takes 6 steps, but nothing is
saved, so WRLD, Maze and task 2 know nothing about the server.

**Still to do, without changing the count:**
- Ask the host-key question and the password inside the connecting pane, as Termius does,
  rather than in sheets over the window.
- Quick connect from WRLD's search, too.

## 2. Reconnect

**Start:** the app open; the host from task 1 saved with its password; no connection to it.
**Finish:** a shell on it.

| | Termius: 2 | Death Race: 3 |
| --- | --- | --- |
| 1 | Vault | ⌘O opens WRLD |
| 2 | Double-click the host | Connect, on its card |
| 3 | | Touch ID, to release the saved password |

Hear Me Calling takes 3 when the host was the last thing picked there, as it is straight after
quick connect: ⇧⌘P, Return, Touch ID. Otherwise it's 4, with the host's name typed. With the
sidebar shown it takes 2: a click on the host, then Touch ID. But the sidebar is hidden until
⌃⌘S. Until builds share one signing identity, each new build also asks once for Keychain
access.

**To reach 1,** both are needed:
- Show the sidebar by default once WRLD has hosts, so one click reconnects. The welcome's Add
  to WRLD makes that the usual case for anyone with a `~/.ssh/config`. A recent-hosts list on a
  new tab would also do it.
- Ask for Touch ID less often, or not at all. It guards every saved password, so this is a
  decision about security, not only about steps. It needs to be made on purpose.

## 3. Folder transfer

**Start:** a pane on the host; a folder, `site`, with a folder inside it, in your home folder on
this Mac.
**Finish:** `site` and everything in it in the host's home folder.

| | Termius: 4 | Death Race: not possible |
| --- | --- | --- |
| 1 | The SFTP tab | Maze moves files, not folders ([BETA.md](BETA.md)) |
| 2 | Double-click the host on the right | Today's route is `scp -r` in a pane |
| 3 | Right-click `site` on the left | |
| 4 | Copy to target directory: `site/assets/app.css` and `site/index.html` arrive | |

Termius checked: the folder arrived with its subfolder.

**To reach 3:** folders in Maze, up and down, by dragging and by dropping from Finder. Then:
Shell › Open in Maze (2 clicks, since it has no shortcut) and drag `site` across (1). A shortcut
for Open in Maze would make it 2.

## 4. A snippet on two hosts

**Start:** the app open; two saved hosts with saved passwords, neither connected; a saved
snippet with no fields, `whoami && uptime`.
**Finish:** the snippet has run on both hosts.

| | Termius: 7 | Death Race: 12, through Hear Me Calling |
| --- | --- | --- |
| 1 | Vault | ⇧⌘P |
| 2 | Snippets | The first host's name |
| 3 | The snippet | Return: a new tab |
| 4 | Add targets | Touch ID, for its password |
| 5 | Tick the first host | ⇧⌘P |
| 6 | Tick the second host | The second host's name |
| 7 | Run: both connect and run it, in a tab that lists the two | ⌘Return: beside the first |
| 8 | | Touch ID, for its password |
| 9 | | ⇧⌘I: Armed and Dangerous |
| 10 | | ⇧⌘P |
| 11 | | The snippet's name |
| 12 | | ⌘Return: it runs in both |

Termius keeps the two hosts as the snippet's targets, so the next run takes fewer steps. Death
Race also leaves both panes armed, so the next keystroke goes to both until ⇧⌘I again; that's
one more step, not counted above.

With the sidebar shown, it takes 6: click the first host, Touch ID, ⌘-click the second, Touch
ID, ⇧⌘I, then ⌘-click the snippet. That's quicker than Termius, but nothing on screen says
⌘-click does any of it.

**To reach 5:** a snippet's Run On… that takes several hosts, opens them side by side, runs the
snippet once in each and leaves nothing armed. Remember the hosts for next time, as Termius
does. Show ⌘-click on the sidebar's rows, as a hint or in the context menu. That run still asks
Touch ID once per host, so 5 also depends on task 2's decision about it.

## 5. Quit and relaunch

**Start:** one window with two tabs. The first has a local shell split beside a pane on the host
from task 1; the second has a local shell running `top`.
**Finish:** after quitting and opening the app again, the same tabs, splits and sessions, with a
shell on the host again.

**Termius: not measured yet.** In the Linux container used to measure it, Termius couldn't read
its own encryption key back after relaunching. That came from the container having no real
keychain, so measure it on a Mac.

**Death Race: 0 for the local shells.** Legends Never Die puts back the shells, their
scrollback, the splits, the tabs and the window frames. The ssh pane is gone, and so is its
place in the split, because SSH sessions end with the app. Putting it back takes 4: ⇧⌘P, the
host's name, ⌘Return, Touch ID.

**To reach 0 and 1:** keep the local shells as they are. An ssh pane comes back in its place
saying it's disconnected, with one Reconnect for the window that reconnects every ssh pane in it.
Touch ID would still ask once per host, so 1 depends on task 2's decision about it too.

## Re-measuring

Count again when a task's flow changes, and update this page's tables in the same pull request.
The first count on a Mac replaces a count traced through the code. Write down what was counted
on: the build, and for Termius its version.
