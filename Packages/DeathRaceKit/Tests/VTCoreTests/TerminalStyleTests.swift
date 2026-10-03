import Testing

@testable import VTCore

@Suite struct TerminalStyleTests {
    private func pen(after sgr: String) -> Style {
        let t = makeTerminal()
        t.feed("\u{1B}[\(sgr)m")
        return t.currentStyle
    }

    @Test func attributesSetAndReset() {
        #expect(
            pen(after: "1;3;4;9;53")
                == Style(attributes: [.bold, .italic, .strikethrough, .overline], underline: .single))
        #expect(pen(after: "1;2;22") == .default)
        #expect(pen(after: "3;23;4;24;5;25;7;27;8;28;9;29;53;55") == .default)
        #expect(pen(after: "1;0") == .default)
        #expect(pen(after: "1;") == .default)
    }

    @Test func emptySGRResets() {
        let t = makeTerminal()
        t.feed("\u{1B}[1;31m\u{1B}[m")
        #expect(t.currentStyle == .default)
    }

    @Test func basicAndBrightColors() {
        #expect(pen(after: "31;42") == Style(foreground: .indexed(1), background: .indexed(2)))
        #expect(pen(after: "91;102") == Style(foreground: .indexed(9), background: .indexed(10)))
        #expect(pen(after: "31;39;42;49") == .default)
    }

    @Test func extendedColorsInEveryForm() {
        #expect(pen(after: "38;5;196").foreground == .indexed(196))
        #expect(pen(after: "38:5:196").foreground == .indexed(196))
        #expect(pen(after: "48;2;10;20;30").background == .rgb(10, 20, 30))
        #expect(pen(after: "48:2::10:20:30").background == .rgb(10, 20, 30))
        #expect(pen(after: "48:2:10:20:30").background == .rgb(10, 20, 30))
        #expect(pen(after: "38:2:1:10:20:30").foreground == .rgb(10, 20, 30))
        #expect(pen(after: "58:2::1:2:3").underlineColor == .rgb(1, 2, 3))
        #expect(pen(after: "58;5;9;59").underlineColor == .default)
        #expect(pen(after: "38;2;300;20;30").foreground == .rgb(255, 20, 30))
    }

    @Test func colorsMixWithOtherAttributes() {
        #expect(
            pen(after: "1;38;2;10;20;30;4;48;5;17")
                == Style(
                    foreground: .rgb(10, 20, 30), background: .indexed(17), attributes: .bold, underline: .single))
        #expect(pen(after: "38:5:1;1").attributes == .bold)
    }

    @Test func malformedColorsAreIgnoredWithoutLeakingAttributes() {
        #expect(pen(after: "38;5") == .default)
        #expect(pen(after: "38;2;1;2") == .default)
        #expect(pen(after: "1;38;7;3") == Style(attributes: .bold))
        #expect(pen(after: "38:2:1;3") == Style(attributes: .italic))
    }

    @Test func underlineStyles() {
        #expect(pen(after: "4:3").underline == .curly)
        #expect(pen(after: "4:2").underline == .double)
        #expect(pen(after: "4:4").underline == .dotted)
        #expect(pen(after: "4:5").underline == .dashed)
        #expect(pen(after: "4:3;4:0").underline == UnderlineStyle.none)
        #expect(pen(after: "21").underline == .double)
        #expect(pen(after: "4:3;24").underline == UnderlineStyle.none)
    }

    @Test func cellsCarryTheirStyle() {
        let t = makeTerminal()
        t.feed("\u{1B}[31mA\u{1B}[0mB\u{1B}[1mC")
        #expect(t.style(x: 0, y: 0) == Style(foreground: .indexed(1)))
        #expect(t.style(x: 1, y: 0) == .default)
        #expect(t.style(x: 2, y: 0) == Style(attributes: .bold))
        #expect(t.row(0).cells[1].styleID == 0)
    }

    @Test func rowStyleTablesStayBounded() {
        let t = makeTerminal()
        for i in 0..<500 { t.feed("\u{1B}[38;2;\(i % 256);\(i / 256);0mX\r") }
        #expect(t.row(0).styles.count <= 33)
        #expect(t.style(x: 0, y: 0).foreground == .rgb(243, 1, 0))
    }

    @Test func manyStylesInOneRowStayDistinct() {
        let t = makeTerminal(columns: 200, rows: 1)
        for i in 0..<200 { t.feed("\u{1B}[38;5;\(i)mX") }
        for i in 0..<200 { #expect(t.style(x: i, y: 0).foreground == .indexed(UInt8(i))) }
    }

    @Test func statusStringReportsThePen() {
        let t = makeTerminal()
        t.feed("\u{1B}[1;4:3;91;38;2;1;2;3;48;5;17;58;5;200m\u{1B}P$qm\u{1B}\\")
        #expect(t.takeReplyString() == "\u{1B}P1$r0;1;4:3;38:2::1:2:3;48:5:17;58:5:200m\u{1B}\\")
        t.feed("\u{1B}[0;31;102m\u{1B}P$qm\u{1B}\\")
        #expect(t.takeReplyString() == "\u{1B}P1$r0;31;102m\u{1B}\\")
    }
}
