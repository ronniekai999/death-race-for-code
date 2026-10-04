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
| gradient (5 stops) | the active tab pill, Settings' switches and sliders |
| neon (3 stops) | the focused pane's border, the 999, the equalizer |
| accent | branch names, the palette's highlights |
| glow, glowOpacity | the halo around the focused pane in the key window |
| danger, warning | failed tabs; settings that could not be used |
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
