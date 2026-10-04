#if DEBUG
    import AppCore
    import AppKit
    import ConfigKit
    import ImageIO
    import PTYKit
    import RenderKit
    import SessionKit
    import SurfaceCore
    import TerminalUI
    import UniformTypeIdentifiers
    import VTCore

    /// A shell that is only a script: what it printed is fed in, and it says which program
    /// runs where, as a pane's pill and status bar ask.
    final class ScriptedSession: PaneSession, @unchecked Sendable {
        let replay: ReplaySession
        let foreground: ForegroundProcess

        init(_ configuration: Terminal.Configuration, program: String, directory: String) {
            replay = ReplaySession(configuration)
            foreground = ForegroundProcess(
                pid: 1, name: program, workingDirectory: directory, isShell: program == "zsh")
        }

        func takeDelta() -> ScreenDelta? { replay.takeDelta() }
        var status: Session.Status { .running }
        func send(_ bytes: [UInt8]) -> Bool { replay.send(bytes) }
        func sendReport(_ bytes: [UInt8]) -> Bool { replay.sendReport(bytes) }
        func resize(columns: Int, rows: Int, cellPixelWidth: Int, cellPixelHeight: Int) {
            replay.resize(
                columns: columns, rows: rows, cellPixelWidth: cellPixelWidth, cellPixelHeight: cellPixelHeight)
        }
        func scroll(by lines: Int) { replay.scroll(by: lines) }
        func scrollToBottom() { replay.scrollToBottom() }
        func requestSnapshot() { replay.requestSnapshot() }
        func setFocused(_ focused: Bool) { replay.setFocused(focused) }
        func setBasePalette(_ palette: Palette) { replay.setBasePalette(palette) }
        func clear(_ kind: Terminal.ClearKind) { replay.clear(kind) }
        func text(in range: TextRegion, generation: UInt64) async -> String? {
            await replay.text(in: range, generation: generation)
        }
        func foregroundProcess() async -> ForegroundProcess? { foreground }
        func close() {}
    }

    /// `DeathRace --render-chrome DIR` (debug builds): the Pit Lane in each of the eight themes,
    /// with Hear Me Calling and Settings, as PNGs for review without building the app.
    ///
    /// No screen recording is needed. The layer tree draws the chrome; each pane's Metal layer
    /// is not in it, so the pane's own frame is drawn offscreen and put where the layer is. The
    /// window server's part is missing: the traffic lights and the glow's blur.
    @MainActor
    public enum ChromePreview {
        static let size = NSSize(width: 1180, height: 720)
        static var directory: String { NSHomeDirectory() + "/code/death-race-for-code" }

        /// What each pane runs, in order: the first tab's two panes, then a tab each.
        static let scripts: [(program: String, output: String)] = [
            (
                "zsh",
                "\u{1B}[38;5;213m❯\u{1B}[0m swift build\r\n"
                    + "\u{1B}[2m[412/412]\u{1B}[0m Linking DeathRace\r\n"
                    + "\u{1B}[32mBuild complete!\u{1B}[0m \u{1B}[2m(12.4s)\u{1B}[0m\r\n"
                    + "\u{1B}[38;5;213m❯\u{1B}[0m ls --hyperlink\r\n"
                    + "\u{1B}]8;;file:///tmp/App\u{1B}\\\u{1B}[1;34mApp\u{1B}[0m\u{1B}]8;;\u{1B}\\  "
                    + "\u{1B}]8;;file:///tmp/Makefile\u{1B}\\Makefile\u{1B}]8;;\u{1B}\\  "
                    + "\u{1B}[1;34mPackages\u{1B}[0m  README.md  \u{1B}[1;34mdocs\u{1B}[0m\r\n"
                    + "\u{1B}[38;5;213m❯\u{1B}[0m "
            ),
            (
                "make",
                "\u{1B}[38;5;213m❯\u{1B}[0m make test\r\n"
                    + "\u{1B}[32m✔\u{1B}[0m Suite \u{1B}[1mThemeCatalogTests\u{1B}[0m passed\r\n"
                    + "\u{1B}[32m✔\u{1B}[0m Suite \u{1B}[1mSplitTreeTests\u{1B}[0m passed\r\n"
                    + "\u{1B}[31m✘\u{1B}[0m Test \u{1B}[1mlinksSurviveReflow()\u{1B}[0m failed\r\n"
                    + "  \u{1B}[33mExpectation failed:\u{1B}[0m uris == expected\r\n"
                    + "See https://github.com/ronniekai999/death-race-for-code\r\n"
            ),
            ("vim", "\u{1B}]2;notes.md\u{7}\u{1B}[1m# Legends Never Die\u{1B}[0m\r\n\r\n- 999\r\n- Lucid Dreams\r\n"),
            ("ssh", "\u{1B}]2;prod-api\u{7}prod-api ~ \u{1B}[32m$\u{1B}[0m uptime\r\n 18:42  up 99 days\r\n"),
        ]

        public static func run(arguments: [String]) -> Int32 {
            let index = arguments.firstIndex(of: "--render-chrome")!
            let folder = URL(
                fileURLWithPath: index + 1 < arguments.count ? arguments[index + 1] : "build/chrome",
                isDirectory: true)
            do {
                _ = NSApplication.shared
                FontRegistry.registerBundledFonts()
                NSWindow.allowsAutomaticWindowTabbing = false
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let renderer = try? OffscreenRenderer()
                if renderer == nil { print("no Metal device: the panes are left empty") }
                for theme in ThemeCatalog.all {
                    try write(window(theme: theme, renderer: renderer, palette: false), to: folder, name: theme.id)
                }
                try write(
                    window(theme: ThemeCatalog.default, renderer: renderer, palette: true), to: folder,
                    name: "hear-me-calling")
                try write(settings(), to: folder, name: "settings")
                print("wrote \(ThemeCatalog.all.count + 2) pictures to \(folder.path)")
                return 0
            } catch {
                FileHandle.standardError.write(Data("render-chrome: \(error)\n".utf8))
                return 1
            }
        }

        struct Failure: Error, CustomStringConvertible {
            let description: String
        }

        // MARK: - The scene

        @MainActor
        private final class Host: WindowHost {
            let ids = IDSource()
            var scripts = ChromePreview.scripts
            private(set) var sessions: [ScriptedSession] = []
            var makeSession: SessionMaker {
                { [unowned self] _, configuration, _ in
                    let script: (program: String, output: String) =
                        self.scripts.isEmpty ? ("zsh", "") : self.scripts.removeFirst()
                    let session = ScriptedSession(
                        configuration, program: script.program, directory: ChromePreview.directory)
                    session.replay.feed(script.output)
                    self.sessions.append(session)
                    return session
                }
            }
            func windowClosed(_ controller: PitLaneWindowController) {}
            func inputStateChanged() {}
            func open(
                detached tab: TabModel, panes: [PaneController], area: PaneAreaView,
                from controller: PitLaneWindowController
            ) {}
            func places(from controller: PitLaneWindowController) -> [PaletteItem] {
                controller.places(isCurrent: true)
            }
            func focus(pane: PaneID, from controller: PitLaneWindowController) {}
            func chooseTheme(_ id: String) throws {}
            func showSettings(page: SettingsCatalog.Page?) {}
            var recentPicks: [String] { [] }
            func picked(_ id: String) {}
        }

        /// A window in `theme`: a split tab, two more tabs, and with `palette` Hear Me Calling
        /// open over it.
        private static func window(theme: NamedTheme, renderer: OffscreenRenderer?, palette: Bool) throws -> CGImage {
            var config = Config()
            config.themeID = theme.id
            let host = Host()
            let controller = PitLaneWindowController(config: config, host: host, directory: directory)
            defer { controller.window?.close() }
            controller.window?.setContentSize(size)
            controller.showWindow(nil)
            controller.splitRight(nil)
            try wait("the split") { controller.panes.count == 2 }
            controller.newTab(nil)
            try wait("the second tab") { controller.model.tabs.count == 2 }
            controller.newTab(nil)
            try wait("the third tab") { controller.model.tabs.count == 3 }
            // Back to the split tab, its left pane in use.
            _ = controller.selectTab(number: 1)
            _ = controller.selectPane(number: 1)
            for pane in controller.panes.values { pane.surface.sessionDidUpdate() }
            try wait("the panes' screens") {
                controller.panes.values.allSatisfy { $0.surface.model?.mirror.generation != nil }
            }
            settle()
            if palette {
                controller.showHearMeCalling(nil)
                if let overlay = controller.hearMeCalling {
                    overlay.field.stringValue = "theme"
                    overlay.controlTextDidChange(
                        Notification(name: NSControl.textDidChangeNotification, object: overlay.field))
                }
                settle()
            }
            return try picture(of: controller, renderer: renderer)
        }

        private static func settings() throws -> CGImage {
            let config = Config()
            let chrome = Chrome(config.namedTheme)
            let model = SettingsModel(
                config: config, palette: LegendsPalette(chrome), filePath: "~/.config/deathrace/config")
            let controller = SettingsWindowController(model: model, chrome: chrome)
            defer { controller.window?.close() }
            controller.show(page: .appearance)
            settle()
            guard let view = controller.window?.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { throw Failure(description: "no picture of the Settings window") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { throw Failure(description: "an empty Settings picture") }
            return image
        }

        // MARK: - Pictures

        /// The window's content: the chrome from the layer tree, each shown pane's own frame
        /// where its Metal layer is, then Hear Me Calling over both.
        private static func picture(of controller: PitLaneWindowController, renderer: OffscreenRenderer?) throws
            -> CGImage
        {
            guard let window = controller.window, let content = window.contentView, let layer = content.layer else {
                throw Failure(description: "the window has no layer")
            }
            let scale = window.backingScaleFactor
            let width = Int(content.bounds.width * scale)
            let height = Int(content.bounds.height * scale)
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw Failure(description: "no bitmap") }
            context.scaleBy(x: scale, y: scale)

            let overlay = controller.hearMeCalling
            overlay?.isHidden = true
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            layer.render(in: context)
            if let renderer, let tab = controller.model.activeTab {
                for id in tab.panes {
                    guard let surface = controller.panes[id]?.surface, !surface.isHiddenOrHasHiddenAncestor,
                        let image = try surface.snapshot(using: renderer)?.cgImage()
                    else { continue }
                    context.draw(image, in: surface.convert(surface.bounds, to: nil))
                }
            }
            if let overlay, let overlayLayer = overlay.layer {
                overlay.isHidden = false
                overlay.displayIfNeeded()
                overlayLayer.render(in: context)
            }
            guard let image = context.makeImage() else { throw Failure(description: "no picture") }
            return image
        }

        private static func write(_ image: CGImage, to folder: URL, name: String) throws {
            let url = folder.appendingPathComponent("\(name).png")
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw Failure(description: "cannot write \(url.path)") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw Failure(description: "cannot write \(url.path)")
            }
        }

        // MARK: - Waiting

        /// Runs the main run loop, where the windows' tasks and display links do their work,
        /// until `done` or five seconds.
        private static func wait(_ what: String, until done: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while !done() {
                guard Date() < deadline else { throw Failure(description: "timed out waiting for \(what)") }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }

        /// A moment for layout, drawing and display links to catch up.
        private static func settle() {
            let until = Date().addingTimeInterval(0.4)
            while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
    }
#endif
