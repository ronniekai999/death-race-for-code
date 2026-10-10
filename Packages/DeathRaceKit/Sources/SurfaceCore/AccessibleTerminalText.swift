import Foundation
import ScreenProtocol
import VTCore

/// A bounded, read-only text view of the viewport, with UTF-16 ranges for AppKit AX.
/// Cell widths and combining scalars map to text once; wide spacer cells never duplicate it.
public struct AccessibleTerminalText: Sendable {
    public let text: String
    public let points: [TextPoint]
    public let lineRanges: [NSRange]

    public init(mirror: MirrorGrid) {
        var text = ""
        var points: [TextPoint] = []
        var ranges: [NSRange] = []
        for (index, row) in mirror.lines.enumerated() {
            let start = points.count
            for column in row.cells.indices {
                let cell = row.cells[column]
                if cell.width == .spacerHead || cell.width == .spacerTail { continue }
                let scalars = row.scalars(at: column)
                let value =
                    scalars.isEmpty
                    ? " " : String(String.UnicodeScalarView(scalars.map { Unicode.Scalar($0) ?? "\u{FFFD}" }))
                if points.count + value.utf16.count > 262_144 { break }
                text += value
                points.append(
                    contentsOf: repeatElement(
                        TextPoint(line: mirror.viewportTopLine + UInt64(index), column: column),
                        count: value.utf16.count))
            }
            ranges.append(NSRange(location: start, length: points.count - start))
            if points.count >= 262_142 { break }
            if index + 1 < mirror.lines.count {
                text += "\n"
                points.append(TextPoint(line: mirror.viewportTopLine + UInt64(index), column: mirror.columns))
            }
        }
        self.text = text
        self.points = points
        lineRanges = ranges
    }

    public func range(for region: TextRegion?) -> NSRange {
        guard let region, let first = points.firstIndex(where: { region.contains($0) }),
            let last = points.lastIndex(where: { region.contains($0) })
        else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first, length: last - first + 1)
    }

    public func substring(_ range: NSRange) -> String? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
            range.location <= points.count, range.length <= points.count - range.location
        else { return nil }
        return (text as NSString).substring(with: range)
    }

    public func line(at index: Int) -> Int {
        lineRanges.lastIndex { $0.location <= index } ?? 0
    }
}
