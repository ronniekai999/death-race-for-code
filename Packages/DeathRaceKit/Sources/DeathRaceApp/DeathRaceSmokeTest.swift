import AppKit
import ConfigKit
import CoreText
import Dispatch
import Foundation
import PTYKit
import RenderKit
import ScreenProtocol
import SessionKit
import SurfaceCore
import VTCore

/// `DeathRace --smoke-test`: the headless end-to-end check macOS CI runs against the bundled
/// app. It needs no window and no GPU, and goes as far as the machine allows:
///
/// 1. a shell answers on a pseudo-terminal;
/// 2. a real session prints bold red 999, and the app's mirror of its screen has it;
/// 3. CoreText rasterizes those glyphs and the frame builder places them, red;
/// 4. with a Metal device, the frame is rendered offscreen and its pixels checked: the
///    background where nothing is written, red where a 9 is. `--write-frame FILE` saves it as
///    a PNG to look at;
/// 5. the bundled fonts register, and a Nerd Font icon draws from Symbols Nerd Font Mono
///    through SF Mono's fallback list.
///
/// Shells start with `zsh -f`, so no rc file can change the outcome.
public enum DeathRaceSmokeTest {
    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    public static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        print("Death Race \(DeathRaceApplication.version) smoke test")
        let launch = ShellLaunch(
            executable: "/bin/zsh",
            arguments: ["zsh", "-f"],
            environment: ShellLaunch.terminalEnvironment(
                inheriting: ShellLaunch.processEnvironment(), appVersion: DeathRaceApplication.version))
        var failed = false
        func step(_ name: String, _ body: () throws -> String) {
            do {
                print("  ok    \(name): \(try body())")
            } catch {
                print("  FAIL  \(name): \(error)")
                failed = true
            }
        }

        step("pseudo-terminal") {
            try SmokeTest.run(launch)
            return "zsh ran a command"
        }
        var mirror = MirrorGrid()
        step("session") {
            mirror = try printInSession(launch)
            return "bold red 999 reached the mirror"
        }
        let theme = Theme.legendsNeverDie
        let fonts = FontSet(family: "SF Mono", size: 13)
        let cell = fonts.cellMetrics(scale: 2)
        let glyphs = GlyphCache(rasterizer: GlyphRasterizer(fonts: fonts, cell: cell))
        var frame: Frame?
        step("glyphs") {
            // Rasterizing has a budget per frame, so a screen of new glyphs takes a few frames,
            // as it does in a window.
            let (built, frames) = FrameBuilder().buildComplete(
                mirror: mirror, theme: theme, cell: cell, selection: nil, glyphs: glyphs)
            guard built.isComplete else { throw Failure("glyphs still missing after \(frames) frames") }
            try checkGlyphs(built, mirror: mirror, red: mirror.palette.colors[1])
            frame = built
            return "CoreText drew the screen at \(cell.width)×\(cell.height) px cells in \(frames) frames; 999 is red"
        }
        if let frame {
            step("Metal") { try render(frame, cell: cell, glyphs: glyphs, mirror: mirror, arguments: arguments) }
        }
        step("fonts") { try checkFonts() }
        print(failed ? "smoke test failed" : "smoke test passed")
        return failed ? 1 : 0
    }

    /// The bundled fonts register for this process, and a prompt's folder icon (nf-fa-folder,
    /// U+F07B) is drawn from Symbols Nerd Font Mono, not from whatever the system would pick.
    @MainActor
    private static func checkFonts() throws -> String {
        let report = FontRegistry.registerBundledFonts()
        guard let directory = report.directory else { throw Failure("no Fonts directory") }
        guard report.failed.isEmpty else {
            throw Failure("did not register: \(report.failed.joined(separator: "; "))")
        }
        let families = Set(NSFontManager.shared.availableFontFamilies)
        let missing = (FontRegistry.bundledFamilies + [FontRegistry.symbolsFamily]).filter { !families.contains($0) }
        guard missing.isEmpty else { throw Failure("missing \(missing.joined(separator: ", "))") }

        let fonts = FontSet(family: "SF Mono", size: 13)
        let folder = GlyphKey(scalar: 0xF07B)
        let rasterizer = GlyphRasterizer(fonts: fonts, cell: fonts.cellMetrics(scale: 2))
        let used = CTFontCopyFamilyName(rasterizer.face(for: folder)) as String
        guard used == FontRegistry.symbolsFamily else {
            throw Failure("the folder icon came from \(used), not \(FontRegistry.symbolsFamily)")
        }
        guard rasterizer.rasterize(folder).pixels.contains(where: { $0 > 128 }) else {
            throw Failure("the folder icon drew nothing")
        }
        return "\(report.registered.count) files from \(directory.lastPathComponent); a prompt's icon draws from"
            + " \(FontRegistry.symbolsFamily)"
    }

    /// Runs `printf` in a real session and returns the mirror once the output is in it.
    private static func printInSession(_ launch: ShellLaunch) throws -> MirrorGrid {
        let updates = DispatchSemaphore(value: 0)
        let session = try Session(
            launch: launch,
            configuration: Terminal.Configuration(columns: 80, rows: 24, palette: Theme.legendsNeverDie.palette),
            onUpdate: { updates.signal() })
        defer { session.close() }
        session.send(Array("printf '\\033[1;31m%s\\033[0m\\n' 999\n".utf8))
        var mirror = MirrorGrid()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            while let delta = session.takeDelta() {
                do {
                    try mirror.apply(delta)
                } catch {
                    session.requestSnapshot()
                }
            }
            if boldRed999(in: mirror) != nil { return mirror }
            _ = updates.wait(timeout: .now() + .milliseconds(100))
        }
        throw Failure("no bold red 999 within 10 seconds")
    }

    /// Where the output 999 is: its row and first column. The command line itself also has
    /// 999 in it, but not in bold red.
    static func boldRed999(in mirror: MirrorGrid) -> (row: Int, column: Int)? {
        for (y, line) in mirror.lines.enumerated() {
            for x in 0..<max(0, line.cells.count - 2) {
                let isBoldRed999 = (x..<x + 3).allSatisfy { column in
                    let cell = line.cells[column]
                    let style = line.style(of: cell)
                    return cell.scalar == 0x39 && style.attributes.contains(.bold)
                        && style.foreground == .indexed(1)
                }
                if isBoldRed999 { return (y, x) }
            }
        }
        return nil
    }

    private static func checkGlyphs(_ frame: Frame, mirror: MirrorGrid, red: RGB) throws {
        guard let found = boldRed999(in: mirror) else { throw Failure("no 999 to draw") }
        let (row, column) = found
        let nines = frame.glyphs.filter { Int($0.cellY) == row && (column..<column + 3).contains(Int($0.cellX)) }
        guard nines.count == 3 else { throw Failure("\(nines.count) glyphs where 999 is") }
        guard nines.allSatisfy({ $0.color == red.packed && $0.width > 0 && $0.height > 0 && $0.flags == 0 }) else {
            throw Failure("the 9s are not red coverage glyphs: \(nines)")
        }
    }

    @MainActor
    private static func render(
        _ frame: Frame, cell: CellMetrics, glyphs: GlyphCache, mirror: MirrorGrid, arguments: [String]
    )
        throws -> String
    {
        let renderer: OffscreenRenderer
        do {
            renderer = try OffscreenRenderer()
        } catch RenderError.noDevice {
            return "skipped, no Metal device"
        }
        let padding = (x: 16, y: 12)
        let layout = PixelLayout(
            width: frame.columns * cell.width + 2 * padding.x, height: frame.rows * cell.height + 2 * padding.y,
            originX: padding.x, originY: padding.y)
        let image = try renderer.render(frame, cell: cell, layout: layout, glyphs: glyphs)
        if let index = arguments.firstIndex(of: "--write-frame"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            guard let png = image.pngData(), FileManager.default.createFile(atPath: path, contents: png) else {
                throw Failure("could not write \(path)")
            }
        }

        let background = mirror.palette.background
        let red = mirror.palette.colors[1]
        func close(_ pixel: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8), _ color: RGB, within: Int) -> Bool {
            abs(Int(pixel.red) - Int(color.red)) <= within && abs(Int(pixel.green) - Int(color.green)) <= within
                && abs(Int(pixel.blue) - Int(color.blue)) <= within
        }
        // The padding and an empty cell are the background.
        guard close(image.pixel(x: 1, y: 1), background, within: 2) else {
            throw Failure("the padding is \(image.pixel(x: 1, y: 1)), not the background")
        }
        guard let found = boldRed999(in: mirror) else { throw Failure("no 999") }
        let (row, column) = found
        let emptyX = padding.x + (frame.columns - 1) * cell.width + cell.width / 2
        let emptyY = padding.y + row * cell.height + cell.height / 2
        guard close(image.pixel(x: emptyX, y: emptyY), background, within: 2) else {
            throw Failure("an empty cell is \(image.pixel(x: emptyX, y: emptyY)), not the background")
        }
        // Somewhere in the first 9 the glyph is solid red.
        var closest = Int.max
        for y in (padding.y + row * cell.height)..<(padding.y + (row + 1) * cell.height) {
            for x in (padding.x + column * cell.width)..<(padding.x + (column + 1) * cell.width) {
                let pixel = image.pixel(x: x, y: y)
                let distance = max(
                    abs(Int(pixel.red) - Int(red.red)), abs(Int(pixel.green) - Int(red.green)),
                    abs(Int(pixel.blue) - Int(red.blue)))
                closest = min(closest, distance)
            }
        }
        guard closest <= 24 else { throw Failure("no red in the 9's cell (closest pixel is \(closest) away)") }
        return
            "rendered \(image.width)×\(image.height) on \(renderer.device.name); padding, empty cells and text are right"
    }
}
