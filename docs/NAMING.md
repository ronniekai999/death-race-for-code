# Naming

User-facing features carry Juice WRLD titles; the sentences around them stay literal. Code
modules keep descriptive names, except where a themed name stays clear (`LegendsUI`,
`LucidDreams`, `legendsd`).

| Feature | Name in the app | Example copy |
| --- | --- | --- |
| Host sidebar and vault | WRLD | "Add a host to WRLD to connect with one click." |
| Pinned hosts | Legends | "Pin a host to keep it in Legends." |
| Snippets | Wishing Well | "Save a command to Wishing Well to run it again." |
| Port forwards | Come & Go | "Forward 5432 to db through prod-api." |
| SFTP browser | Maze | "Drop files here to upload them to prod-api." |
| Broadcast input | Armed and Dangerous | "Typing goes to 3 panes: prod-api-1, prod-api-2 and prod-api-3." Stop is ⇧⌘I or the banner's button, never Esc, which belongs to the programs. |
| Command palette (⇧⌘P) | Hear Me Calling | "Search hosts, snippets and commands." |
| Notch quick terminal | Lucid Dreams | "Press ⌥Space to open Lucid Dreams." |
| Session persistence | Legends Never Die | "3 sessions kept running while the app was closed." |
| Command + output blocks | Conversations | |
| Command duration | Fast | "Fast 12.4s · 3.1s faster than your best" |
| Failed / passed command | Bad Energy / Righteous | "Exited with status 1" beside ✗; "Done" beside ✓ |
| Command finished alert | Ring Ring | "swift build finished in 12.4s." |
| Close confirmation | Goodbye & Good Riddance? | "2 sessions are still running. Close anyway?" |
| Max-effects preset | The Party Never Ends | |
| Joined operators | Ligatures, with no title of its own | "Draws runs like != and => the way the font draws them together." Say runs, or operators, never "texture healing": the font's `calt` does shape some punctuation pairs for their neighbours, but letters are drawn exactly as they were, which is what people mean by the phrase. |

Secure Keyboard Entry has no themed name, and its copy stays literal. On the Lucid Dreams
panel it is off until you click into the app (the panel is non-activating), so nothing there
claims the keyboard is secured.

Maze's copy says what it did and what it didn't: "notes.md is already there. Replace it?"
before a transfer overwrites, "Maze moves files, not folders." for a dropped folder, and a
failed transfer carries the server's own reason on its row ("Permission denied") rather than
a code. Sizes get their unit, as every number does: "4.2 MB of 48 MB".

Legends Never Die's copy never promises what is not happening. The setting reads "Keep local
shells running when Death Race quits", with "They go back in their windows next time. Sessions
on a host are not kept." under it — because a session on a host cannot be kept, and the words
have to say so rather than letting someone find out at quit. When the daemon was asked for and
could not be had, the status bar says "Sessions end with the app", in the warning colour, and
a click opens Settings at the Sessions group; the reason itself is a sentence in the log, not
in the bar, where it would not fit and could not be read. The one line that counts is counted
properly: "1 session kept running while the app was closed." and "3 sessions kept running
while the app was closed."

Quitting asks only about what is actually ending. A window of local shells quits without a
word, because nothing in it is going; a tunnel, an ssh pane or a transfer still asks. Closing
is the opposite and says so: closing a pane, a tab or a window ends its shell, and the
question is "Goodbye & Good Riddance?" as it always was.

Conversations tells you how long a command took, and only when that is worth a sentence. A
duration carries its unit and loses precision as it grows, because nobody reads the tenths of an
hour: `4ms` under a second, `12.4s` to one decimal under a minute, then `10m 00s` and `2h 05m`
with the smaller field padded. Over the threshold, or failed, a command earns words: "Fast 12.4s
✓", "Fast 12.4s · 3.1s faster than your best ✓", "Fast 4ms · exited with status 2 ✗" — the
clauses joined by a middle dot, the second one lower-case because it is not first, and the ✓ or
✗ always there, since `docs/DESIGN.md` does not let a colour arrive without a word or a glyph.
**Only a win is said.** "4.0s slower than your best" is a thing nobody asked to be told.

Ring Ring names the command and says what became of it: "swift build" over "Finished in 10m
00s", or "Exited with status 2 after 4ms". A command whose text never arrived is "A command"
rather than an empty banner. The status bar's health count appears only when the panes disagree
— "2 of 3 healthy" — because "1 of 1 healthy" is a sentence about nothing.

**A command hidden from the shell's history is hidden everywhere.** A leading space keeps it out
of `~/.zsh_history`, and it also keeps it out of the bests file, out of any notification, and off
the screen — a banner sits where anyone nearby can read it. The help for `bests-on-disk` says
where the file is, so it can be deleted.

Under bash that promise is kept by **reporting no command text at all**, not by passing the space
along: `$BASH_COMMAND` is rebuilt from the parsed command and has no leading whitespace, so a
line the shell was asked to hide would have arrived looking ordinary. The mark, the duration and
the exit code still come, so the rail and the badge work; it is only the words that are withheld,
and an unnamed command reads as "A command".

A notification a **program** asked for is shown under the pane's name rather than as Death Race's
own: those words came off the same stream as everything else on screen, and a banner that
appears while you are looking elsewhere should say plainly whose voice it is.

Never quote lyrics, use slang, or add emoji to interface copy. Use sentence case, and give
every number a unit.
