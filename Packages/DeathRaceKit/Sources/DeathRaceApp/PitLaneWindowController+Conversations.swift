import AppKit
import SurfaceCore
import VTCore

extension PitLaneWindowController {
    // MARK: - Conversations: walking between commands, and selecting one

    /// Selects the block the cursor is in: the command and its output, and nothing of the next.
    @objc func selectCommand(_ sender: Any?) {
        guard let pane = pane(of: sender) else { return }
        selectBlock(around: nil, in: pane)
    }

    @objc func jumpToPreviousPrompt(_ sender: Any?) { jump(back: true, in: pane(of: sender)) }
    @objc func jumpToNextPrompt(_ sender: Any?) { jump(back: false, in: pane(of: sender)) }

    /// Puts the prompt either side of the top of the view at the top of the view.
    ///
    /// Asked of the session rather than worked out here: the mirror holds only the viewport, so
    /// a prompt that has scrolled away is not in it, and after a reattach none of them are. The
    /// answer is a line number, and `scroll(by:)` has always been relative, so the move is a
    /// subtraction — no absolute scroll is needed anywhere.
    private func jump(back: Bool, in pane: PaneController?) {
        guard let pane, let model = pane.surface.model, let generation = model.mirror.generation else { return }
        let session = pane.session
        let from = model.mirror.viewportTopLine
        Task { @MainActor in
            guard let span = await session?.promptSpan(at: from, generation: generation) else { return }
            // Going back from inside a block means the top of this one, then the one before it;
            // going forward always means the next. Nothing there is not a failure — it is the
            // oldest or newest command, and the screen stays where it is.
            let target: UInt64? =
                back
                ? (span.lines.lowerBound < from ? span.lines.lowerBound : span.previousPrompt) : span.nextPrompt
            // The same generation check `selectBlock` makes. Line numbers survive a reflow, so
            // that much the subtraction can take — but an alternate-screen switch landing in
            // the await renumbers what is at the top, and a relative scroll against it is an
            // arbitrary jump. Doing nothing is the right answer to "the screen changed".
            guard let target, let now = pane.surface.model?.mirror, now.generation == generation else { return }
            let lines = Blocks.scroll(toPut: target, atTopOf: now)
            if lines != 0 { session?.scroll(by: lines) }
        }
    }

    /// Brings the command the status bar's Fast run is about back into view.
    ///
    /// Scrolls and no more. Selecting it would be a second useful thing to do and the wrong one
    /// here: `copy-on-select` is a setting people have on, and a tap on the status bar is not a
    /// request to change the clipboard.
    func scrollToLastCommand() {
        guard let pane = activePane, let line = pane.lastCommandLine, let model = pane.surface.model,
            let generation = model.mirror.generation
        else { return }
        let session = pane.session
        Task { @MainActor in
            // A line the engine has since trimmed out of its scrollback answers nil, and the
            // screen stays where it is rather than jumping somewhere arbitrary.
            guard let span = await session?.promptSpan(at: line, generation: generation),
                let now = pane.surface.model?.mirror, now.generation == generation
            else { return }
            let lines = Blocks.scroll(toPut: span.lines.lowerBound, atTopOf: now)
            if lines != 0 { session?.scroll(by: lines) }
        }
    }

    /// Selects the block at `line`, or the one the cursor is in when nil.
    ///
    /// The runs in view are enough for a click on a rail, which is only drawn for a block that
    /// is on screen. The cursor's own block can be off screen, so that one is asked of the
    /// session, which is the same query the jump uses.
    func selectBlock(around line: UInt64?, in pane: PaneController) {
        guard let model = pane.surface.model, let generation = model.mirror.generation else { return }
        if let line, let run = Blocks.runs(in: model.mirror).first(where: { $0.lines.contains(line) }) {
            pane.surface.select(
                Blocks.selection(of: PromptSpan(lines: run.lines, command: run.command), in: model.mirror),
                generation: generation)
            return
        }
        let session = pane.session
        let cursor = Blocks.cursorLine(in: model.mirror)
        Task { @MainActor in
            guard let span = await session?.promptSpan(at: line ?? cursor, generation: generation),
                let now = pane.surface.model?.mirror, now.generation == generation
            else { return }
            pane.surface.select(Blocks.selection(of: span, in: now), generation: generation)
        }
    }

}
