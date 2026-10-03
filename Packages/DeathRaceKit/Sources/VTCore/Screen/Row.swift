/// One line of the grid, with everything needed to draw it: cells, the styles they use, and
/// the extra scalars of multi-scalar characters.
///
/// Each row interns its own styles, so a cell's style index fits in 16 bits whatever the
/// program does (a row cannot hold more distinct styles than it has cells), and a row is
/// self-contained when it travels to the app in a screen delta.
///
/// Rows are reference types owned by one screen buffer on the session thread. Moving a row
/// (scrolling, scroll regions) moves a reference; nothing is copied.
public final class Row {
    /// Stable while the row lives, across scrolling; renderers and deltas key on it.
    public internal(set) var id: UInt64
    /// Bumped on every change to the row's content; the session sends rows whose version
    /// moved. Scrolling moves rows without changing them, so it leaves versions alone.
    public internal(set) var version: UInt64 = 0
    public internal(set) var cells: ContiguousArray<Cell>
    public internal(set) var styles: ContiguousArray<Style>
    /// Extra scalars for cells with `hasGrapheme`, keyed by column.
    public internal(set) var graphemes: [Int: [UInt32]] = [:]
    /// The line continues on the next row (soft wrap). Reflow joins wrapped rows.
    public internal(set) var isWrapped = false
    /// The OSC 133 marks the shell placed on this row. One row often carries several: the
    /// previous command's end and the next prompt's start, or a prompt and its command.
    public internal(set) var promptMarks: PromptMarks = []
    /// The exit code from a `commandEnd` mark, when the shell sent one.
    public internal(set) var exitCode: Int32?

    /// Lookup from style to index, built only once a row has many styles.
    private var styleIndex: [Style: UInt16]?
    private static let linearSearchLimit = 12

    init(id: UInt64, columns: Int, fill: Style = .default) {
        self.id = id
        self.styles = [.default]
        let fillID: UInt16 = fill == .default ? 0 : 1
        if fillID == 1 { styles.append(fill) }
        self.cells = ContiguousArray(repeating: .blank(styleID: fillID), count: columns)
    }

    public var columns: Int { cells.count }

    @inlinable
    public func style(of cell: Cell) -> Style {
        let index = Int(cell.styleID)
        return index < styles.count ? styles[index] : .default
    }

    /// The scalars of the character at `column`: its base scalar and any that combine with it.
    public func scalars(at column: Int) -> [UInt32] {
        let cell = cells[column]
        guard !cell.isEmpty else { return [] }
        if cell.hasGrapheme, let extra = graphemes[column] { return [cell.scalar] + extra }
        return [cell.scalar]
    }

    /// The row's index for `style`, adding it if needed.
    func styleID(for style: Style) -> UInt16 {
        if style == .default { return 0 }
        if let styleIndex {
            if let id = styleIndex[style] { return id }
        } else if styles.count <= Self.linearSearchLimit {
            for index in 1..<styles.count where styles[index] == style { return UInt16(index) }
        }
        // Stale styles accumulate as cells are overwritten; compact before growing past what
        // the cells could possibly use.
        if styles.count >= max(cells.count + 1, 32) || styles.count >= Int(UInt16.max) {
            compactStyles()
            if let id = styleIndex?[style] { return id }
            if styleIndex == nil {
                for index in 1..<styles.count where styles[index] == style { return UInt16(index) }
            }
        }
        let id = UInt16(styles.count)
        styles.append(style)
        if styleIndex != nil {
            styleIndex![style] = id
        } else if styles.count > Self.linearSearchLimit {
            buildIndex()
        }
        return id
    }

    private func buildIndex() {
        var index: [Style: UInt16] = [:]
        index.reserveCapacity(styles.count)
        for (i, style) in styles.enumerated() where i > 0 { index[style] = UInt16(i) }
        styleIndex = index
    }

    /// Drops styles no cell uses and renumbers the cells.
    func compactStyles() {
        var used = [Bool](repeating: false, count: styles.count)
        used[0] = true
        for cell in cells { used[Int(cell.styleID)] = true }
        var remap = [UInt16](repeating: 0, count: styles.count)
        var kept: ContiguousArray<Style> = [.default]
        for index in 1..<styles.count where used[index] {
            remap[index] = UInt16(kept.count)
            kept.append(styles[index])
        }
        for column in cells.indices {
            cells[column].styleID = remap[Int(cells[column].styleID)]
        }
        styles = kept
        styleIndex = nil
        if styles.count > Self.linearSearchLimit { buildIndex() }
    }

    /// Empties the row for reuse: blank cells in `fill`, no wrap, no marks.
    func reset(id: UInt64, columns: Int, fill: Style) {
        self.id = id
        styles.removeAll(keepingCapacity: true)
        styles.append(.default)
        styleIndex = nil
        let fillID = fill == .default ? 0 : styleID(for: fill)
        cells.removeAll(keepingCapacity: true)
        cells.append(contentsOf: repeatElement(.blank(styleID: fillID), count: columns))
        graphemes.removeAll()
        isWrapped = false
        promptMarks = []
        exitCode = nil
    }

    /// Changes the width without rewrapping: truncates or pads with default blanks.
    func setColumns(_ columns: Int) {
        if columns < cells.count {
            cells.removeLast(cells.count - columns)
            graphemes = graphemes.filter { $0.key < columns }
            // A wide character cut in half loses its right half.
            if columns > 0 && cells[columns - 1].width == .wide {
                cells[columns - 1] = .blank(styleID: cells[columns - 1].styleID)
            }
        } else if columns > cells.count {
            cells.append(contentsOf: repeatElement(.empty, count: columns - cells.count))
        }
    }

    /// Approximate memory use, for the scrollback budget.
    var estimatedBytes: Int {
        96 + cells.count * MemoryLayout<Cell>.stride + styles.count * MemoryLayout<Style>.stride
            + graphemes.count * 48
    }

    /// The index one past the last cell that holds a character or a colored background.
    var contentLength: Int {
        var end = cells.count
        while end > 0 {
            let cell = cells[end - 1]
            guard cell.isEmpty && cell.styleID == 0 && cell.width != .spacerTail else { break }
            end -= 1
        }
        return end
    }

    /// Nothing on the row: no characters, no colored cells, no prompt marks.
    var isBlank: Bool { contentLength == 0 && promptMarks.isEmpty }
}

/// Where the shell said a prompt, a command, or its output begins (OSC 133).
public enum PromptMark: Equatable, Sendable {
    case promptStart
    case commandStart
    case outputStart
    case commandEnd(exitCode: Int32?)
}

/// The OSC 133 marks on one row.
public struct PromptMarks: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let promptStart = PromptMarks(rawValue: 1 << 0)
    public static let commandStart = PromptMarks(rawValue: 1 << 1)
    public static let outputStart = PromptMarks(rawValue: 1 << 2)
    public static let commandEnd = PromptMarks(rawValue: 1 << 3)
}
