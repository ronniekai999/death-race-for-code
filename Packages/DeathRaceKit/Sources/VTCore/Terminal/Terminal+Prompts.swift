/// One command's block, found by its prompt, with the prompts either side of it.
///
/// This is the answer to the one question the app cannot work out for itself. `MirrorGrid` holds
/// only the viewport, so a prompt that has scrolled out of view is simply not there to be found
/// — and after a reattach the app has seen no history at all, which is the case Legends Never
/// Die exists for. The engine owns the scrollback, so it is the engine that answers.
///
/// One span serves both things that needed asking: `lines` bounds a block for selecting it, and
/// `previousPrompt` / `nextPrompt` are where ⌘↑ and ⌘↓ go. One round trip rather than two.
public struct PromptSpan: Hashable, Sendable {
    /// From the line the prompt starts on to the line before the next prompt — or the last line
    /// the screen has, for the block being typed in.
    public var lines: ClosedRange<UInt64>
    /// What the shell said about the command in it: nil while it is still running, and nil for
    /// every block when no integration is installed.
    public var command: CommandRecord?
    /// The prompt line of the block before this one; nil when this is the oldest kept.
    public var previousPrompt: UInt64?
    /// The prompt line of the block after this one; nil when this is the newest.
    public var nextPrompt: UInt64?

    public init(
        lines: ClosedRange<UInt64>, command: CommandRecord? = nil, previousPrompt: UInt64? = nil,
        nextPrompt: UInt64? = nil
    ) {
        self.lines = lines
        self.command = command
        self.previousPrompt = previousPrompt
        self.nextPrompt = nextPrompt
    }
}

extension Terminal {

    /// How many lines back `promptSpan(at:)` will look for the prompt that starts a block.
    ///
    /// A bound rather than the whole ring, because a screen with no integration installed has no
    /// marks at all: every one of these calls would otherwise walk all of scrollback, and ⌘↑ held
    /// down would walk it again per keypress. Generous against real use — a command printing more
    /// than this many lines without a prompt is a build log, and its block starts off the top of
    /// what we will claim to know.
    public static let promptSearchLimit = 50_000

    /// The block `line` falls in, or nil when no prompt can be found around it.
    ///
    /// Nil is the honest answer in two cases that are not failures: the alternate screen, whose
    /// marks are whatever a full-screen program happened to print, and a screen with no prompt
    /// within `promptSearchLimit` lines above — which is what no shell integration looks like.
    ///
    /// Taken from the rows themselves rather than from the event stream, for the reason
    /// `Blocks.runs` is: `TerminalEvent.coalesced` keeps only the newest 64 prompt marks per
    /// burst, and a loop of fast commands drops the oldest — the `commandEnd`s you most want.
    /// `limit` is a seam, not a knob: the real one would make a test that overruns it allocate
    /// tens of thousands of rows, heavy enough to starve its neighbours under Thread Sanitizer —
    /// the same reason `SFTPClient.Limits` is injectable.
    public func promptSpan(at line: UInt64, limit: Int = Terminal.promptSearchLimit) -> PromptSpan? {
        // A full-screen program draws its own screen. A block inside vim is not a thing.
        guard !isAlternateScreen else { return nil }
        let oldest = linesScrolledOff - UInt64(scrollbackCount)
        let newest = linesScrolledOff + UInt64(rows) - 1
        guard oldest <= newest else { return nil }
        let asked = min(max(line, oldest), newest)

        // The prompt at or above `asked`, and the one above that.
        var start: UInt64?
        var previous: UInt64?
        var walked = 0
        var cursor = asked
        while walked <= limit {
            if isPromptStart(cursor) {
                if start == nil {
                    start = cursor
                } else {
                    previous = cursor
                    break
                }
            }
            if cursor == oldest { break }
            cursor &-= 1
            walked += 1
        }
        guard let start else { return nil }

        // The next prompt below it bounds the block; without one the block runs to the last line
        // the screen has, which is the one being typed in.
        //
        // Bounded by `limit` as the walk above is. One command with a hundred thousand lines of
        // output made this walk all of them on the session thread, which is the cost the other
        // bound exists to prevent.
        var next: UInt64?
        var below = start
        var forward = 0
        while below < newest, forward < limit {
            below &+= 1
            forward += 1
            if isPromptStart(below) {
                next = below
                break
            }
        }
        // `below` is the last line actually examined: `newest` when the walk ran out of screen,
        // the bound when it ran out of allowance. Claiming `newest` in the second case would
        // hand a selection every block below it, none of which was looked at.
        let end = next.map { $0 - 1 } ?? below

        return PromptSpan(
            lines: start...end, command: command(in: start...end), previousPrompt: previous,
            nextPrompt: next)
    }

    /// The command record in a block: the last one, because the engine takes marks from the
    /// stream by design and cannot tell whose bytes they are — a program that printed a mark of
    /// its own earlier is overruled by the shell's, which always comes after the output.
    /// Found by walking up from the end rather than down from the start: the answer is the last
    /// record in the range either way, and the shell's `commandEnd` is on or near the block's
    /// last row, so this is one lookup where the forward walk was a second pass over every line
    /// of the output.
    private func command(in lines: ClosedRange<UInt64>) -> CommandRecord? {
        var line = lines.upperBound
        while true {
            if let command = storedRow(line)?.command { return command }
            if line == lines.lowerBound { return nil }
            line &-= 1
        }
    }

    private func isPromptStart(_ line: UInt64) -> Bool {
        storedRow(line)?.promptMarks.contains(.promptStart) ?? false
    }

    /// The row holding `line`, from the active area or from scrollback, or nil when the number is
    /// outside what this screen still has. The arithmetic is `linesScrolledOff`'s own, stated
    /// where it is defined: the active row `y` is line `linesScrolledOff + y`, and scrollback row
    /// `i` is line `linesScrolledOff - scrollbackCount + i`.
    ///
    /// That subtraction rests on `linesScrolledOff >= scrollbackCount`, which holds because every
    /// row entering the scrollback goes through `pushToScrollback` and increments the count, and
    /// trimming only removes rows. Reflow is the one place that could break it — it replaces the
    /// scrollback wholesale and a narrowing turns one line into two — so
    /// `reflowKeepsTheArithmeticTheSpanDependsOn` pins it rather than leaving it assumed; an
    /// underflow here would be a trap, not a wrong answer.
    private func storedRow(_ line: UInt64) -> Row? {
        if line >= linesScrolledOff {
            let y = Int(line - linesScrolledOff)
            guard y < rows else { return nil }
            return row(y)
        }
        let back = Int(linesScrolledOff - line)
        guard back <= scrollbackCount else { return nil }
        return scrollbackRow(scrollbackCount - back)
    }
}
