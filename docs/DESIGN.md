# Design

Death Race for Code uses **Legends Never Die**, the visual language it shares with MenuGlance:
a deep indigo night, neon that runs pink → violet → cyan, and a 999 that marks the brand.

- Design system (tokens, components, brand book): https://claude.ai/artifact/SYrFpKuxmKj2m6kTioXe6G
- Hi-fi mockups (12 boards): https://claude.ai/artifact/A7ti39oW56UDr8FyTqguVd

Both are private until shared from their Share menu. In code, the tokens live in
`Packages/DeathRaceKit/Sources/LegendsUI/Legends.swift`.

## Palette (Midnight)

The brand hues are the exact colors of MenuGlance's 999 icon. Every text color holds 4.5:1 on
`ground`, `groundDeep` and `surface`; `lineStrong` holds 3:1 for control borders.

| Token | Hex | Use |
| --- | --- | --- |
| ground | `#160C2E` | windows and panels |
| groundDeep | `#100822` | terminal well, sidebar |
| surface | `#22153F` | raised cards |
| line / lineStrong | `#3A2C63` / `#6E5FA8` | hairlines / control borders |
| ink / inkMuted / inkFaint | `#FFFFFF` / `#C3B5EE` / `#9A8CC8` | primary, labels, tertiary |
| pink → orchid → violet → periwinkle → cyan | `#EC48C4` `#D054D8` `#9870FC` `#80A4FC` `#5CC8FC` | the brand gradient |
| warning / danger | `#FF8A3D` / `#FF5277` | elevated states / failures |
| onAccent | `#1A0C33` | text on pink, cyan or gradient fills |

## Rules

- The gradient fills the hero NeonBorder, stat and progress bars, the active tab pill and the
  999 wordmark. Never body text, never large fills.
- One glow per view: the element that leads (the focused pane, the hero card, the cursor).
- Success is cyan and danger is pink-red; both always come with a word or a ✓ / ✗ glyph.
- Nothing animates at idle. Equalizer bars move only while a tab has output.
- Copy is plain and helpful, like MenuGlance's. The theme lives in names, never in sentences.

## Themes

Eight original themes named after Juice WRLD titles. No lyrics, album art, photos or official
logos ship in the app. `theme = <id or name>` in the settings file picks one, wherever the
line is; `background`, `palette` and the other color settings then change single colors on
top of it.

| Theme | id | Terminal background | Window ground | Neon |
| --- | --- | --- | --- | --- |
| Legends Never Die (default) | `legends-never-die` | `#100822` | `#160C2E` | `#EC48C4` → `#9870FC` → `#5CC8FC` |
| Lucid Dreams | `lucid-dreams` | `#141128` | `#1B1832` | `#FF9AD5` → `#B9A6FF` → `#8FD3FF` |
| Goodbye & Good Riddance | `goodbye-good-riddance` | `#0A0A0C` | `#121214` | `#FFFFFF` → `#B8B8C0` → `#8A8A94` |
| Death Race for Love | `death-race-for-love` | `#14060A` | `#1F080C` | `#FF3D3D` → `#FFB02E` → `#FFE066` |
| Fighting Demons | `fighting-demons` | `#08130E` | `#0C1C16` | `#3DFF8F` → `#59D6B5` → `#9FE870` |
| Wishing Well | `wishing-well` | `#06172A` | `#0B1E34` | `#3FD0FF` → `#7AA8FF` → `#2EE6C5` |
| The Party Never Ends | `the-party-never-ends` | `#12031F` | `#1D0527` | `#FF2FD6` → `#2FF3FF` → `#B6FF3A` |
| Righteous (light) | `righteous` | `#FFFFFF` | `#F9F7FD` | `#B8259B` → `#6440D8` → `#0A6E9E` |

Legends Never Die is exactly the Midnight palette above. The others start from the Themes
board's anchor colors; `scripts/gen-themes.py` mixed the rest and nudged them until every
rule below holds. The hex values live in `ThemeCatalog.swift`, which reads like a design file.

**Contrast, checked on every push** (WCAG, on Linux):

| What | On | At least |
| --- | --- | --- |
| ink, inkMuted, inkFaint | ground, groundDeep, surface, surfaceHover | 4.5:1 |
| onAccent | every gradient and neon stop | 4.5:1 |
| accent | groundDeep and the terminal's background | 4.5:1 |
| lineStrong; danger and warning | the grounds; groundDeep | 3:1 |
| the terminal's text | its background | 7:1 |
| ANSI colors 1–6 and 9–14, with white and bright white (dark themes) or black (light) | the background | 4.5:1 |
| bright black, the dim gray | the background | 3:1 |
| selected text; the character under the cursor | the selection; the cursor | 4.5:1 |
| the cursor | the background | 3:1 |

## Chrome

Each theme carries the window's colors as well as the terminal's (`ChromeColors`):

| Token | Use |
| --- | --- |
| ground | the window behind the panes |
| groundDeep | the title row and the status bar |
| surface, surfaceHover | cards, Hear Me Calling, Settings' rows |
| line, lineStrong | borders; key caps and controls |
| ink, inkMuted, inkFaint | text: primary, secondary, tertiary |
| gradient (5 stops) | the active tab pill, Settings' switches and sliders, a 999 personal best |
| neon (3 stops) | the focused pane's border, the title bar's 999, the equalizer |
| accent | branch names, the palette's highlights |
| glow, glowOpacity | the halo around the focused pane in the key window |
| danger, warning | failed tabs; settings that could not be used; sessions that will not outlive the app |
| armed (warning → danger) | Armed and Dangerous: each armed pane's border, the status bar's warning |
| armedTint | the armed banner's fill: the ground mixed 16% toward each armed stop |

**How it is drawn.**
- AppKit and Core Animation draw the title row, pills, cards and status bar from these
  tokens. SwiftUI windows (Settings, Hear Me Calling's rows) read them as a `LegendsPalette`
  in the environment, so they follow the theme too.
- The NeonBorder is four gradient strips and four corner arcs sampled from one 120° gradient,
  with no mask layers.
- Gradient text (the 999) is drawn once into an image.
- Panes not in use fade 14% toward the ground in the terminal's shader.

Righteous gives the window a light appearance, so menus, sheets and the traffic lights match;
the dark themes use the dark appearance. The starfield (`starfield = true`) belongs to the
night skies, so Righteous has none.

**Pictures of every theme.** `DeathRace --render-chrome DIR` (debug builds) draws the window
in all eight themes without a screen recording permission, and CI keeps them as the
`chrome-preview` artifact.
- The traffic lights and the glow's blur are the window server's, so they are missing.
- The SwiftUI windows (Settings, Hear Me Calling) are left out. Their text doesn't survive
  being drawn this way, so they are reviewed on the Mac.

## Ligatures

`font-ligatures` is off by default. With it on and a font that has them — Monaspace Neon does,
SF Mono does not — a run of punctuation is drawn the way the font draws it together: `!=` joins
into one mark, `->` becomes an arrow, `===` a triple bar. Each character still occupies its own
column, so the ligature is the same width as the characters under it and nothing else on screen
moves.

- Only punctuation joins. Letters are drawn as they always were, side by side.
- A selection edge inside a ligature breaks it: the two characters draw separately so the
  highlight lands on the cell boundary, and they join again when the selection moves off.
- The block cursor shows the character it is on, not the half of a ligature behind it.
- The `--render-chrome` pictures are drawn in Monaspace Neon with ligatures on, so the operators
  in them are the real thing rather than the default font's.

## Conversations

A command and its output, marked on the ordinary grid rather than boxed into a card.

| Part | How |
| --- | --- |
| the rail | one filled bar, `cell.underlineThickness` wide, down the whole block at column 0 |
| the band | the terminal's background mixed toward `surface`, on the block holding the cursor only |
| the badge | right-aligned gradient text on the command's own line, for the ones worth a word |
| the pill's fill | a 3 pt bar along the bottom of a tab pill, clipped to its shape |

**The rail is neutral on success and `danger` only on a failure.** A fast successful command
gets no badge, so a cyan rail would be colour with no word beside it, which the rules above
forbid; and a failure always has a badge, so the ✗ is always there when the danger colour is.
The rail says "this is a command", and how it went is said where there are words.

**The band marks the block you are in, and nothing else.** One band reads as "here"; twenty read
as stripes. It is mixed into the background cell by cell, keeping each cell's own top byte, so
the starfield survives underneath it — a constant write would have put out every star it covered,
and a hand-packed byte would have made a tinted cell starry.

**A badge appears only when there is something to say:** over
`fast-threshold-milliseconds` (1000 by default), or on any failure however quick. A new personal
best draws its text through the five-stop gradient and flashes once, on the event — nothing
animates at idle. The words are `docs/NAMING.md`'s.

**The pill's fill is under the title, not behind it.** A half-tinted pill is hard to read, and
this has to be legible at a glance from across a tab row. It takes the gradient, or `danger`
when the program reported trouble, and a program working without saying how far fills the whole
bar rather than none of it — an empty bar reads as nothing happening.

With `conversations = false` there is no rail, no band, no badge and nothing to click: the
terminal is byte-for-byte what it was, which is also what keeps the existing frame goldens valid.

## Lucid Dreams

The quick terminal drops out of the notch and settles just below the menu bar.

- **Where.** Centred under the notch on the screen that holds the pointer, or top-centre on a
  display without a notch, hung a few points below the menu bar. The math is `NotchPlacement`
  (AppCore), so it is checked on Linux; the notch rectangle comes from the screen's
  `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`.
- **The panel.** One `PaneCardView` — the same card the Pit Lane draws — lit with the focused
  pane's NeonBorder, its surface inset by `Chrome.cardInset`, in a borderless panel on a clear
  background (the card draws its own glow). A 90 × 20 grid: wide enough for a command, short
  enough to read as a drop-in.
- **The motion.** On show it springs down from the notch and fades in over about 0.18 s
  (`easeOut`); on hide it lifts back and fades out over about 0.14 s, then `orderOut`. Nothing
  animates once it is at rest.
- **Secure Keyboard Entry.** The panel is non-activating, so summoning it doesn't switch apps —
  and Secure Keyboard Entry, which engages on `NSApp.isActive`, stays off on the quick terminal
  until you click into Death Race. This is the chosen trade-off, drop-in over always-secure,
  stated plainly rather than worked around.

(The `lucid-dreams` row in the Themes table is the colour theme of that name — a different
thing from this feature.)

## WRLD and Armed and Dangerous

**The sidebar** (⌃⌘S) is AppKit drawing from `SidebarModel`, so it follows the theme and
shows in the CI pictures.
- 220 pt wide, from under the title row to the window's bottom, on `groundDeep` with a
  1 px `line` at its edge. The status bar starts beside it, as on the Main board.
- Search WRLD at the top (a 30 pt rounded field on `ground`), then the sections, each under
  a 24 pt eyebrow, in 28 pt rows with 12 pt margins: Legends, WRLD's groups and loose hosts
  (a group's hosts indent 14 pt), Wishing Well, Come & Go. Add host and the spaced-out
  tagline sit in a 76 pt footer.
- A row leads with its mark (a host's dot, a group's chevron, Wishing Well's », Come & Go's
  ⇄) and ends with its meta (latency, a count) or, for a tunnel, its dot. A snippet's
  placeholders follow its name as small chips while they fit. Hover is a `surface` fill.

**Host dots**, the same in the sidebar and the WRLD window:

| Dot | Means |
| --- | --- |
| `accent`, filled (glowing in the window) | connected now |
| `accent`, a little faded | answered its last check |
| `inkFaint`, filled; the name in `inkMuted` | didn't answer its last check |
| a `lineStrong` ring | not connected now, and not checked (only Legends are) |

**The WRLD window** (⌘O) is SwiftUI on the theme's `LegendsPalette`, 1,120 × 720 pt to
start: the list on the left, host cards in the middle and, for the host you pick, a 330 pt
inspector on the right. Its buttons come in four kinds: primary (on the gradient), plain (on
`surface`), ghost (text alone) and destructive (`danger` text on `surface`).

**Armed and Dangerous** swaps the focused pane's neon for the armed stops on *every* armed
pane, so the tab can't be mistaken for an ordinary one:
- the banner across the tab, on `armedTint`, names where typing goes and how to stop;
- each armed pane's header says "receiving input", with a toggle to leave it out;
- armed panes aren't dimmed, since typing reaches them all;
- the pill names the hosts ("prod-api × 3") and the status bar leads with a `warning` run.

The contrast tests cover it in every theme: the armed stops at 3:1 on the ground and the
terminal's background, `ink` and `inkMuted` at 4.5:1 on both tints, and `warning` at 4.5:1
on `groundDeep`.

## Maze

One window per host, 980 × 620 pt to start, on the theme's `LegendsPalette`. It is three
bands on `ground`, divided by 1 px `line`:

- **The title row**, 46 pt: `MAZE` as a spaced-out eyebrow in `inkMuted`, a `·`, then the
  host's name in `ink`; a small spinner while a listing is on its way, and, on the right,
  whatever went wrong last in `danger`, one line.
- **The two panes**, side by side and equal, divided by a 1 px `line`. Each has a 24 pt
  header — `THIS MAC` or the host's name as an eyebrow, with Up on the right in `accent`
  (off at `/`) — the folder's path under it in `inkFaint`, truncated at the head so the end
  you care about stays; then the rows on `groundDeep`; then a 34 pt footer with the
  transfer button (`Upload →` on the left, `← Download` on the right, off until a row is
  picked) and the row count.
- **A row**, 24 pt: a folder, link or doc symbol in `accent` for a folder and `inkFaint`
  otherwise, the name in `ink`, and for a file its size with its unit on the right in
  `inkFaint`. The picked row is filled `surfaceHover`.
- **The transfers**, along the bottom on `groundDeep`: a `TRANSFERS` eyebrow with Clear on
  the right once a row has finished, then a row per transfer — the direction's arrow in
  `accent`, the file's name, how far it has got ("4.2 MB of 48 MB", "done", "cancelled", or
  why it failed, in `danger`), and Stop while it's going — each over a **`TransferBar`**:
  `NeonSlider`'s fill without the knob or the drag, a 4 pt capsule of `surfaceHover` under
  the brand gradient's share of the width. Before the first transfer the band reads "Pick a
  file and press Upload or Download."; the band itself scrolls at 108 pt.

**Drags.** A file row can be dragged to the other pane — this Mac's as its file URL, the
host's as its path — and Finder files dropped on the host's pane upload. A folder dropped
there is set aside with "Maze moves files, not folders.": Maze moves files this phase.
Dragging a file *out* of Maze into Finder is not in this phase.
