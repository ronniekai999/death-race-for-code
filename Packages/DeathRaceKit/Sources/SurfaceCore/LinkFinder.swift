import ScreenProtocol
import VTCore

/// A link under the pointer: one a program made (OSC 8), with every cell of it on screen,
/// or a URL found in the text.
public struct LinkHit: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        /// A viewport row.
        public var row: Int
        public var columns: Range<Int>

        public init(row: Int, columns: Range<Int>) {
            self.row = row
            self.columns = columns
        }
    }

    public var uri: String
    /// What the link shows on screen, to tell whether it names a site it does not go to.
    public var text: String
    /// The cells it covers, top to bottom.
    public var spans: [Span]
    /// The program made it with OSC 8, rather than the text holding a URL.
    public var isExplicit: Bool

    public init(uri: String, text: String, spans: [Span], isExplicit: Bool) {
        self.uri = uri
        self.text = text
        self.spans = spans
        self.isExplicit = isExplicit
    }

    public func contains(column: Int, row: Int) -> Bool {
        spans.contains { $0.row == row && $0.columns.contains(column) }
    }
}

/// Finds the link at a cell of the screen, for ⌘-hovering and ⌘-clicking.
public enum LinkFinder {
    /// The program's own link at the cell, else a URL in the text of its line, soft
    /// wraps included.
    public static func link(atColumn column: Int, row: Int, in mirror: MirrorGrid) -> LinkHit? {
        guard mirror.lines.indices.contains(row), mirror.lines[row].cells.indices.contains(column) else { return nil }
        if let link = mirror.link(column: column, row: row) { return explicit(link, in: mirror) }
        return detected(atColumn: column, row: row, in: mirror)
    }

    /// Every cell on screen in `link`: the same id and URI, on any row.
    static func explicit(_ link: Hyperlink, in mirror: MirrorGrid) -> LinkHit {
        var spans: [LinkHit.Span] = []
        var text = ""
        for (y, line) in mirror.lines.enumerated() {
            // Compared by the row's own index for the link, not string by string.
            guard let slot = line.links.firstIndex(of: link) else { continue }
            let index = UInt16(slot + 1)
            var start: Int?
            for x in 0...line.cells.count {
                if x < line.cells.count && line.cells[x].linkIndex == index {
                    if start == nil { start = x }
                    if line.cells[x].width != .spacerTail { text += shown(line, at: x) }
                } else if let begin = start {
                    spans.append(LinkHit.Span(row: y, columns: begin..<x))
                    start = nil
                }
            }
        }
        return LinkHit(uri: link.uri, text: text, spans: spans, isExplicit: true)
    }

    /// A URL in the logical line through the cell: the rows soft wraps join, so a long URL
    /// that wrapped is found whole.
    static func detected(atColumn column: Int, row: Int, in mirror: MirrorGrid) -> LinkHit? {
        var first = row
        while first > 0 && mirror.lines[first - 1].isWrapped { first -= 1 }
        var last = row
        while last < mirror.lines.count - 1 && mirror.lines[last].isWrapped { last += 1 }

        var characters: [Character?] = []
        var rowStarts: [Int] = []
        for y in first...last {
            let line = mirror.lines[y]
            rowStarts.append(characters.count)
            for x in line.cells.indices {
                switch line.cells[x].width {
                // The right half of a wide character, or the gap a wide one left when it
                // wrapped: nothing of their own to show.
                case .spacerTail, .spacerHead: characters.append(nil)
                // Its first character: a cell's scalars need not make one (a letter and a
                // zero-width space are two), and the URL rules look at one.
                case .narrow, .wide: characters.append(shown(line, at: x).first ?? " ")
                }
            }
        }
        let offset = rowStarts[row - first] + column
        guard let found = URLDetector.url(in: characters, at: offset) else { return nil }
        var spans: [LinkHit.Span] = []
        for (index, start) in rowStarts.enumerated() {
            let end = start + mirror.lines[first + index].cells.count
            let covered = found.columns.clamped(to: start..<end)
            if !covered.isEmpty {
                spans.append(
                    LinkHit.Span(
                        row: first + index, columns: (covered.lowerBound - start)..<(covered.upperBound - start)))
            }
        }
        return LinkHit(uri: found.url, text: found.url, spans: spans, isExplicit: false)
    }

    /// What a cell shows, a space when empty.
    private static func shown(_ line: RowSnapshot, at column: Int) -> String {
        let scalars = line.scalars(at: column).compactMap(Unicode.Scalar.init)
        guard !scalars.isEmpty else { return " " }
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        return text
    }
}
