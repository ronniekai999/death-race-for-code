import AppKit
import ConfigKit
import CoreText
import TerminalUI
import VTCore

/// The window's look for the current theme: its colors as AppKit wants them, and what is
/// drawn once from them (the 999).
@MainActor
struct Chrome {
    let theme: NamedTheme
    let colors: ChromeColors

    init(_ theme: NamedTheme) {
        self.theme = theme
        colors = theme.chrome
    }

    var appearance: NSAppearance? {
        NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
    }

    /// The terminal's default background, which pane cards are filled with.
    var terminalBackground: RGB { theme.terminal.palette.background }

    /// The 999 in the theme's neon, rendered once at `scale`.
    func wordmark(size: CGFloat, scale: CGFloat) -> CGImage? {
        GradientText.render("999", font: GradientText.wordmarkFont(size: size), colors: colors.neon, scale: scale)
    }

    // MARK: - Metrics (the mockup's, in points)

    static let titleRowHeight: CGFloat = 46
    static let statusBarHeight: CGFloat = 30
    /// Around the panes, and between them.
    static let paneMargin: CGFloat = 14
    static let paneGap: CGFloat = 12
    static let cardRadius: CGFloat = 12
    /// The terminal view sits this far inside its card, clear of the rounded corners, so
    /// nothing has to be masked.
    static let cardInset: CGFloat = 4
    static let neonWidth: CGFloat = 1.5
    static let glowRadius: CGFloat = 14
}

/// Text filled with a gradient, drawn once into an image: cheaper than a gradient layer
/// masked by text, and it shows up in snapshots.
enum GradientText {
    /// SF Pro Rounded, black, slanted 12° as SwiftUI's `.italic()` slants it.
    static func wordmarkFont(size: CGFloat) -> CTFont {
        let system = NSFont.systemFont(ofSize: size, weight: .black)
        let rounded =
            system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        var slant = CGAffineTransform(a: 1, b: 0, c: 0.2126, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(rounded as CTFont, size, &slant, nil)
    }

    static func render(_ text: String, font: CTFont, colors: [RGB], scale: CGFloat) -> CGImage? {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let margin: CGFloat = 2
        let width = Int(((bounds.width + margin * 2) * scale).rounded(.up))
        let height = Int(((bounds.height + margin * 2) * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: margin - bounds.minX, y: margin - bounds.minY)
        context.setTextDrawingMode(.clip)
        CTLineDraw(line, context)
        guard
            let gradient = CGGradient(
                colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil)
        else { return nil }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: margin, y: 0), end: CGPoint(x: margin + bounds.width, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return context.makeImage()
    }
}

/// A linear gradient's colors at any point along it: the NeonBorder samples its edges from
/// one gradient across the whole card.
struct GradientRamp {
    let stops: [RGB]

    /// The color `t` of the way along, 0 to 1.
    func color(at t: Double) -> RGB {
        guard stops.count > 1 else { return stops.first ?? RGB(0, 0, 0) }
        let position = min(max(t, 0), 1) * Double(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        return stops[index].mixed(with: stops[index + 1], by: position - Double(index))
    }
}
