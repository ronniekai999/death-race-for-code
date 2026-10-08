import VTCore

/// The light a bright-coloured character throws around itself: bright red glows red, cyan glows
/// cyan, and ordinary output never glows at all.
///
/// One frame-global parameter, the shape `Dimming` already set. **Which** characters emit is
/// decided per glyph in the shader from the glyph's own colour, so nothing about this reaches
/// `Frame`, `GlyphInstance` or the row cache — this carries only how strong the effect may be,
/// which is a theme's business and an energy policy's.
public struct Glow: Equatable, Sendable {
    /// Reserved for XDR Neon's tint, and ignored today: the shaders take each glyph's own
    /// colour. It is here so the uniform word has somewhere to put the tint XDR will need
    /// without widening `Uniforms` a second time.
    public var tint: RGB
    /// 0 draws nothing; 1 is as bright as the kernel goes. Per theme, from
    /// `ChromeColors.glowOpacity`.
    public var strength: Double

    public init(strength: Double, tint: RGB = RGB(0, 0, 0)) {
        self.strength = strength
        self.tint = tint
    }

    /// No glow at all.
    public static let none = Glow(strength: 0)

    /// As the shaders' `Uniforms.glow` holds it: the tint, with the strength in the alpha byte.
    ///
    /// A strength that rounds to zero packs to **exactly 0**, whatever the tint, so "off" is one
    /// value rather than a family of them. The renderer skips the glow draw on `glow == 0`, which
    /// is what makes a frame drawn with the parameter left out bit-identical to one drawn with
    /// `Glow.none`.
    public var packed: PackedColor {
        // `isFinite` first, because the clamp alone is not total: Swift's `min` and `max`
        // propagate NaN (`0 >= .nan` is false), and `UInt32(Double.nan.rounded())` traps rather
        // than clamping. Nothing reaches it today — strengths come from the themes' literals —
        // but `init(strength:)` is public and this is read on every frame-settling path.
        let clamped = strength.isFinite ? min(max(strength, 0), 1) : 0
        let alpha = UInt32((clamped * 255).rounded())
        guard alpha > 0 else { return 0 }
        return UInt32(tint.red) | UInt32(tint.green) << 8 | UInt32(tint.blue) << 16 | alpha << 24
    }

    /// Nothing will be drawn for this glow.
    public var isOff: Bool { packed == 0 }

    /// Chroma at or below this never glows; at or above `chromaFull` it glows fully.
    ///
    /// **Provisional.** These four numbers are the one part of the feature only a calibrated
    /// display can judge, and CI's GPU is paravirtual. `GlowTests` records what they do to all
    /// eight themes' palettes, so a retune is a number here plus the same number in
    /// `Shaders.source`, with the table saying what moved.
    public static let chromaFloor = 0.28
    public static let chromaFull = 0.44
    /// A brightness floor, and the only thing brightness is used for: it keeps ANSI black out
    /// (luma 0.16–0.27 across the themes) without making brightness the rule.
    public static let lumaFloor = 0.30
    public static let lumaFull = 0.45

    /// How much of the glow a glyph in this colour throws: 0 for body text and the greys, 1 for
    /// a saturated colour, and something faint in between for one on the edge.
    ///
    /// **Chroma decides, not brightness.** On a dark ground the default foreground is the
    /// brightest thing on the screen — luma 0.92 to 0.97 across the seven dark themes — so a
    /// brightness rule would glow every line of ordinary output. Saturation is what separates a
    /// colour a program *chose*: the themes' reds, greens, yellows, blues, magentas and cyans sit
    /// at chroma 0.33 to 0.82, against a default foreground's 0.01 to 0.12 and white's 0.00.
    ///
    /// A pair of `smoothstep`s rather than two thresholds, because no pair of numbers classifies
    /// 128 palette entries correctly: the greys reach chroma 0.27 and a pastel bright magenta
    /// starts at 0.275, so the bands genuinely overlap. A colour in the overlap glows *faintly*
    /// instead of being miscategorised loudly, which turns a correctness problem into a taste one
    /// — and the greys keep the benefit of the doubt, because an ordinary `ESC[37m` line glowing
    /// is a worse mistake than a pastel magenta not glowing.
    ///
    /// **This is the twin of `emissive()` in `Shaders.source`, and nothing can prove they agree,
    /// because one of them is a string.** Both read the sRGB bytes as plain numbers without
    /// linearizing — the shaders unpack the same bytes the same way — both use the four
    /// thresholds above, and `GlowTests`' per-theme table is what a retune has to update. Change
    /// one, change the other.
    public static func emissiveStrength(of color: RGB) -> Double {
        let red = Double(color.red) / 255
        let green = Double(color.green) / 255
        let blue = Double(color.blue) / 255
        let chroma = max(red, max(green, blue)) - min(red, min(green, blue))
        let luma = 0.299 * red + 0.587 * green + 0.114 * blue
        return smoothstep(chromaFloor, chromaFull, chroma) * smoothstep(lumaFloor, lumaFull, luma)
    }

    /// Metal's `smoothstep`, written out so the twin above can be read line for line against the
    /// shader's.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
