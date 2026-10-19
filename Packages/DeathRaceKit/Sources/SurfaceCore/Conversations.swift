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
    /// From the line its prompt started on to the line before the next prompt — or, for the
    /// block you are typing in, to the cursor or the last line written below it.
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
    /// Scrolled back, the rows below the view finish the last block in it: its record is on
    /// the next prompt's row, which is down there, and the session sends what those rows say
    /// (`MirrorGrid.outcomeBelow`). That is also what lets a view entirely inside one command's
    /// output — scrolled up to read a failure — show a rail: it is one block, and the rows
    /// below say how it ended. A command still running there shows nothing, as no prompt in
    /// view and nothing below is also how a terminal with no integration looks.
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
        let cursorLine = Self.cursorLine(in: mirror)

        // No prompt in view is how a terminal with no integration looks, and it is also how one
        // looks in the middle of a long command's output. With an outcome from below it is the
        // second, and the whole view is that command's.
        guard let first = starts.first else {
            guard mirror.viewportOffset > 0, let outcome = mirror.outcomeBelow else { return [] }
            return [BlockRun(lines: top...last, command: outcome, isCurrent: (top...last).contains(cursorLine))]
        }

        var bounds: [ClosedRange<UInt64>] = []
        if first > top { bounds.append(top...(first - 1)) }
        for (index, start) in starts.enumerated() {
            // The block being typed in ends at the cursor, or lower if something was written
            // below it — not at the bottom of the screen. The rows under a prompt are empty, and
            // a band down them marks nothing. Scrolled back, the cursor is below the view and
            // the block runs to its last line, which is right: it does go on.
            let end =
                index + 1 < starts.count
                ? starts[index + 1] - 1 : min(last, max(cursorLine, lastWritten(in: mirror, from: start, to: last)))
            if start <= end { bounds.append(start...end) }
        }

        return bounds.enumerated().map { index, range in
            let next = index + 1 < bounds.count ? bounds[index + 1].lowerBound : nil
            // Scrolled back, the last block goes on below the view, and its record is down
            // there with the next prompt: the session says what the rows below hold. Those
            // rows come after the ones in view, so what they say is the later word.
            let below = next == nil && mirror.viewportOffset > 0 && range.upperBound == last ? mirror.outcomeBelow : nil
            return BlockRun(
                lines: range, command: below ?? command(in: range, before: next, of: mirror),
                isCurrent: range.contains(cursorLine))
        }
    }

    /// The record of the command a block holds.
    ///
    /// The shell sends `D` from the hook that draws the next prompt, so it lands at the start of
    /// that prompt's row: a block's record is on the row the next block starts on, and one on a
    /// block's own prompt row is the block above's (after `clear`, a command no longer on screen).
    /// Otherwise the last one wins, because the engine takes marks from the stream by design and
    /// cannot tell whose bytes they are — a mark a program printed is overruled by the shell's,
    /// which always comes after the output.
    private static func command(
        in lines: ClosedRange<UInt64>, before next: UInt64?, of mirror: MirrorGrid
    ) -> CommandRecord? {
        var found: CommandRecord?
        for line in lines {
            guard let row = mirror.line(line), let command = row.command else { continue }
            if line == lines.lowerBound, row.promptMarks.contains(.promptStart) { continue }
            found = command
        }
        if let next, let row = mirror.line(next), row.promptMarks.contains(.promptStart), let command = row.command {
            found = command
        }
        return found
    }

    /// The last line from `start` to `end` with anything written on it, or `start`.
    private static func lastWritten(in mirror: MirrorGrid, from start: UInt64, to end: UInt64) -> UInt64 {
        var line = end
        while line > start {
            if let row = mirror.line(line), row.cells.contains(where: { !$0.isEmpty }) { return line }
            line -= 1
        }
        return start
    }
}

extension Blocks {

    /// The line the cursor is on.
    ///
    /// The cursor is placed in the active area, so the viewport's own scroll has to be added
    /// back — the same sum `updateCursor` makes. Deliberately not clamped to the viewport:
    /// scrolled back through history the cursor's line is below the last one in view, and
    /// clamping it would hand "the block you are in" to whatever row happened to be at the
    /// bottom of the screen.
    ///
    /// Shared rather than written twice because both callers depend on it agreeing: the band is
    /// drawn around this line, and ⌘⇧A asks the engine about it.
    public static func cursorLine(in mirror: MirrorGrid) -> UInt64 {
        mirror.viewportTopLine &+ UInt64(max(mirror.cursor.y + mirror.viewportOffset, 0))
    }

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
        // Only the block's own rows are visible to the unit walk. `.line` granularity follows
        // `isWrapped` outward in *both* directions, so a block whose last output line happened
        // to fill the width would swallow the next command's prompt row, and a prompt row that
        // is itself a continuation would reach back into the block above. Hiding the neighbours
        // stops the walk at the block's edges, which is what "nothing of the next one" means.
        let read: (UInt64) -> (any TextLine)? = { span.lines.contains($0) ? mirror.line($0) : nil }
        var selection = Selection(
            at: Selection.Point(line: span.lines.lowerBound, column: 0, boundary: 0), granularity: .line,
            rectangular: false, columns: mirror.columns, line: read)
        selection.extend(
            to: Selection.Point(line: span.lines.upperBound, column: 0, boundary: 0), columns: mirror.columns,
            line: read)
        return selection
    }
}
