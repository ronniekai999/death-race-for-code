import ConfigKit
import ScreenProtocol
import VTCore

/// A glyph source that places every glyph without rasterizing it: for building frames where
/// only their colors and positions matter (`vthost frame`, the frame goldens).
public final class PlaceholderGlyphs: GlyphSource {
    public let epoch: UInt64 = 0

    public init() {}

    public func placement(for key: GlyphKey) -> GlyphPlacement? {
        GlyphPlacement(
            atlas: .mask, x: 0, y: 0, width: key.isWide ? 2 : 1, height: 1, offsetX: 0, offsetY: 0, shelf: 0)
    }

    public func markUsed(shelves: [UInt16]) {}
}

extension Frame {
    /// The frame as color runs, the form the frame goldens hold: per row, the runs of
    /// background colors, then the colors glyphs are drawn in, then the decorations. Rows
    /// with nothing but the default colors are left out. Columns count from 1.
    ///
    ///     size 80x24 · clear #100822
    ///     3: bg 1-11 #3A2B6A 12-80 #100822 · fg 1-3 #FF5277 5-9 #EDE7FF · underline 5-9 #EDE7FF
    public func summary(defaultForeground: RGB, defaultBackground: RGB) -> String {
        var out = "size \(columns)x\(rows) · clear \(hex(clearColor))\n"
        var glyphsByRow: [[GlyphInstance]] = Array(repeating: [], count: rows)
        for glyph in glyphs where Int(glyph.cellY) < rows { glyphsByRow[Int(glyph.cellY)].append(glyph) }
        var decorationsByRow: [[DecorationInstance]] = Array(repeating: [], count: rows)
        for decoration in decorations where Int(decoration.cellY) < rows {
            decorationsByRow[Int(decoration.cellY)].append(decoration)
        }
        for y in 0..<rows {
            let backgrounds = Array(self.backgrounds[(y * columns)..<((y + 1) * columns)])
            let glyphColors = glyphsByRow[y].map { (Int($0.cellX), $0.color) }
            let plainBackground = backgrounds.allSatisfy { $0 == defaultBackground.packed }
            let plainForeground = glyphColors.allSatisfy { $0.1 == defaultForeground.packed }
            guard !(plainBackground && plainForeground && decorationsByRow[y].isEmpty) else { continue }

            var parts: [String] = []
            parts.append("bg " + runs(backgrounds.enumerated().map { ($0.offset, $0.element) }))
            if !glyphColors.isEmpty { parts.append("fg " + runs(glyphColors)) }
            for decoration in decorationsByRow[y] {
                let first = Int(decoration.cellX) + 1
                let last = Int(decoration.cellX) + Int(decoration.cellCount)
                let span = first == last ? "\(first)" : "\(first)-\(last)"
                parts.append("\(Self.decorationName(decoration.kind)) \(span) \(hex(decoration.color))")
            }
            out += "\(y + 1): " + parts.joined(separator: " · ") + "\n"
        }
        return out
    }

    /// The frame as text with 24-bit color escapes, to look at in a terminal: each cell's
    /// background, and the mirror's character in its glyph's color.
    public func ansi(text mirror: MirrorGrid) -> String {
        var glyphColor: [Int: PackedColor] = [:]
        for glyph in glyphs { glyphColor[Int(glyph.cellY) * columns + Int(glyph.cellX)] = glyph.color }
        var out = ""
        for y in 0..<min(rows, mirror.lines.count) {
            let row = mirror.lines[y]
            var background: PackedColor?
            var foreground: PackedColor?
            var x = 0
            while x < columns {
                let index = y * columns + x
                let cell = x < row.cells.count ? row.cells[x] : .empty
                guard cell.width != .spacerTail else {
                    x += 1
                    continue
                }
                if backgrounds[index] != background {
                    background = backgrounds[index]
                    out += "\u{1B}[48;2;\(Self.rgb(backgrounds[index]))m"
                }
                if let color = glyphColor[index], color != foreground {
                    foreground = color
                    out += "\u{1B}[38;2;\(Self.rgb(color))m"
                }
                let scalars = x < row.cells.count ? row.scalars(at: x) : []
                if scalars.isEmpty || cell.width == .spacerHead {
                    out += " "
                } else {
                    for scalar in scalars { out.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}") }
                }
                x += 1
            }
            out += "\u{1B}[0m\n"
        }
        return out
    }

    private func runs(_ cells: [(Int, PackedColor)]) -> String {
        var parts: [String] = []
        var index = 0
        while index < cells.count {
            let (start, color) = cells[index]
            var end = start
            while index + 1 < cells.count, cells[index + 1].1 == color, cells[index + 1].0 <= end + 2 {
                index += 1
                end = cells[index].0
            }
            parts.append((start == end ? "\(start + 1)" : "\(start + 1)-\(end + 1)") + " " + hex(color))
            index += 1
        }
        return parts.joined(separator: " ")
    }

    private func hex(_ color: PackedColor) -> String {
        let digits = Array("0123456789ABCDEF")
        var out = "#"
        for shift in [0, 8, 16] {
            let byte = Int(color >> UInt32(shift) & 0xFF)
            out.append(digits[byte >> 4])
            out.append(digits[byte & 0xF])
        }
        return out
    }

    private static func rgb(_ color: PackedColor) -> String {
        "\(color & 0xFF);\(color >> 8 & 0xFF);\(color >> 16 & 0xFF)"
    }

    private static func decorationName(_ kind: UInt8) -> String {
        switch DecorationKind(rawValue: kind) {
        case .underline: "underline"
        case .doubleUnderline: "double-underline"
        case .curlyUnderline: "curly-underline"
        case .dottedUnderline: "dotted-underline"
        case .dashedUnderline: "dashed-underline"
        case .strikethrough: "strikethrough"
        case .overline: "overline"
        case nil: "decoration-\(kind)"
        }
    }
}

/// A recording replayed into the frames the app would draw: an engine in process, the
/// view's model and a frame builder, with placeholder glyphs. Feed it in pieces to see the
/// frame at any point.
public final class FrameReplay {
    public let session: ReplaySession
    public let model: SurfaceModel
    public let theme: Theme
    private let builder = FrameBuilder()
    private let glyphs = PlaceholderGlyphs()
    private static let cell = CellMetrics(
        width: 1, height: 1, baseline: 0, underlineTop: 0, underlineThickness: 1, strikethroughTop: 0,
        strikethroughThickness: 1, scale: 1)

    public init(columns: Int, rows: Int, theme: Theme = .legendsNeverDie) {
        self.theme = theme
        session = ReplaySession(Terminal.Configuration(columns: columns, rows: rows, palette: theme.palette))
        model = SurfaceModel(session: session)
    }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        session.feed(Array(bytes))
        _ = model.drain()
    }

    public var mirror: MirrorGrid { model.mirror }

    public func frame() -> Frame {
        builder.build(mirror: model.mirror, theme: theme, cell: Self.cell, selection: nil, glyphs: glyphs)
    }

    /// The frame summaries the goldens hold: one before each mark (where keys were typed),
    /// then the last.
    public static func summaries(of bytes: [UInt8], marks: [Int], columns: Int, rows: Int) -> String {
        let replay = FrameReplay(columns: columns, rows: rows)
        let palette = replay.theme.palette
        var out = ""
        var fed = 0
        for (index, mark) in marks.enumerated() {
            replay.feed(bytes[fed..<mark])
            fed = mark
            out += "==== before keys \(index + 1), after \(mark) bytes ====\n"
            out += replay.frame().summary(defaultForeground: palette.foreground, defaultBackground: palette.background)
        }
        replay.feed(bytes[fed...])
        if !marks.isEmpty { out += "==== at the end, after \(bytes.count) bytes ====\n" }
        return out
            + replay.frame().summary(defaultForeground: palette.foreground, defaultBackground: palette.background)
    }
}
