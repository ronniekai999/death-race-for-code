import AppKit
import SurfaceCore
import TerminalUI
import Testing

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    /// The box, in the window's points, around every pixel `surface.drawCursor(in:)` draws
    /// into a picture of `window` at its backing scale. Nil if it draws nothing.
    func drawnCursor(of surface: TerminalSurfaceView, in window: NSWindow) -> CGRect? {
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
        surface.drawCursor(in: context)
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

    /// The cursor is a layer of its own, which a pane's offscreen frame leaves out, so a
    /// picture of the pane draws it over the frame: on its cell.
    @Test func aPictureOfAPaneHasItsCursorOnItsCell() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let pane = try #require(controller.activePane)
        let session = try #require(pane.session as? FakeSession)
        let surface = pane.surface

        session.replay.feed("abc\r\nde")
        surface.sessionDidUpdate()
        let rect = CellGeometry(cell: surface.cell, layout: surface.grid).rect(column: 2, row: 1)
        let cell = surface.convert(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), to: nil)
        // Within a pixel: a cell's edges need not fall on whole points.
        let pixel = 1 / window.backingScaleFactor
        func onItsCell(_ drawn: CGRect?) -> Bool {
            guard let drawn else { return false }
            return abs(drawn.minX - cell.minX) <= pixel && abs(drawn.maxX - cell.maxX) <= pixel
                && abs(drawn.minY - cell.minY) <= pixel && abs(drawn.maxY - cell.maxY) <= pixel
        }
        await eventually(within: 5) { onItsCell(drawnCursor(of: surface, in: window)) }
        let drawn = drawnCursor(of: surface, in: window)
        #expect(onItsCell(drawn), "the cursor is drawn at \(String(describing: drawn)); its cell is at \(cell)")
    }
}
