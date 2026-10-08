import ScreenProtocol
import Testing
import VTCore

@testable import SurfaceCore

/// A `GlyphKey` that covers several columns, for the runs a font draws as one glyph.
///
/// The first test is the important one: it pins the bits every other kind of key packs into, so
/// the claim that shaping off leaves the frame exactly as it was is a claim about numbers rather
/// than about care — and so the next person to take a free bit cannot move these by accident.
@Suite struct GlyphKeyRunTests {
    @Test func theBitsEveryOtherKindOfKeyPacksAreUnchanged() {
        #expect(GlyphKey(scalar: 0x41).packed == 0x41)
        #expect(GlyphKey(scalar: 0x41, bold: true).packed == 0x41 | 1 << 21)
        #expect(GlyphKey(scalar: 0x41, italic: true).packed == 0x41 | 1 << 22)
        #expect(GlyphKey(scalar: 0x4F60, wide: true).packed == 0x4F60 | 1 << 23)
        // A cluster's scalars live beside the word, so only the cluster bit is set in it.
        #expect(GlyphKey(scalars: [0x65, 0x301], bold: false, italic: false, wide: false).packed == 1 << 24)
        // And the run bits are zero on all of them, which is what `cells` falls back from.
        for key in [
            GlyphKey(scalar: 0x41), GlyphKey(scalar: 0x41, bold: true), GlyphKey(scalar: 0x4F60, wide: true),
            GlyphKey(scalars: [0x65, 0x301], bold: false, italic: false, wide: false),
        ] {
            #expect(!key.isRun)
        }
    }

    @Test func aRunCountsItsColumns() {
        let two = GlyphKey(run: Array("!=".unicodeScalars.map(\.value)), bold: false, italic: false)
        #expect(two.isRun)
        #expect(two.cells == 2)
        #expect(two.string == "!=")
        let three = GlyphKey(run: Array("===".unicodeScalars.map(\.value)), bold: false, italic: false)
        #expect(three.cells == 3)
        #expect(three.string == "===")
        let eight = GlyphKey(run: Array(repeating: UInt32(0x2D), count: 8), bold: false, italic: false)
        #expect(eight.cells == 8)
    }

    @Test func aRunIsNeverAlsoWide() {
        // The alphabet is one-column characters, so the two cannot both be true; a caller that
        // asks for both gets a run, because that is what decides the width.
        let key = GlyphKey(scalars: [0x21, 0x3D], bold: false, italic: false, wide: true, runCells: 2)
        #expect(key.isRun)
        #expect(!key.isWide)
        #expect(key.cells == 2)
    }

    /// Five bits hold 32, and a caller asking for more gets 32 rather than a wrapped-around
    /// span that would read as a one-cell glyph.
    @Test func theSpanIsClampedRatherThanWrapped() {
        let scalars = Array(repeating: UInt32(0x2D), count: 40)
        let key = GlyphKey(run: scalars, bold: false, italic: false)
        #expect(key.cells == GlyphKey.maxRunCells)
        #expect(key.isRun)
    }

    /// A run of two scalars and a grapheme cluster of the same two are different glyphs, and
    /// the cache must not answer one with the other.
    @Test func aRunAndAClusterOverTheSameScalarsAreDifferentKeys() {
        let scalars: [UInt32] = [0x65, 0x301]
        let run = GlyphKey(run: scalars, bold: false, italic: false)
        let cluster = GlyphKey(scalars: scalars, bold: false, italic: false, wide: false)
        #expect(run != cluster)
        #expect(run.packed != cluster.packed)
        #expect(cluster.cells == 1)
        #expect(run.cells == 2)
    }

    /// Fewer than two columns is not a run: one character shaped alone is the ordinary path,
    /// and giving it run bits would make a second cache entry for the same glyph.
    ///
    /// The `runCells >= 2` floor in the initializer reads as that intent but is not separately
    /// provable — a span is stored less one, so 1 writes the same zero that 0 does. What is
    /// provable, and what this pins, is the outcome: neither count makes a run, and both pack
    /// to the very bits a plain key packs.
    @Test func neitherZeroNorOneColumnsMakeARun() {
        for count in [0, 1] {
            let key = GlyphKey(scalars: [0x41], bold: false, italic: false, wide: false, runCells: count)
            #expect(!key.isRun, "runCells \(count)")
            #expect(key.cells == 1, "runCells \(count)")
            #expect(key.packed == GlyphKey(scalar: 0x41).packed, "runCells \(count)")
        }
    }

    @Test func aRunKeepsItsFaceAndItsText() {
        let key = GlyphKey(run: Array("=>".unicodeScalars.map(\.value)), bold: true, italic: true)
        #expect(key.bold)
        #expect(key.italic)
        #expect(key.scalars == Array("=>".unicodeScalars.map(\.value)))
        #expect(key.cells == 2)
    }
}

/// A table standing in for a font. The thing under test is segmentation — where a run may be —
/// so the oracle's answers are fixed and the test never computes what it is asserting.
private final class TableShaper: RunShaping {
    var ligatures: Set<String>
    private(set) var asked: [String] = []

    init(_ ligatures: Set<String> = ["!=", "=>", "===", "->", "::"]) {
        self.ligatures = ligatures
    }

    func shapesAsOne(_ scalars: [UInt32], bold: Bool, italic: Bool) -> Bool {
        var text = ""
        for scalar in scalars { text.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}") }
        asked.append(text)
        return ligatures.contains(text)
    }
}

/// A row from a real engine, so the cells, their widths and their style ids are the ones the
/// frame builder will actually see.
private func line(_ text: String, columns: Int = 20) -> RowSnapshot {
    let session = ReplaySession(Terminal.Configuration(columns: columns, rows: 2))
    let model = SurfaceModel(session: session)
    session.feed(text)
    _ = model.drain()
    return model.mirror.lines[0]
}

/// A function rather than a stored closure: a global `let` holding a closure is not Sendable.
private func plainFace(_ column: Int) -> (bold: Bool, italic: Bool) { (false, false) }

@Suite struct RunScannerTests {
    private func runs(
        _ text: String, scanner: RunScanner = RunScanner(), shaper: TableShaper = TableShaper(),
        selected: ClosedRange<Int>? = nil, columns: Int = 20
    ) -> [GlyphRun] {
        scanner.runs(
            in: line(text, columns: columns), columns: columns, selected: selected, face: plainFace(_:),
            shaper: shaper)
    }

    @Test func itFindsTheRunsAFontDraws() {
        let found = runs("a != b")
        #expect(found.count == 1)
        #expect(found.first?.column == 2)
        #expect(found.first?.cells == 2)
        #expect(found.first?.scalars == Array("!=".unicodeScalars.map(\.value)))
    }

    @Test func itFindsEveryRunInARow() {
        let found = runs("x => y != z")
        #expect(found.map(\.column) == [2, 7])
        #expect(found.map(\.cells) == [2, 2])
    }

    /// Leftmost-longest: `===` is one run of three, not `==` and a stray `=`.
    @Test func theLongestRunWins() {
        let found = runs("a === b", shaper: TableShaper(["==", "==="]))
        #expect(found.count == 1)
        #expect(found.first?.cells == 3)
    }

    /// And when the long one is not in the font, the scanner falls back to what is.
    @Test func itFallsBackToAShorterRunTheFontDoesDraw() {
        let found = runs("a === b", shaper: TableShaper(["=="]))
        #expect(found.count == 1)
        #expect(found.first?.column == 2)
        #expect(found.first?.cells == 2, "the first two of the three")
    }

    @Test func aRunTheFontRefusesIsNotARun() {
        #expect(runs("a =! b").isEmpty)
    }

    /// Letters are not in the alphabet, so a run never reaches into a word — which is what
    /// keeps the key space bounded.
    @Test func lettersAreNotPartOfARun() {
        #expect(runs("a=b", shaper: TableShaper(["a=", "=b", "a=b"])).isEmpty)
    }

    /// A change of style ends a run: the whole run is drawn as one instance with one
    /// foreground and one underline, so it must not straddle two styles.
    @Test func aChangeOfStyleEndsARun() {
        // `!` plain, `=` bold.
        #expect(runs("a!\u{1B}[1m=b").isEmpty)
        // And with the style change after the pair, the pair still ligates.
        let found = runs("a!=\u{1B}[1mb")
        #expect(found.count == 1)
        #expect(found.first?.column == 1)
    }

    /// A selection edge inside a run ends it too, so the highlight lands on exact cell
    /// boundaries rather than on half a bitmap.
    @Test func aSelectionEdgeEndsARun() {
        #expect(runs("a != b", selected: 0...2).isEmpty, "the selection ends between ! and =")
        let found = runs("a != b", selected: 0...3)
        #expect(found.count == 1, "both of the run's columns are selected, so it survives")
    }

    /// A double-width character carries VT width semantics, so it is never part of a run and
    /// never splits one by accident either.
    @Test func aDoubleWidthCharacterIsNotPartOfARun() {
        let found = runs("\u{4F60}!=")
        #expect(found.count == 1)
        #expect(found.first?.column == 2, "after the two columns the wide character covers")
    }

    /// The engine cannot make this row — ASCII punctuation is one column by Unicode's own
    /// width — but a `RowSnapshot` also arrives decoded from whatever `legendsd` sent, so the
    /// width guard is about the wire rather than about the engine. A run over a cell claiming
    /// two columns would overlap a tail the frame builder separately skips.
    @Test func aForgedWideCellIsNeverPartOfARun() {
        func cell(_ scalar: UInt32, _ width: CellWidth) -> Cell {
            Cell(scalar: scalar, width: width, styleID: 0, protected: false, link: 0)
        }
        let equals = UInt32(0x3D)
        // A cell claiming two columns with another alphabet character right beside it, where a
        // spacer tail belongs. Without the width guard, columns 0 and 1 ligate as a two-column
        // run while column 0 already claims two — so the run covers column 1 twice.
        let forged = RowSnapshot(
            id: 1, version: 1,
            cells: [cell(equals, .wide), cell(equals, .narrow), cell(equals, .narrow), cell(equals, .narrow)])
        let found = RunScanner().runs(
            in: forged, columns: 4, selected: nil, face: plainFace(_:), shaper: TableShaper(["==", "==="]))
        #expect(
            found.map(\.column) == [1],
            "the run starts past the cell that claims two columns, not on it")
        #expect(
            found.first?.cells == 3,
            "and covers the three single-column cells after it, which is the longest match there")
    }

    @Test func aRunNeverRunsPastTheRowsEnd() {
        // `!=` sits on the last two columns of a four-column row.
        let found = runs("ab!=", columns: 4)
        #expect(found.map(\.column) == [2])
        #expect(found.first?.cells == 2)
    }

    @Test func theCapBoundsARunsLength() {
        let dashes = String(repeating: "-", count: 10)
        let shaper = TableShaper([dashes, String(repeating: "-", count: 4), "--"])
        let found = runs(dashes, scanner: RunScanner(maxCells: 4), shaper: shaper)
        #expect(found.first?.cells == 4, "never more than the cap, however long the font's run")
    }

    /// The cap derived from the cell is the one that matters: a rasterizer handed a bitmap
    /// wider than it will draw answers "draws nothing", and caches that answer.
    @Test func aBigCellShortensTheCap() {
        let wide = CellMetrics(
            width: 300, height: 600, baseline: 480, underlineTop: 500, underlineThickness: 2,
            strikethroughTop: 300, strikethroughThickness: 2, scale: 2)
        #expect(RunScanner(cell: wide).maxCells == 3, "1024 / 300")
        let ordinary = CellMetrics(
            width: 9, height: 18, baseline: 14, underlineTop: 15, underlineThickness: 1,
            strikethroughTop: 9, strikethroughThickness: 1, scale: 1)
        #expect(RunScanner(cell: ordinary).maxCells == 8, "the asked-for cap, well inside the limit")
        // Never below two, or `maxCells` would mean "no runs" rather than "short runs".
        let huge = CellMetrics(
            width: 4000, height: 600, baseline: 480, underlineTop: 500, underlineThickness: 2,
            strikethroughTop: 300, strikethroughThickness: 2, scale: 2)
        #expect(RunScanner(cell: huge).maxCells == 2)
    }

    @Test func aRunNeverCoversMoreThanAKeyCanHold() {
        #expect(RunScanner(maxCells: 999).maxCells == GlyphKey.maxRunCells)
    }

    @Test func anEmptyRowHasNoRuns() {
        #expect(runs("").isEmpty)
    }
}

@Suite struct MemoizedRunShapingTests {
    @Test func itAsksOncePerDistinctRun() {
        let table = TableShaper()
        let memo = MemoizedRunShaping(table)
        let bang = Array("!=".unicodeScalars.map(\.value))
        #expect(memo.shapesAsOne(bang, bold: false, italic: false))
        #expect(memo.shapesAsOne(bang, bold: false, italic: false))
        #expect(memo.shapesAsOne(bang, bold: false, italic: false))
        #expect(table.asked == ["!="], "asked once, answered three times")
    }

    /// The face is part of the question: a font may ligate in regular and not in bold.
    @Test func theFaceIsPartOfTheKey() {
        let table = TableShaper()
        let memo = MemoizedRunShaping(table)
        let bang = Array("!=".unicodeScalars.map(\.value))
        _ = memo.shapesAsOne(bang, bold: false, italic: false)
        _ = memo.shapesAsOne(bang, bold: true, italic: false)
        _ = memo.shapesAsOne(bang, bold: true, italic: true)
        #expect(table.asked.count == 3)
        #expect(memo.count == 3)
    }

    @Test func aNewFaceForgetsEveryAnswer() {
        let table = TableShaper()
        let memo = MemoizedRunShaping(table)
        let bang = Array("!=".unicodeScalars.map(\.value))
        _ = memo.shapesAsOne(bang, bold: false, italic: false)
        memo.forgetAll()
        _ = memo.shapesAsOne(bang, bold: false, italic: false)
        #expect(table.asked == ["!=", "!="])
    }

    /// Past its bound the memo stops growing rather than evicting: reaching it means something
    /// unexpected is asking, and paying the shaper beats unbounded memory.
    @Test func theMemoIsBounded() {
        let table = TableShaper([])
        let memo = MemoizedRunShaping(table, limit: 2)
        for scalar in UInt32(0x21)...UInt32(0x25) {
            _ = memo.shapesAsOne([scalar, 0x3D], bold: false, italic: false)
        }
        #expect(memo.count == 2)
    }
}
