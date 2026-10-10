import Foundation
import VTCore

public struct SearchQuery: Sendable, Equatable {
    public static let longestNeedle = 1024
    public var needle: String
    public var caseSensitive: Bool
    public var startLine: UInt64?

    public init(_ needle: String, caseSensitive: Bool = false, startLine: UInt64? = nil) {
        self.needle = needle
        self.caseSensitive = caseSensitive
        self.startLine = startLine
    }
}

public struct SearchPage: Sendable, Equatable {
    public static let mostMatches = 256
    public let generation: UInt64
    public let matches: [TextRegion]
    public let nextLine: UInt64?
    /// More matches existed than this page could return.
    public let limited: Bool

    public init(generation: UInt64, matches: [TextRegion], nextLine: UInt64?, limited: Bool = false) {
        self.generation = generation
        self.matches = matches
        self.nextLine = nextLine
        self.limited = limited
    }
}

extension Terminal {
    /// Bounded pages keep search from monopolizing the session thread. The overlap at a
    /// page boundary covers a needle split by soft wrapping; callers deduplicate regions.
    public func search(_ query: SearchQuery) -> SearchPage {
        guard !query.needle.isEmpty, query.needle.utf16.count <= SearchQuery.longestNeedle else {
            return SearchPage(generation: generation, matches: [], nextLine: nil)
        }
        let first = linesScrolledOff - UInt64(scrollbackCount)
        let last = linesScrolledOff + UInt64(rows - 1)
        let start = max(first, query.startLine ?? first)
        guard start <= last else { return SearchPage(generation: generation, matches: [], nextLine: nil) }
        let end = min(last, start + 2047)
        var text = ""
        var starts: [TextPoint] = []
        var ends: [TextPoint] = []
        var matches: [TextRegion] = []
        var limited = false

        func findMatches() {
            var position = text.startIndex
            let options: String.CompareOptions = query.caseSensitive ? [.literal] : [.caseInsensitive]
            while position < text.endIndex,
                let found = text.range(of: query.needle, options: options, range: position..<text.endIndex)
            {
                let lower = text.utf16.distance(from: text.utf16.startIndex, to: found.lowerBound)
                let upper = text.utf16.distance(from: text.utf16.startIndex, to: found.upperBound)
                guard upper > lower, upper <= starts.count else { break }
                if matches.count == SearchPage.mostMatches { limited = true; break }
                matches.append(TextRegion(starts[lower], ends[upper - 1]))
                position = found.upperBound
            }
        }

        for number in start...end {
            guard let row = line(number) else { continue }
            for column in row.cells.indices {
                let cell = row.cells[column]
                if cell.width == .spacerHead || cell.width == .spacerTail { continue }
                let scalars = row.scalars(at: column)
                let value =
                    scalars.isEmpty
                    ? " " : String(String.UnicodeScalarView(scalars.map { Unicode.Scalar($0) ?? "\u{FFFD}" }))
                text += value
                let point = TextPoint(line: number, column: column)
                let tail = TextPoint(
                    line: number, column: min(row.cells.count - 1, column + (cell.width == .wide ? 1 : 0)))
                starts.append(contentsOf: repeatElement(point, count: value.utf16.count))
                ends.append(contentsOf: repeatElement(tail, count: value.utf16.count))
            }
            if !row.isWrapped || text.utf16.count >= 65_536 || number == end {
                if !row.isWrapped {
                    while text.last == " " { text.removeLast(); starts.removeLast(); ends.removeLast() }
                }
                findMatches()
                if limited { break }
                if row.isWrapped && number != end {
                    // Keep enough trailing cells for a match crossing a large logical line.
                    let keep = min(SearchQuery.longestNeedle, text.utf16.count)
                    let units = Array(text.utf16.suffix(keep))
                    text = String(decoding: units, as: UTF16.self)
                    starts = Array(starts.suffix(keep))
                    ends = Array(ends.suffix(keep))
                } else {
                    text = ""; starts.removeAll(keepingCapacity: true); ends.removeAll(keepingCapacity: true)
                }
            }
        }
        let overlap = UInt64(min(1024, query.needle.utf16.count * 2 / max(1, columns) + 2))
        let consumed = limited ? (matches.last?.end.line ?? end) : end
        let next = consumed < last ? max(start + 1, consumed + 1 - min(overlap, consumed + 1)) : nil
        return SearchPage(generation: generation, matches: matches, nextLine: next, limited: limited)
    }
}
