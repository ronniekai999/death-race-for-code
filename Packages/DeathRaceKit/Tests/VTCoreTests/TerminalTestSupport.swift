@testable import VTCore

func makeTerminal(
    columns: Int = 10, rows: Int = 5, _ configure: (inout Terminal.Configuration) -> Void = { _ in }
) -> Terminal {
    var configuration = Terminal.Configuration(columns: columns, rows: rows)
    configure(&configuration)
    return Terminal(configuration)
}

extension Terminal {
    /// Every row of the active area as text.
    var lines: [String] { (0..<rows).map { row($0).text } }

    /// The scrollback, oldest first, as text.
    var scrollbackLines: [String] { (0..<scrollbackCount).map { scrollbackRow($0).text } }

    /// `[x, y]`, 0-based: an array, so `#expect` can compare it and print both sides.
    var cursorPosition: [Int] { [cursor.x, cursor.y] }

    /// Replies as a string, for comparing with escape sequences.
    func takeReplyString() -> String {
        String(decoding: takeReplies(), as: UTF8.self)
    }

    /// The style of the cell at a position.
    func style(x: Int, y: Int) -> Style {
        let row = row(y)
        return row.style(of: row.cells[x])
    }
}
