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
    /// What the shell said about the command that ended on this row: its text, how long it
    /// took, how it went. Only rows carrying `.commandEnd` have one.
    public internal(set) var command: CommandRecord?
    /// The exit code from a `commandEnd` mark, when the shell sent one.
    public var exitCode: Int32? { command?.exitCode }
    /// The OSC 8 links the row's cells belong to; a cell's `linkIndex` counts from 1.
    public internal(set) var links: ContiguousArray<Hyperlink> = []
    /// The most links one row holds; past it, characters print without their link.
    public static let linkLimit = 1024

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

    /// The link the cell at `column` belongs to.
    public func link(at column: Int) -> Hyperlink? {
        guard cells.indices.contains(column) else { return nil }
        let index = Int(cells[column].linkIndex)
        return index > 0 && index <= links.count ? links[index - 1] : nil
    }

    /// The row's index for `link`, counting from 1 and adding it if needed; 0 when the row
    /// holds `linkLimit` links that are all in use.
    func linkIndex(for link: Hyperlink) -> UInt16 {
        // Characters of one link print one after another: the last link is the usual answer.
        if let last = links.last, last == link { return UInt16(links.count) }
        if let index = links.firstIndex(of: link) { return UInt16(index + 1) }
        if links.count >= Self.linkLimit {
            compactLinks()
            guard links.count < Self.linkLimit else { return 0 }
        }
        links.append(link)
        return UInt16(links.count)
    }

    /// Drops links no cell uses any more and renumbers the cells.
    func compactLinks() {
        var used = [Bool](repeating: false, count: links.count + 1)
        for cell in cells where Int(cell.linkIndex) <= links.count { used[Int(cell.linkIndex)] = true }
        var remap = [UInt16](repeating: 0, count: links.count + 1)
        var kept: ContiguousArray<Hyperlink> = []
        for index in links.indices where used[index + 1] {
            kept.append(links[index])
            remap[index + 1] = UInt16(kept.count)
        }
        for column in cells.indices where cells[column].linkIndex != 0 {
            let index = Int(cells[column].linkIndex)
            cells[column].linkIndex = index < remap.count ? remap[index] : 0
        }
        links = kept
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
        let blank = Cell.blank(styleID: fill == .default ? 0 : styleID(for: fill))
        if cells.count != columns {
            cells = ContiguousArray(repeating: blank, count: columns)
        } else if blank == .empty {
            // A default blank cell is all zero bits: clear the row like memory.
            _ = cells.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        } else {
            cells.withUnsafeMutableBufferPointer { $0.update(repeating: blank) }
        }
        graphemes.removeAll()
        links.removeAll(keepingCapacity: true)
        isWrapped = false
        promptMarks = []
        command = nil
    }

    /// Changes the width without rewrapping: truncates or pads with default blanks.
    func setColumns(_ columns: Int) {
        if columns < cells.count {
            cells.removeLast(cells.count - columns)
            graphemes = graphemes.filter { $0.key < columns }
            // A wide character cut in half goes, extra scalars and all.
            if columns > 0 && cells[columns - 1].width == .wide {
                cells[columns - 1] = .blank(styleID: cells[columns - 1].styleID)
                graphemes[columns - 1] = nil
            }
        } else if columns > cells.count {
            cells.append(contentsOf: repeatElement(.empty, count: columns - cells.count))
        }
    }

    /// Approximate memory use, for the scrollback budget.
    var estimatedBytes: Int {
        var bytes = 96 + cells.count * MemoryLayout<Cell>.stride + styles.count * MemoryLayout<Style>.stride
        for extra in graphemes.values { bytes += 48 + extra.count * MemoryLayout<UInt32>.stride }
        for link in links { bytes += 48 + link.id.utf8.count + link.uri.utf8.count }
        return bytes
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

/// One command, as the shell reported it: `OSC 633;E` for the text, and `OSC 133;D` for the
/// exit code and the duration.
///
/// The shell is asked for all three rather than the terminal working them out, because the
/// shell knows them exactly and the terminal does not. A duration in particular cannot be
/// measured here: VTCore is deliberately Foundation-free and has no clock, and a command that
/// ran while the app was closed — the case the session daemon exists for — was never watched
/// by anything that could have timed it.
public struct CommandRecord: Equatable, Sendable {
    /// The command line, capped at `textLimit` bytes of UTF-8 and stripped of controls.
    public var text: String
    /// How long it ran, from `dur=` on the `D` mark; nil when the shell did not say.
    public var durationMilliseconds: UInt32?
    /// Its exit status, from the bare parameter on the `D` mark; nil when the shell did not say.
    public var exitCode: Int32?

    /// A command line longer than this is cut. Deltas carry rows, so an unbounded string here
    /// would be an unbounded string on every frame that touched the row.
    public static let textLimit = 1024

    public init(text: String = "", durationMilliseconds: UInt32? = nil, exitCode: Int32? = nil) {
        self.text = text
        self.durationMilliseconds = durationMilliseconds
        self.exitCode = exitCode
    }

    /// Whether there is anything worth keeping. A record of three nils is not worth a frame.
    public var isEmpty: Bool { text.isEmpty && durationMilliseconds == nil && exitCode == nil }
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
