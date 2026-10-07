import ConfigKit
import ScreenProtocol
import Testing
import VTCore

@testable import SurfaceCore

/// Hands out a fixed placement per glyph, in the order glyphs are first asked for, and
/// records what was asked.
final class FakeGlyphs: GlyphSource {
    var epoch: UInt64 = 0
    var placements: [GlyphKey: GlyphPlacement] = [:]
    var requests: [GlyphKey] = []
    var unavailable: Set<UInt32> = []
    var usedShelves: Set<UInt16> = []

    func placement(for key: GlyphKey) -> GlyphPlacement? {
        requests.append(key)
        if key.scalars.count == 1, unavailable.contains(key.scalars[0]) { return nil }
        if let known = placements[key] { return known }
        let index = UInt16(placements.count)
        let placement = GlyphPlacement(
            atlas: key.scalars.first.map { $0 >= 0x1F300 } == true ? .color : .mask, x: index * 10, y: 0,
            width: key.isWide ? 18 : 9, height: 12, offsetX: 1, offsetY: 3, shelf: index % 3)
        placements[key] = placement
        return placement
    }

    func markUsed(shelves: [UInt16]) {
        usedShelves.formUnion(shelves)
    }
}

/// A replay session and the pieces a view puts around it.
private struct Surface {
    let session: ReplaySession
    let model: SurfaceModel
    let builder = FrameBuilder()
    let glyphs = FakeGlyphs()
    var theme = Theme.legendsNeverDie
    static let cell = CellMetrics(
        width: 9, height: 18, baseline: 14, underlineTop: 15, underlineThickness: 1, strikethroughTop: 9,
        strikethroughThickness: 1, scale: 1)

    init(columns: Int = 10, rows: Int = 3) {
        session = ReplaySession(Terminal.Configuration(columns: columns, rows: rows))
        model = SurfaceModel(session: session)
    }

    @discardableResult
    func feed(_ text: String) -> SurfaceModel.Update {
        session.feed(text)
        return model.drain()
    }

    func frame(selection: TextRegion? = nil, starfield: Bool = false) -> Frame {
        builder.build(
            mirror: model.mirror, theme: theme, cell: Self.cell, selection: selection, glyphs: glyphs,
            starfield: starfield)
    }
}

@Suite struct SurfaceModelTests {
    @Test func theFirstDrainIsASnapshot() {
        let surface = Surface()
        let update = surface.feed("hi")
        #expect(update.replaced)
        #expect(update.rows == [0, 1, 2])
        #expect(surface.model.mirror.lines[0].cells[0].scalar == 0x68)
    }

    @Test func laterDrainsCarryWhatChanged() {
        let surface = Surface()
        surface.feed("hi")
        var update = surface.feed("\u{1B}[2;1Hx")
        #expect(!update.replaced)
        #expect(update.rows == [1])
        #expect(update.cursorChanged)
        update = surface.feed("\u{1B}]2;Lucid Dreams\u{7}\u{7}")
        #expect(update.titleChanged)
        #expect(update.events == [.titleChanged("Lucid Dreams"), .bell])
        #expect(surface.model.drain().isEmpty)
    }

    @Test func scrollingThroughHistoryMovesTheViewport() {
        let surface = Surface()
        surface.feed("1\r\n2\r\n3\r\n4\r\n5")
        surface.session.scroll(by: 2)
        let update = surface.model.drain()
        #expect(update.viewportMoved)
        #expect(surface.model.mirror.viewportTopLine == 0)
        #expect(update.rows == [0, 1, 2])
    }

    @Test func aRefusedDeltaAsksForASnapshot() {
        let surface = Surface()
        surface.feed("hi")
        // A delta built on a state the mirror never had: the session forgets what the
        // mirror holds, as if the app had dropped a delta.
        surface.session.feed("x")
        _ = surface.session.takeDelta()
        surface.session.feed("y")
        let update = surface.model.drain()
        #expect(!update.replaced)
        let recovered = surface.model.drain()
        #expect(recovered.replaced)
        #expect(surface.model.mirror.lines[0].cells[3].scalar == 0x79)
    }

    @Test func aNewBasePaletteArrives() {
        let surface = Surface()
        surface.feed("hi")
        surface.session.setBasePalette(.xterm)
        let update = surface.model.drain()
        #expect(update.paletteChanged)
        #expect(update.events == [.colorsChanged])
        #expect(surface.model.mirror.palette == .xterm)
    }
}

@Suite struct ColorResolverTests {
    let resolver = ColorResolver(palette: .legendsNeverDie, theme: .legendsNeverDie)
    let palette = Palette.legendsNeverDie

    @Test func defaultsAndPaletteAndTruecolor() {
        let plain = resolver.resolve(.default)
        #expect(plain.foreground == palette.foreground)
        #expect(plain.background == palette.background)
        #expect(plain.underlineColor == palette.foreground)
        let colored = resolver.resolve(Style(foreground: .indexed(1), background: .rgb(1, 2, 3)))
        #expect(colored.foreground == palette.colors[1])
        #expect(colored.background == RGB(1, 2, 3))
    }

    @Test func inverseAndReverseVideoCancel() {
        let inverse = resolver.resolve(Style(attributes: .inverse))
        #expect(inverse.foreground == palette.background)
        #expect(inverse.background == palette.foreground)
        var reversed = resolver
        reversed.reverseVideo = true
        #expect(reversed.resolve(.default).background == palette.foreground)
        #expect(reversed.resolve(Style(attributes: .inverse)).background == palette.background)
        #expect(reversed.clearColor == palette.foreground)
    }

    @Test func faintIsHalfwayToTheBackground() {
        let faint = resolver.resolve(
            Style(foreground: .rgb(200, 100, 0), background: .rgb(0, 0, 0), attributes: .faint))
        #expect(faint.foreground == RGB(100, 50, 0))
    }

    @Test func boldIsBrightOnlyWhenTheThemeSaysSo() {
        let bold = Style(foreground: .indexed(1), attributes: .bold)
        #expect(resolver.resolve(bold).foreground == palette.colors[1])
        var theme = Theme.legendsNeverDie
        theme.boldIsBright = true
        let bright = ColorResolver(palette: palette, theme: theme)
        #expect(bright.resolve(bold).foreground == palette.colors[9])
        #expect(bright.resolve(Style(foreground: .indexed(9), attributes: .bold)).foreground == palette.colors[9])
        #expect(bright.resolve(Style(foreground: .indexed(1))).foreground == palette.colors[1])
    }

    @Test func selectionColors() {
        var theme = Theme.legendsNeverDie
        let selected = ColorResolver(palette: palette, theme: theme).resolve(
            Style(foreground: .indexed(2)), selected: true)
        #expect(selected.background == theme.selectionBackground)
        #expect(selected.foreground == palette.colors[2])
        theme.selectionForeground = RGB(255, 255, 255)
        let white = ColorResolver(palette: palette, theme: theme).resolve(.default, selected: true)
        #expect(white.foreground == RGB(255, 255, 255))
    }

    @Test func underlineColorsAndAttributes() {
        let style = Style(
            foreground: .indexed(3), underlineColor: .indexed(5), attributes: [.bold, .italic, .strikethrough],
            underline: .curly)
        let resolved = resolver.resolve(style)
        #expect(resolved.underlineColor == palette.colors[5])
        #expect(resolved.bold && resolved.italic && resolved.strikethrough)
        #expect(resolved.underline == .curly)
    }

    @Test func packingPutsRedInTheLowByte() {
        #expect(RGB(0x11, 0x22, 0x33).packed == 0xFF33_2211)
    }
}

@Suite struct FrameBuilderTests {
    @Test func backgroundsGlyphsAndColors() {
        let surface = Surface(columns: 4, rows: 2)
        surface.feed("a\u{1B}[41mb\u{1B}[0m c")
        let frame = surface.frame()
        let palette = Palette.legendsNeverDie
        #expect(frame.columns == 4 && frame.rows == 2)
        #expect(frame.backgrounds.count == 8)
        #expect(frame.backgrounds[0] == palette.background.packed)
        #expect(frame.backgrounds[1] == palette.colors[1].packed)
        // Spaces draw no glyph.
        #expect(frame.glyphs.map(\.cellX) == [0, 1, 3])
        #expect(frame.glyphs.allSatisfy { $0.cellY == 0 && $0.color == palette.foreground.packed })
        #expect(frame.glyphs[0].offsetX == 1 && frame.glyphs[0].offsetY == 3)
        #expect(frame.isComplete)
        #expect(frame.clearColor == palette.background.packed)
    }

    /// Stars go only in each row's empty end: after the last glyph, line or colored cell.
    @Test func theStarfieldMarksOnlyEachRowsEmptyEnd() {
        let surface = Surface(columns: 8, rows: 3)
        surface.feed("ab  c\r\n\u{1B}[44m  \u{1B}[0m x\u{1B}[4m \u{1B}[0m\r\n中")
        let plain = Palette.legendsNeverDie.background.packed
        let starry = (plain & 0x00FF_FFFF) | (FrameBuilder.starryAlpha << 24)
        #expect(!surface.frame().backgrounds.contains(starry), "off by default")
        let frame = surface.frame(starfield: true)
        func row(_ y: Int) -> [Bool] { (0..<8).map { frame.backgrounds[y * 8 + $0] == starry } }
        // "ab  c": the gap inside the line keeps no stars; the end does.
        #expect(row(0) == [false, false, false, false, false, true, true, true])
        // A blue background and an underlined space count as ink.
        #expect(row(1) == [false, false, false, false, false, true, true, true])
        // A wide character covers its second column.
        #expect(row(2) == [false, false, true, true, true, true, true, true])
    }

    @Test func wideAndColorGlyphs() {
        let surface = Surface(columns: 6, rows: 1)
        surface.feed("中🎉x")
        let frame = surface.frame()
        #expect(frame.glyphs.map(\.cellX) == [0, 2, 4])
        #expect(frame.glyphs.map(\.width) == [18, 18, 9])
        #expect(frame.glyphs.map(\.flags) == [0, GlyphInstance.colorAtlasFlag, 0])
        #expect(surface.glyphs.requests.map(\.isWide) == [true, true, false])
    }

    @Test func boldAndItalicPickTheFace() {
        let surface = Surface(columns: 4, rows: 1)
        surface.feed("\u{1B}[1ma\u{1B}[0;3mb")
        _ = surface.frame()
        #expect(surface.glyphs.requests.map(\.bold) == [true, false])
        #expect(surface.glyphs.requests.map(\.italic) == [false, true])
    }

    @Test func clustersKeepTheirScalars() {
        let surface = Surface(columns: 4, rows: 1)
        surface.feed("e\u{301}")
        _ = surface.frame()
        #expect(surface.glyphs.requests.map(\.scalars) == [[0x65, 0x301]])
    }

    @Test func onlyChangedRowsAreRebuilt() {
        let surface = Surface(columns: 4, rows: 3)
        surface.feed("a\r\nb\r\nc")
        _ = surface.frame()
        #expect(surface.builder.rebuiltRows == 3)
        surface.feed("\u{1B}[2;1Hx")
        _ = surface.frame()
        #expect(surface.builder.rebuiltRows == 1)
        _ = surface.frame()
        #expect(surface.builder.rebuiltRows == 0)
    }

    @Test func scrolledRowsAreReusedAtTheirNewPosition() {
        let surface = Surface(columns: 4, rows: 3)
        surface.feed("a\r\nb\r\nc")
        _ = surface.frame()
        surface.feed("\r\nd")
        let frame = surface.frame()
        #expect(surface.builder.rebuiltRows == 1)
        #expect(frame.glyphs.map(\.cellY) == [0, 1, 2])
    }

    @Test func colorChangesRebuildEverything() {
        var surface = Surface(columns: 4, rows: 2)
        surface.feed("a")
        _ = surface.frame()
        surface.theme.selectionBackground = RGB(1, 1, 1)
        _ = surface.frame()
        #expect(surface.builder.rebuiltRows == 2)
        surface.feed("\u{1B}]11;#000000\u{7}")
        let frame = surface.frame()
        #expect(surface.builder.rebuiltRows == 2)
        #expect(frame.backgrounds[0] == RGB(0, 0, 0).packed)
        surface.glyphs.epoch += 1
        _ = surface.frame()
        #expect(surface.builder.rebuiltRows == 2)
    }

    @Test func selectionHighlightsItsCells() {
        let surface = Surface(columns: 4, rows: 2)
        surface.feed("abcd\r\nefgh")
        let selection = TextRegion(TextPoint(line: 0, column: 2), TextPoint(line: 1, column: 1))
        let frame = surface.frame(selection: selection)
        let selected = Theme.legendsNeverDie.selectionBackground.packed
        let plain = Palette.legendsNeverDie.background.packed
        #expect(frame.backgrounds == [plain, plain, selected, selected, selected, selected, plain, plain])
        // Only rows whose selected columns changed rebuild.
        _ = surface.frame(selection: TextRegion(TextPoint(line: 0, column: 2), TextPoint(line: 1, column: 2)))
        #expect(surface.builder.rebuiltRows == 1)
    }

    @Test func missingGlyphsLeaveTheRowDirty() {
        let surface = Surface(columns: 4, rows: 1)
        surface.glyphs.unavailable = [0x62]
        surface.feed("ab")
        var frame = surface.frame()
        #expect(!frame.isComplete)
        #expect(frame.glyphs.map(\.cellX) == [0])
        surface.glyphs.unavailable = []
        frame = surface.frame()
        #expect(frame.isComplete)
        #expect(surface.builder.rebuiltRows == 1)
        #expect(frame.glyphs.map(\.cellX) == [0, 1])
    }

    @Test func invisibleTextDrawsOnlyItsBackground() {
        let surface = Surface(columns: 4, rows: 1)
        surface.feed("\u{1B}[8;4;41mab")
        let frame = surface.frame()
        #expect(frame.glyphs.isEmpty)
        #expect(frame.decorations.isEmpty)
        #expect(frame.backgrounds[0] == Palette.legendsNeverDie.colors[1].packed)
    }

    @Test func decorationsRunAcrossCells() {
        let surface = Surface(columns: 8, rows: 1)
        surface.feed("\u{1B}[4mabc\u{1B}[4:3;9md\u{1B}[0m \u{1B}[53mz")
        let frame = surface.frame()
        let kinds = frame.decorations.map { (Int($0.cellX), Int($0.cellCount), $0.kind) }
        let expected: [(Int, Int, UInt8)] = [
            (0, 3, DecorationKind.underline.rawValue),
            (3, 1, DecorationKind.curlyUnderline.rawValue),
            (3, 1, DecorationKind.strikethrough.rawValue),
            (5, 1, DecorationKind.overline.rawValue),
        ]
        #expect(kinds.count == expected.count)
        for (a, b) in zip(kinds, expected) { #expect(a == b) }
        let underline = frame.decorations[0]
        #expect(underline.top == 15 && underline.height == 1 && underline.thickness == 1)
        let curly = frame.decorations[1]
        #expect(curly.top == 14 && curly.height == 4)
        #expect(frame.decorations[2].top == 9)
        #expect(frame.decorations[3].top == 0)
    }

    @Test func underlineColorsSplitRuns() {
        let surface = Surface(columns: 4, rows: 1)
        surface.feed("\u{1B}[4;58;5;1ma\u{1B}[58;5;2mb")
        let frame = surface.frame()
        #expect(frame.decorations.map(\.cellCount) == [1, 1])
        #expect(frame.decorations.map(\.color) == [1, 2].map { Palette.legendsNeverDie.colors[$0].packed })
    }

    @Test func shelvesInUseAreReported() {
        let surface = Surface(columns: 6, rows: 1)
        surface.feed("abcd")
        _ = surface.frame()
        #expect(surface.glyphs.usedShelves == [0, 1, 2])
    }

    /// An input method's composing text covers the cells at the cursor, underlined, and is
    /// gone from the next frame without it.
    @Test func composingTextIsDrawnOverTheRow() {
        let surface = Surface(columns: 8, rows: 2)
        surface.feed("\u{1B}[41mabcdef")
        let preedit = PreeditLayout(text: "日本", cursorColumn: 1, cursorRow: 0, columns: 8)
        let frame = surface.builder.build(
            mirror: surface.model.mirror, theme: surface.theme, cell: Surface.cell, selection: nil,
            glyphs: surface.glyphs, preedit: preedit)
        let red = Palette.legendsNeverDie.colors[1].packed
        let plain = Palette.legendsNeverDie.background.packed
        // The red background ends with "abcdef"; 日本 covers b to e in the default colors.
        #expect(Array(frame.backgrounds[0..<8]) == [red, plain, plain, plain, plain, red, plain, plain])
        // a, then 日 and 本 (wide), then f; b, c, d and e are covered.
        #expect(frame.glyphs.map(\.cellX).sorted() == [0, 1, 3, 5])
        #expect(frame.decorations.map { [Int($0.cellX), Int($0.cellCount)] } == [[1, 4]])
        let without = surface.frame()
        #expect(Array(without.backgrounds[0..<8]) == Array(repeating: red, count: 6) + [plain, plain])
        #expect(without.decorations.isEmpty)
    }

    // MARK: - Block chrome

    /// A transcript the shell integration would send for two commands, the second still being
    /// typed. Three rows, so both blocks and the band are in view at once.
    private static func twoCommands(_ surface: Surface) {
        surface.feed("\u{1B}]133;A\u{7}$ ls\u{1B}]133;B\u{7}\u{1B}]133;C\u{7}")
        surface.feed("\r\nout\u{1B}]633;E;ls\u{7}\u{1B}]133;D;0;dur=2000\u{7}")
        surface.feed("\r\n\u{1B}]133;A\u{7}$ ")
    }

    private static func chrome(_ runs: [BlockRun]) -> BlockChrome {
        BlockChrome(
            runs: runs,
            colors: BlockColors(
                rail: RGB(0x40, 0x40, 0x40), railFailed: RGB(0xFF, 0x00, 0x00), band: RGB(0xFF, 0xFF, 0xFF),
                bandAmount: 0.5))
    }

    /// The rail and the band go on after the row cache, like composing text and the hovered
    /// link, so a block appearing or the cursor moving between two of them rebuilds no rows.
    @Test func blockChromeIsDrawnWithoutRebuildingRows() {
        let surface = Surface(columns: 8, rows: 3)
        Self.twoCommands(surface)
        _ = surface.frame()
        let runs = Blocks.runs(in: surface.model.mirror)
        #expect(runs.count == 2, "two prompts in view, so two blocks")

        let frame = surface.builder.build(
            mirror: surface.model.mirror, theme: surface.theme, cell: Surface.cell, selection: nil,
            glyphs: surface.glyphs, blocks: Self.chrome(runs))
        #expect(surface.builder.rebuiltRows == 0)
        // One instance per block, a single cell wide, as tall as the block.
        let rails = frame.decorations.filter { $0.kind == DecorationKind.rail.rawValue }
        #expect(
            rails.map { [Int($0.cellX), Int($0.cellY), Int($0.cellCount), Int($0.height)] }
                == [[0, 0, 1, 2 * Surface.cell.height], [0, 2, 1, Surface.cell.height]])
        // And none of it sticks: a plain frame is the terminal as it was.
        #expect(surface.frame().decorations.filter { $0.kind == DecorationKind.rail.rawValue }.isEmpty)
    }

    /// The rail says "this is a command" and nothing more, except on a failure — which always
    /// has a badge, so the ✗ `docs/DESIGN.md` asks for is always beside the danger color.
    @Test func onlyAFailedBlocksRailTakesTheDangerColor() {
        let surface = Surface(columns: 8, rows: 2)
        surface.feed("\u{1B}]133;A\u{7}$ x\u{1B}]133;D;3\u{7}")
        surface.feed("\r\n\u{1B}]133;A\u{7}$ y\u{1B}]133;D;0\u{7}")
        let runs = Blocks.runs(in: surface.model.mirror)
        let frame = surface.builder.build(
            mirror: surface.model.mirror, theme: surface.theme, cell: Surface.cell, selection: nil,
            glyphs: surface.glyphs, blocks: Self.chrome(runs))
        let rails = frame.decorations.filter { $0.kind == DecorationKind.rail.rawValue }
        #expect(rails.count == 2)
        #expect(rails.first?.color == RGB(0xFF, 0x00, 0x00).packed, "the one that exited 3")
        #expect(rails.last?.color == RGB(0x40, 0x40, 0x40).packed, "the one that worked")
    }

    /// The band tints only the block the cursor is in. Twenty tinted bands read as stripes.
    @Test func theBandTintsOnlyTheBlockYouAreIn() {
        let surface = Surface(columns: 4, rows: 3)
        Self.twoCommands(surface)
        let runs = Blocks.runs(in: surface.model.mirror)
        #expect(runs.map(\.isCurrent) == [false, true], "the cursor is on the prompt it is typing at")
        let plain = surface.frame().backgrounds
        let frame = surface.builder.build(
            mirror: surface.model.mirror, theme: surface.theme, cell: Surface.cell, selection: nil,
            glyphs: surface.glyphs, blocks: Self.chrome(runs))
        // Rows 0 and 1 are the first block: untouched.
        #expect(Array(frame.backgrounds[0..<8]) == Array(plain[0..<8]))
        // Row 2 is the one being typed in: every cell moved, and all the same way.
        let banded = Array(frame.backgrounds[8..<12])
        #expect(banded.allSatisfy { $0 != plain[8] })
        #expect(Set(banded).count == 1)
    }

    /// The trap the band had to be written around: `starryAlpha` is the background word's own
    /// top byte, so writing a constant would put out every star the band covers, and packing
    /// one by hand could make a tinted cell starry.
    @Test func theBandKeepsTheStarfieldExactlyWhereItWas() {
        let surface = Surface(columns: 6, rows: 1)
        surface.feed("\u{1B}]133;A\u{7}ab")
        let plain = surface.frame(starfield: true).backgrounds
        let starryBefore = plain.map { $0 >> 24 }
        #expect(starryBefore.contains(FrameBuilder.starryAlpha), "the row's empty end is starry to begin with")

        let runs = Blocks.runs(in: surface.model.mirror)
        #expect(runs.first?.isCurrent == true)
        let frame = surface.builder.build(
            mirror: surface.model.mirror, theme: surface.theme, cell: Surface.cell, selection: nil,
            glyphs: surface.glyphs, starfield: true, blocks: Self.chrome(runs))
        // Every star is still a star and every opaque cell is still opaque...
        #expect(frame.backgrounds.map { $0 >> 24 } == starryBefore)
        // ...and the color under all of them moved, so the band really did cover the stars too.
        for (index, was) in plain.enumerated() {
            #expect(frame.backgrounds[index] & 0x00FF_FFFF != was & 0x00FF_FFFF, "cell \(index) was not tinted")
        }
    }

    /// What the frame goldens pass, so they keep saying what they said.
    @Test func withNoBlocksTheFrameIsWhatItAlwaysWas() {
        let surface = Surface(columns: 8, rows: 3)
        Self.twoCommands(surface)
        let withNil = surface.builder.build(
            mirror: surface.model.mirror, theme: surface.theme, cell: Surface.cell, selection: nil,
            glyphs: surface.glyphs, blocks: nil)
        #expect(withNil.decorations.allSatisfy { $0.kind != DecorationKind.rail.rawValue })
        #expect(withNil.backgrounds == surface.frame().backgrounds)
    }

    @Test func aHoveredLinkIsUnderlinedWithoutRebuildingRows() {
        let surface = Surface(columns: 8, rows: 2)
        surface.feed("ab\u{1B}[32mhttps://x.example")
        _ = surface.frame()
        let link = LinkHit(
            uri: "https://x.example", text: "https://x.example",
            spans: [LinkHit.Span(row: 0, columns: 2..<8), LinkHit.Span(row: 1, columns: 0..<9)], isExplicit: false)
        let frame = surface.builder.build(
            mirror: surface.model.mirror, theme: surface.theme, cell: Surface.cell, selection: nil,
            glyphs: surface.glyphs, link: link)
        #expect(surface.builder.rebuiltRows == 0)
        // Clamped to the screen's width, in the link text's own color.
        #expect(
            frame.decorations.map { [Int($0.cellX), Int($0.cellY), Int($0.cellCount)] } == [[2, 0, 6], [0, 1, 8]])
        #expect(frame.decorations.first?.color == Palette.legendsNeverDie.colors[2].packed)
        #expect(surface.frame().decorations.isEmpty)
    }

    /// The structs the shaders read have the sizes the shaders expect.
    @Test func instanceLayouts() {
        #expect(MemoryLayout<GlyphInstance>.size == 24)
        #expect(MemoryLayout<GlyphInstance>.stride == 24)
        #expect(MemoryLayout<DecorationInstance>.size == 16)
        #expect(MemoryLayout<DecorationInstance>.stride == 16)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.color) == 16)
        #expect(MemoryLayout<DecorationInstance>.offset(of: \.color) == 12)
    }
}

@Suite struct ShelfAtlasTests {
    @Test func glyphsShareShelvesOfTheirHeight() {
        var atlas = ShelfAtlas(size: 64, maxSize: 64)
        #expect(atlas.allocate(width: 9, height: 17, frame: 1) == .placed(.init(x: 0, y: 0, shelf: 0)))
        #expect(atlas.allocate(width: 9, height: 17, frame: 1) == .placed(.init(x: 10, y: 0, shelf: 0)))
        // Much shorter glyphs get a shelf of their own.
        #expect(atlas.allocate(width: 4, height: 3, frame: 1) == .placed(.init(x: 0, y: 18, shelf: 1)))
        // A slightly shorter one shares.
        #expect(atlas.allocate(width: 9, height: 15, frame: 1) == .placed(.init(x: 20, y: 0, shelf: 0)))
    }

    @Test func itGrowsThenReusesTheOldestShelf() {
        var atlas = ShelfAtlas(size: 16, maxSize: 32)
        #expect(atlas.allocate(width: 15, height: 15, frame: 1) == .placed(.init(x: 0, y: 0, shelf: 0)))
        #expect(atlas.allocate(width: 15, height: 15, frame: 2) == .grew(.init(x: 16, y: 0, shelf: 0), size: 32))
        #expect(atlas.allocate(width: 15, height: 15, frame: 3) == .placed(.init(x: 0, y: 16, shelf: 1)))
        #expect(atlas.allocate(width: 15, height: 15, frame: 4) == .placed(.init(x: 16, y: 16, shelf: 1)))
        // Full, and every shelf drawn from in the last three frames: nothing to reuse yet.
        #expect(atlas.allocate(width: 15, height: 15, frame: 4) == .full)
        // Shelf 1 keeps being drawn from; shelf 0 goes quiet and is reused.
        atlas.markUsed(shelf: 1, frame: 7)
        #expect(atlas.allocate(width: 15, height: 15, frame: 7) == .reused(.init(x: 0, y: 0, shelf: 0), evicted: 0))
        #expect(atlas.allocate(width: 15, height: 15, frame: 7) == .placed(.init(x: 16, y: 0, shelf: 0)))
    }

    @Test func tooBigIsFull() {
        var atlas = ShelfAtlas(size: 16, maxSize: 32)
        #expect(atlas.allocate(width: 40, height: 4, frame: 1) == .full)
    }

    @Test func resetForgetsEverything() {
        var atlas = ShelfAtlas(size: 16, maxSize: 64)
        _ = atlas.allocate(width: 15, height: 15, frame: 1)
        _ = atlas.allocate(width: 15, height: 15, frame: 1)
        atlas.reset(size: 16)
        #expect(atlas.size == 16)
        #expect(atlas.allocate(width: 15, height: 15, frame: 2) == .placed(.init(x: 0, y: 0, shelf: 0)))
    }
}
