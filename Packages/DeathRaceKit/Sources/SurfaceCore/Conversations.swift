import ScreenProtocol
import VTCore

/// One command and everything it printed, bounded to lines.
///
/// Lines rather than cells, and that is a consequence of what a mark can say: `PromptMarks` is
/// an `OptionSet` on a row, so it cannot tell you which of two marks on one row came first, and
/// it records no column — while a short command's prompt, command and output all share one row,
/// which is the common case. What makes a line-bounded run enough is that the command's own text
/// no longer has to be recovered from the screen: the shell sends it (`OSC 633;E`).
public struct BlockRun: Sendable, Equatable {
    /// From the line its prompt started on to the line before the next prompt — or to the last
    /// line in view, for the block you are typing in.
    public var lines: ClosedRange<UInt64>
    /// What the shell said about the command that ended in it: nil while it is still running,
    /// and nil for every block when no integration is installed.
    public var command: CommandRecord?
    /// The block the cursor is in: the one you are working in, and the only one with a band.
    public var isCurrent: Bool

    public init(lines: ClosedRange<UInt64>, command: CommandRecord? = nil, isCurrent: Bool = false) {
        self.lines = lines
        self.command = command
        self.isCurrent = isCurrent
    }

    /// Whether it ended badly; nil when the shell said nothing about how it ended, which is not
    /// the same as saying it went well.
    public var failed: Bool? {
        guard let code = command?.exitCode else { return nil }
        return code != 0
    }

    /// How many lines it covers, for a rail drawn as one instance.
    public var rows: Int { Int(lines.upperBound - lines.lowerBound) + 1 }
}

/// The blocks in view, read from the grid.
///
/// From the grid and never from the event stream, on purpose: `TerminalEvent.coalesced` keeps
/// only the newest 64 prompt marks per burst, and the `commandEnd`s are the ones you most need —
/// a loop of fast commands would silently drop the oldest. Rebuilt from scratch on every frame,
/// with nothing cached and nothing to invalidate: a viewport is a few dozen rows, and the row
/// ids a cache would have to key on are minted afresh by reflow.
public enum Blocks {

    /// Every block whose prompt is in view, plus the one above the first of them — so the rail
    /// of a command whose output fills the screen still reaches the top edge.
    ///
    /// A limit worth knowing rather than discovering: scrolled so far into one command's output
    /// that its prompt is gone, there is nothing in view to say a block is there at all, and
    /// none is drawn. The mirror holds only the viewport, so the honest fix is to ask the engine
    /// — which owns the scrollback — and that is the same query jumping between prompts needs.
    public static func runs(in mirror: MirrorGrid) -> [BlockRun] {
        // A full-screen program draws its own screen: a rail down the side of vim is wrong, and
        // the marks on the alternate screen are whatever it happened to print.
        guard !mirror.isAlternateScreen, !mirror.lines.isEmpty else { return [] }
        let top = mirror.viewportTopLine
        let last = top &+ UInt64(mirror.lines.count - 1)

        var starts: [UInt64] = []
        for (y, row) in mirror.lines.enumerated() where row.promptMarks.contains(.promptStart) {
            starts.append(top &+ UInt64(y))
        }
        // No prompt in view is how a terminal with no integration looks, and it is also how one
        // looks in the middle of a long command's output. Drawing nothing is right for the first
        // and the best this can do for the second.
        guard let first = starts.first else { return [] }

        // The cursor is placed in the active area, so the viewport's own scroll has to be added
        // back to find the line it is on — the same sum `updateCursor` makes. Deliberately not
        // clamped to the viewport: scrolled back through history the cursor's line is below the
        // last one in view, and clamping it would hand "current" to whatever row happened to be
        // at the bottom of the screen.
        let cursorLine = top &+ UInt64(max(mirror.cursor.y + mirror.viewportOffset, 0))

        var bounds: [ClosedRange<UInt64>] = []
        if first > top { bounds.append(top...(first - 1)) }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] - 1 : last
            if start <= end { bounds.append(start...end) }
        }

        return bounds.map { range in
            BlockRun(lines: range, command: command(in: range, of: mirror), isCurrent: range.contains(cursorLine))
        }
    }

    /// The command record in a block: the last one, because the engine takes marks from the
    /// stream by design and cannot tell whose bytes they are — a program that printed a mark of
    /// its own earlier is overruled by the shell's, which always comes after the output.
    private static func command(in lines: ClosedRange<UInt64>, of mirror: MirrorGrid) -> CommandRecord? {
        var found: CommandRecord?
        for line in lines {
            if let command = mirror.line(line)?.command { found = command }
        }
        return found
    }
}

extension Blocks {

    /// How far to scroll to put `line` at the top of the viewport, in `scroll(by:)`'s own sign:
    /// positive goes back into history, negative toward the output.
    ///
    /// This is why jumping between prompts needs no absolute scroll, which the phase's plan had
    /// budgeted for. The engine answers with a line number, the view already knows which line is
    /// at the top, and the difference is the relative scroll the session has always taken.
    public static func scroll(toPut line: UInt64, atTopOf mirror: MirrorGrid) -> Int {
        let top = mirror.viewportTopLine
        if line == top { return 0 }
        // Clamped rather than wrapped: a line number from another process could be anything, and
        // a wrap would scroll hard the other way.
        if line < top { return Int(clamping: top - line) }
        return -Int(clamping: line - top)
    }

    /// Every line of `span`, selected as triple-clicking each of them would — so copying it gives
    /// the command and its output and nothing else.
    ///
    /// Line granularity rather than a character range on purpose: a block is bounded to lines,
    /// because `PromptMarks` records no column and a short command's prompt, command and output
    /// share one row. `mirror.line` is the same closure the mouse path passes, so a line the
    /// mirror no longer holds is handled the way it already is — the caller scrolls first.
    public static func selection(of span: PromptSpan, in mirror: MirrorGrid) -> Selection {
        let read: (UInt64) -> (any TextLine)? = { mirror.line($0) }
        var selection = Selection(
            at: Selection.Point(line: span.lines.lowerBound, column: 0, boundary: 0), granularity: .line,
            rectangular: false, columns: mirror.columns, line: read)
        selection.extend(
            to: Selection.Point(line: span.lines.upperBound, column: 0, boundary: 0), columns: mirror.columns,
            line: read)
        return selection
    }
}
