#!/usr/bin/env python3
"""Derives the eight themes' full palettes from the mockup's anchor colors.

Each theme starts from the anchors on the Themes board (background, foreground, five
accents, red) and a tint for its chrome. Everything else is mixed from those, then nudged
until it meets the contrast rules ThemeCatalogTests checks (WCAG 2 contrast ratios):

    ink, inkMuted, inkFaint     >= 4.5 on ground, groundDeep, surface, surfaceHover
    onAccent                    >= 4.5 on every gradient and neon stop
    lineStrong                  >= 3   on ground and groundDeep
    accent                      >= 4.5 on groundDeep and on the background
    danger, warning             >= 3   on groundDeep
    foreground                  >= 7   on the background, >= 4.5 on the selection
    cursor                      >= 3   on the background; the background >= 4.5 on it
    ANSI 1-6 and 9-14           >= 4.5 on the background, as are 7 and 15 on dark themes
                                       and 0 on light ones; ANSI 8 >= 3

The output is Swift for Sources/ConfigKit/ThemeCatalog.swift. The values there are the
source of truth; run this again only to change a theme, and review the diff.

    python3 scripts/gen-themes.py > /tmp/themes.swift
"""

WHITE = (255, 255, 255)
BLACK = (0, 0, 0)


def rgb(hex_string):
    value = int(hex_string.lstrip("#"), 16)
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)


def mix(a, b, t):
    """`a` moved `t` of the way toward `b`, in sRGB as CSS does."""
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def channel(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(color):
    r, g, b = (channel(c) for c in color)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def nudge(color, backgrounds, minimum, toward):
    """Moves `color` toward `toward` in small steps until it holds `minimum` on every
    background."""
    step = 0
    current = color
    while min(contrast(current, b) for b in backgrounds) < minimum:
        step += 1
        if step > 100:
            raise SystemExit(f"cannot reach {minimum}:1 for {color}")
        current = mix(color, toward, step / 100)
    return current


def hex6(color):
    return "0x%02X%02X%02X" % color


# The Themes board's anchors: background, foreground, accents c1-c5, red, glow (rgba),
# plus the chrome's tint and the ANSI slots each theme fills from its own accents.
THEMES = [
    dict(id="legends-never-die", name="Legends Never Die",
         bg="#100822", fg="#ede7ff", c1="#ec48c4", c2="#9870fc", c3="#5cc8fc", c4="#4fe3a9",
         c5="#ffc45c", red="#ff5277", glow=("#9d63ff", 0.35), tint="c2"),
    dict(id="lucid-dreams", name="Lucid Dreams",
         bg="#141128", fg="#ece8ff", c1="#ff9ad5", c2="#b9a6ff", c3="#8fd3ff", c4="#9ff2d0",
         c5="#ffe29a", red="#ff8fa3", glow=("#b9a6ff", 0.35), tint="c2"),
    dict(id="goodbye-good-riddance", name="Goodbye & Good Riddance",
         bg="#0a0a0c", fg="#f2f2f4", c1="#ffffff", c2="#b8b8c0", c3="#8a8a94", c4="#d6d6dc",
         c5="#9e9ea8", red="#ff3b4f", glow=("#ffffff", 0.12), tint="c2"),
    dict(id="death-race-for-love", name="Death Race for Love",
         bg="#14060a", fg="#ffeee8", c1="#ff3d3d", c2="#ffb02e", c3="#4da3ff", c4="#7cf29a",
         c5="#ffe066", red="#ff3d3d", glow=("#ff3d3d", 0.30), tint="c1",
         # Red to orange to blue would pass through grey: the gradient burns red to gold,
         # and the theme's blue and a teal fill the cool ANSI slots.
         gradient=["#ff3d3d", "#ff7735", "#ffb02e", "#ffc84a", "#ffe066"],
         neon=["#ff3d3d", "#ffb02e", "#ffe066"], accent="c2",
         ansi={"blue": "#4da3ff", "magenta": "#ff5fa8", "cyan": "#64cacc"}),
    dict(id="fighting-demons", name="Fighting Demons",
         bg="#08130e", fg="#def5e8", c1="#3dff8f", c2="#59d6b5", c3="#9fe870", c4="#59d6b5",
         c5="#e8d36a", red="#ff4060", glow=("#3dff8f", 0.25), tint="c2",
         ansi={"green": "#3dff8f", "blue": "#6fb7e8", "magenta": "#e07bc8", "cyan": "#59d6b5"}),
    dict(id="wishing-well", name="Wishing Well",
         bg="#06172a", fg="#e1f1ff", c1="#3fd0ff", c2="#7aa8ff", c3="#2ee6c5", c4="#b8f0ff",
         c5="#ffcf5c", red="#ff6b81", glow=("#3fd0ff", 0.30), tint="c2",
         ansi={"green": "#2ee6c5", "blue": "#7aa8ff", "magenta": "#d98cff", "cyan": "#3fd0ff"},
         bright={"cyan": "#b8f0ff"}),
    dict(id="the-party-never-ends", name="The Party Never Ends",
         bg="#12031f", fg="#fff2ff", c1="#ff2fd6", c2="#2ff3ff", c3="#b6ff3a", c4="#ff8a1f",
         c5="#ffe14d", red="#ff3f6e", glow=("#ff2fd6", 0.35), tint="c1",
         ansi={"green": "#b6ff3a", "blue": "#6f8bff", "magenta": "#ff2fd6", "cyan": "#2ff3ff"},
         warning="#ff8a1f"),
    dict(id="righteous", name="Righteous", light=True,
         bg="#ffffff", fg="#2b1f4d", c1="#b8259b", c2="#6440d8", c3="#0a6e9e", c4="#0b7552",
         c5="#8a5600", red="#be1f45", glow=("#6440d8", 0.25), tint="c2"),
]

# Legends Never Die is the design system's Midnight theme: its chrome and palette are
# exactly the tokens LegendsUI and Palette.legendsNeverDie already use.
LEGENDS_CHROME = dict(
    ground="#160c2e", groundDeep="#100822", surface="#22153f", surfaceHover="#2c1d4f",
    line="#3a2c63", lineStrong="#6e5fa8", ink="#ffffff", inkMuted="#c3b5ee", inkFaint="#9a8cc8",
    gradient=["#ec48c4", "#d054d8", "#9870fc", "#80a4fc", "#5cc8fc"],
    neon=["#ec48c4", "#9870fc", "#5cc8fc"], onAccent="#1a0c33", accent="#5cc8fc",
    danger="#ff5277", warning="#ff8a3d")
LEGENDS_ANSI = ["#3a2b6a", "#ff5277", "#4fe3a9", "#ffc45c", "#80a4fc", "#ec48c4", "#5cc8fc", "#c3b5ee",
                "#7b6bb0", "#ff7d99", "#86f0c8", "#ffd98a", "#a9c1ff", "#f37fd8", "#97ddff", "#ffffff"]
LEGENDS_SELECTION = "#463279"


def derive(theme):
    light = theme.get("light", False)
    bg, fg = rgb(theme["bg"]), rgb(theme["fg"])
    c = {k: rgb(theme[k]) for k in ("c1", "c2", "c3", "c4", "c5")}
    red = rgb(theme["red"])
    tint = c[theme["tint"]]
    away = WHITE if not light else BLACK  # the direction that raises contrast
    out = {}

    if theme["id"] == "legends-never-die":
        chrome = {k: (rgb(v) if isinstance(v, str) else [rgb(x) for x in v]) for k, v in LEGENDS_CHROME.items()}
        ansi = [rgb(x) for x in LEGENDS_ANSI]
        selection = rgb(LEGENDS_SELECTION)
    elif not light:
        gradient = [rgb(x) for x in theme["gradient"]] if "gradient" in theme else [
            c["c1"], mix(c["c1"], c["c2"], 0.5), c["c2"], mix(c["c2"], c["c3"], 0.5), c["c3"]]
        neon = [rgb(x) for x in theme["neon"]] if "neon" in theme else [c["c1"], c["c2"], c["c3"]]
        chrome = dict(
            groundDeep=bg, ground=mix(bg, tint, 0.045), surface=mix(bg, tint, 0.13),
            surfaceHover=mix(bg, tint, 0.205), line=mix(bg, tint, 0.30),
            lineStrong=mix(mix(bg, tint, 0.55), fg, 0.1), ink=WHITE,
            inkMuted=mix(mix(fg, tint, 0.3), bg, 0.1), inkFaint=mix(mix(fg, tint, 0.3), bg, 0.3),
            gradient=gradient, neon=neon, onAccent=mix(bg, tint, 0.06), accent=c[theme.get("accent", "c3")],
            danger=red, warning=rgb(theme.get("warning", "#ff8a3d")))
        slots = theme.get("ansi", {})
        base = [
            red,
            rgb(slots["green"]) if "green" in slots else c["c4"],
            c["c5"],
            rgb(slots["blue"]) if "blue" in slots else mix(c["c2"], c["c3"], 0.5),
            rgb(slots["magenta"]) if "magenta" in slots else c["c1"],
            rgb(slots["cyan"]) if "cyan" in slots else c["c3"],
        ]
        brights = [mix(x, WHITE, 0.3) for x in base]
        for slot, color in theme.get("bright", {}).items():
            brights[["red", "green", "yellow", "blue", "magenta", "cyan"].index(slot)] = rgb(color)
        ansi = ([mix(bg, tint, 0.3)] + base + [chrome["inkMuted"]]
                + [mix(bg, mix(tint, fg, 0.5), 0.6)] + brights + [WHITE])
        selection = mix(bg, tint, 0.4)
    else:
        gradient = [c["c1"], mix(c["c1"], c["c2"], 0.5), c["c2"], mix(c["c2"], c["c3"], 0.5), c["c3"]]
        chrome = dict(
            groundDeep=mix(bg, tint, 0.07), ground=mix(bg, tint, 0.04), surface=bg,
            surfaceHover=mix(bg, tint, 0.10), line=mix(bg, tint, 0.2), lineStrong=mix(bg, tint, 0.75),
            ink=mix(fg, BLACK, 0.3), inkMuted=mix(fg, tint, 0.25), inkFaint=mix(fg, bg, 0.28),
            gradient=gradient, neon=[c["c1"], c["c2"], c["c3"]], onAccent=WHITE, accent=c["c3"],
            danger=red, warning=rgb("#b54a00"))
        base = [red, c["c4"], c["c5"], mix(c["c2"], c["c3"], 0.5), c["c1"], c["c3"]]
        ansi = ([fg] + base + [mix(bg, mix(fg, tint, 0.5), 0.2)]
                + [mix(fg, bg, 0.45)] + [mix(x, WHITE, 0.12) for x in base] + [WHITE])
        selection = mix(bg, tint, 0.2)

    # Nudge what falls short; Legends Never Die passes as it is.
    grounds = [chrome[k] for k in ("ground", "groundDeep", "surface", "surfaceHover")]
    for key in ("ink", "inkMuted", "inkFaint"):
        chrome[key] = nudge(chrome[key], grounds, 4.5, away)
    chrome["onAccent"] = nudge(chrome["onAccent"], chrome["gradient"] + chrome["neon"], 4.5,
                               BLACK if not light else WHITE)
    chrome["lineStrong"] = nudge(chrome["lineStrong"], [chrome["ground"], chrome["groundDeep"]], 3, away)
    chrome["accent"] = nudge(chrome["accent"], [chrome["groundDeep"], bg], 4.5, away)
    chrome["danger"] = nudge(chrome["danger"], [chrome["groundDeep"]], 3, away)
    chrome["warning"] = nudge(chrome["warning"], [chrome["groundDeep"]], 3, away)
    fg = nudge(fg, [bg], 7, away)
    strict = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] + ([7, 15] if not light else [0])
    for index in strict:
        ansi[index] = nudge(ansi[index], [bg], 4.5, away)
    ansi[8] = nudge(ansi[8], [bg], 3, away)
    selection_fixed = selection
    if contrast(fg, selection) < 4.5:
        selection_fixed = nudge(selection, [fg], 4.5, bg)
    cursor = nudge(c["c1"], [bg], 3, away)
    assert contrast(bg, cursor) >= 4.5 or contrast(WHITE if not light else BLACK, cursor) >= 4.5

    out.update(id=theme["id"], name=theme["name"], light=light, bg=bg, fg=fg, ansi=ansi,
               cursor=cursor, selection=selection_fixed, chrome=chrome,
               glow=(rgb(theme["glow"][0]), theme["glow"][1]))
    return out


def swift(t):
    ch = t["chrome"]
    lines = []
    lines.append(f"    static let {camel(t['id'])} = NamedTheme(")
    lines.append(f"        id: \"{t['id']}\", name: \"{t['name']}\", isLight: {str(t['light']).lower()},")
    lines.append(f"        terminal: Theme(")
    lines.append(f"            palette: Palette.themed(")
    ansi = t["ansi"]
    lines.append("                system: [")
    lines.append("                    " + ", ".join(hex6(x) for x in ansi[:8]) + ",")
    lines.append("                    " + ", ".join(hex6(x) for x in ansi[8:]) + ",")
    lines.append("                ],")
    lines.append(f"                foreground: {hex6(t['fg'])}, background: {hex6(t['bg'])}, cursor: {hex6(t['cursor'])}),")
    lines.append(f"            selectionBackground: RGB(hex: {hex6(t['selection'])})),")
    lines.append("        chrome: ChromeColors(")
    for key in ("ground", "groundDeep", "surface", "surfaceHover", "line", "lineStrong",
                "ink", "inkMuted", "inkFaint"):
        lines.append(f"            {key}: {hex6(ch[key])},")
    lines.append("            gradient: [" + ", ".join(hex6(x) for x in ch["gradient"]) + "],")
    lines.append("            neon: [" + ", ".join(hex6(x) for x in ch["neon"]) + "],")
    lines.append(f"            onAccent: {hex6(ch['onAccent'])}, accent: {hex6(ch['accent'])},")
    lines.append(f"            glow: {hex6(t['glow'][0])}, glowOpacity: {t['glow'][1]},")
    lines.append(f"            danger: {hex6(ch['danger'])}, warning: {hex6(ch['warning'])}))")
    return "\n".join(lines)


def camel(identifier):
    head, *rest = identifier.split("-")
    return head + "".join(part.capitalize() for part in rest)


def main():
    derived = [derive(t) for t in THEMES]
    print("\n\n".join(swift(t) for t in derived))


if __name__ == "__main__":
    main()
