import AppKit
import ConfigKit
import ScreenProtocol
import SurfaceCore
import TerminalUI
import Testing
import VTCore

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the screen
// with.
extension WindowTests {

    /// What a shell with the integration installed sends for one command.
    private func transcript(_ text: String, exit: Int32, milliseconds: UInt32) -> String {
        "\u{1B}]133;A\u{7}$ \(text)\u{1B}]133;B\u{7}\u{1B}]633;E;\(text)\u{7}\u{1B}]133;C\u{7}"
            + "\u{1B}]133;D;\(exit);dur=\(milliseconds)\u{7}"
    }

    /// The box, in the window's points, around every pixel `surface.drawBadges(in:)` draws into
    /// a picture of `window` at its backing scale. Nil if it draws nothing.
    ///
    /// The same shape as `drawnCursor`, for the same reason: a badge is a layer, which a pane's
    /// offscreen frame leaves out, so a picture of the pane has to draw it over the frame.
    func drawnBadges(of surface: TerminalSurfaceView, in window: NSWindow) -> CGRect? {
        let scale = window.backingScaleFactor
        let size = window.contentView?.bounds.size ?? .zero
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        surface.drawBadges(in: context)
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var (left, right, top, bottom) = (width, -1, height, -1)
        for row in 0..<height {
            for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 0 {
                left = min(left, column)
                right = max(right, column)
                top = min(top, row)
                bottom = max(bottom, row)
            }
        }
        guard right >= 0 else { return nil }
        // The bitmap's first row is the picture's top; the window's y runs up.
        return CGRect(
            x: CGFloat(left) / scale, y: CGFloat(height - 1 - bottom) / scale,
            width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    /// What the badge path saw, for a failure message. A badge needs a run, a run with a
    /// command, and a picture for it; which of those is missing says where to look, so a
    /// failure on CI — the only place these run — costs one round rather than three.
    private func badgeState(of surface: TerminalSurfaceView) -> String {
        guard let mirror = surface.model?.mirror else { return "the session had sent no screen" }
        let runs = Blocks.runs(in: mirror)
        return "grid \(surface.grid.columns)x\(surface.grid.rows), \(mirror.lines.count) lines,"
            + " top \(mirror.viewportTopLine), \(runs.count) run(s),"
            + " \(runs.compactMap(\.command).count) with a command,"
            + " makeBadge \(surface.makeBadge == nil ? "nil" : "set")"
    }

    /// The window's own points for a viewport row, so a badge can be checked against the line
    /// it is about rather than against a number.
    private func rowRect(of surface: TerminalSurfaceView, row: Int) -> CGRect {
        let rect = CellGeometry(cell: surface.cell, layout: surface.grid).rect(column: 0, row: row)
        return surface.convert(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), to: nil)
    }

    // MARK: - What the frame draws

    /// The rail and the band ride in the `Frame`, so they cost no rows and need no layer. What
    /// this pins down is that the pane turns them on at all, and off when asked.
    @Test func aPaneDrawsBlockChromeOnlyWhenItIsAskedTo() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let pane = try #require(controller.activePane)
        #expect(pane.surface.blockColors != nil, "on by default, with the integration on by default")
        #expect(pane.surface.makeBadge != nil)

        var off = Config()
        off.conversations = false
        controller.apply(off)
        #expect(pane.surface.blockColors == nil, "and the terminal draws exactly what it drew before")
        #expect(pane.surface.makeBadge == nil)

        // Turning the integration off takes it with it: there is nothing to draw without it.
        var noIntegration = Config()
        noIntegration.shellIntegration = false
        controller.apply(noIntegration)
        #expect(pane.surface.blockColors == nil)
    }

    // MARK: - The badge

    /// A badge is a layer over the Metal frame, placed with it, and it belongs to the line its
    /// command's prompt is on — at the right-hand end, as the board draws it.
    @Test func aSlowCommandsBadgeIsOnItsOwnLine() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface

        // Row 0: a command slow enough to be worth a word. Row 1: the prompt after it.
        session.replay.feed(transcript("swift build", exit: 0, milliseconds: 12_400))
        session.replay.feed("\r\n\u{1B}]133;A\u{7}$ ")
        surface.sessionDidUpdate()

        await eventually(within: 5) { drawnBadges(of: surface, in: window) != nil }
        let drawn = try #require(
            drawnBadges(of: surface, in: window), "no badge was drawn: \(badgeState(of: surface))")
        let row = rowRect(of: surface, row: 0)
        // On the command's own line, within a pixel of it, and at the right-hand end.
        let pixel = 1 / window.backingScaleFactor
        #expect(drawn.midY >= row.minY - pixel && drawn.midY <= row.maxY + pixel, "drawn at \(drawn), row \(row)")
        #expect(drawn.maxX > surface.convert(surface.bounds, to: nil).midX, "right-aligned, not left")
    }

    /// Most commands. A badge over every `ls` is noise, and twenty of them are twenty layers.
    @Test func aQuickCommandGetsNoBadge() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface

        session.replay.feed(transcript("ls", exit: 0, milliseconds: 8))
        session.replay.feed("\r\n\u{1B}]133;A\u{7}$ ")
        surface.sessionDidUpdate()
        // Long enough for a frame to have been drawn, then nothing: a badge that was going to
        // appear would be there by now.
        await eventually(within: 1) { false }
        #expect(drawnBadges(of: surface, in: window) == nil)
    }

    /// A failure is the thing you most need to see, however fast it was.
    @Test func aFailedCommandGetsABadgeHoweverFastItWas() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface

        session.replay.feed(transcript("false", exit: 1, milliseconds: 4))
        session.replay.feed("\r\n\u{1B}]133;A\u{7}$ ")
        surface.sessionDidUpdate()
        await eventually(within: 5) { drawnBadges(of: surface, in: window) != nil }
        #expect(drawnBadges(of: surface, in: window) != nil, "no badge was drawn: \(badgeState(of: surface))")
    }

    /// A badge is pinned to its command's line, so it has to move with the screen — which is
    /// why it is placed inside the transaction that presents the frame.
    @Test func aBadgeFollowsItsCommandWhenTheScreenScrolls() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface

        // Fill the screen first, so the command lands on the last row. A window is 100x30 by
        // default: with room to spare below it one more line scrolls nothing, and a badge that
        // never had to move proves nothing. Exactly one row of slack is what is wanted — pushed
        // off the top the command's prompt is gone from view and gets no badge by design.
        session.replay.feed(String(repeating: "filler\r\n", count: max(surface.grid.rows - 1, 1)))
        session.replay.feed(transcript("swift build", exit: 0, milliseconds: 12_400))
        surface.sessionDidUpdate()
        await eventually(within: 5) { drawnBadges(of: surface, in: window) != nil }
        let before = try #require(
            drawnBadges(of: surface, in: window), "no badge was drawn: \(badgeState(of: surface))")
        let topBefore = try #require(surface.model?.mirror.viewportTopLine)

        // One more line of output pushes the screen up by a row, the command's line with it.
        session.replay.feed("\r\nanother line")
        surface.sessionDidUpdate()
        await eventually(within: 5) { (surface.model?.mirror.viewportTopLine ?? topBefore) > topBefore }
        // The premise, asserted rather than assumed: without a scroll there is nothing to follow.
        let topAfter = try #require(surface.model?.mirror.viewportTopLine)
        #expect(topAfter > topBefore, "the screen never scrolled: \(badgeState(of: surface))")

        await eventually(within: 5) { drawnBadges(of: surface, in: window).map { $0.minY != before.minY } ?? false }
        let after = try #require(
            drawnBadges(of: surface, in: window), "the badge went away: \(badgeState(of: surface))")
        // It moved by the one row the screen scrolled. Checked as a distance, not a direction,
        // so it does not depend on which way the window's y runs.
        let pixel = 1 / window.backingScaleFactor
        let moved = abs(after.minY - before.minY)
        let rowHeight = CGFloat(surface.cell.pointHeight)
        #expect(
            abs(moved - rowHeight) <= pixel,
            "the badge moved \(moved) pt for a one-row scroll of \(rowHeight) pt")
    }

    /// With Conversations off there are no layers over the grid at all.
    @Test func noBadgeIsDrawnWithConversationsOff() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface

        session.replay.feed(transcript("swift build", exit: 0, milliseconds: 12_400))
        surface.sessionDidUpdate()
        await eventually(within: 5) { drawnBadges(of: surface, in: window) != nil }

        var off = Config()
        off.conversations = false
        controller.apply(off)
        surface.sessionDidUpdate()
        await eventually(within: 1) { false }
        #expect(drawnBadges(of: surface, in: window) == nil)
    }
}
