import SwiftUI

/// The 999 mark: rounded black italic, filled with the brand gradient. Once per surface.
public struct Wordmark999: View {
    private let size: CGFloat

    public init(size: CGFloat = 22) {
        self.size = size
    }

    public var body: some View {
        Text(verbatim: "999")
            .font(.system(size: size, weight: .black, design: .rounded).italic())
            .foregroundStyle(
                LinearGradient(
                    colors: [Legends.pink, Legends.violet, Legends.cyan], startPoint: .leading, endPoint: .trailing)
            )
            .shadow(color: .black.opacity(0.35), radius: size / 12, y: size / 22)
            .accessibilityLabel(Text(verbatim: "999"))
    }
}

/// L E G E N D S   N E V E R   D I E: uppercase, wide tracking, muted. Once per surface.
public struct Tagline: View {
    private let text: String

    public init(_ text: String = "Legends never die") {
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(4.2)
            .foregroundStyle(Legends.inkMuted)
    }
}

/// A card whose border runs the brand gradient, with a soft violet glow. It marks the one
/// thing that leads a view: the focused pane, the hero card, the Lucid Dreams panel.
public struct NeonBorder: ViewModifier {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    var glows: Bool

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(Legends.surface))
            .overlay(shape.strokeBorder(Legends.borderGradient, lineWidth: lineWidth))
            .shadow(color: glows ? Legends.glow.opacity(0.35) : .clear, radius: 14)
    }
}

extension View {
    public func neonBorder(cornerRadius: CGFloat = Legends.Radius.hero, lineWidth: CGFloat = 1.5, glows: Bool = true)
        -> some View
    {
        modifier(NeonBorder(cornerRadius: cornerRadius, lineWidth: lineWidth, glows: glows))
    }
}

/// Sparse white specks over the ground, like MenuGlance's panel and icon.
///
/// Static and deterministic: the same seed draws the same sky, and nothing animates, so it
/// costs one draw per size change and no frames at idle.
public struct Starfield: View {
    private let seed: UInt64
    private let density: Double

    /// `density` is specks per 1000×600 points.
    public init(seed: UInt64 = 999, density: Double = 50) {
        self.seed = seed
        self.density = density
    }

    public var body: some View {
        Canvas { context, size in
            var random = SplitMix64(seed: seed)
            let count = Int(density * Double(size.width * size.height) / 600_000)
            for _ in 0..<count {
                let x = random.unit() * size.width
                let y = random.unit() * size.height
                let bright = random.unit() < 0.2
                let diameter: CGFloat = bright ? 2 : 1
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                    with: .color(.white.opacity(bright ? 0.55 : 0.22))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small deterministic generator, so a starfield never reshuffles between draws.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}
