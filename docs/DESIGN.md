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

Eight original terminal palettes named after Juice WRLD titles: Legends Never Die (default),
Lucid Dreams, Goodbye & Good Riddance, Death Race for Love, Fighting Demons, Wishing Well,
The Party Never Ends and Righteous (light). Each holds at least 4.5:1 for every text color on
its own background. No lyrics, album art, photos or official logos ship in the app.
