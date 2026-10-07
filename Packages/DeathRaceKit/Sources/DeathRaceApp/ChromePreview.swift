#if DEBUG
    import AppCore
    import AppKit
    import ConfigKit
    import ImageIO
    import PTYKit
    import RenderKit
    import SFTPKit
    import SSHKit
    import ScreenProtocol
    import SessionKit
    import SurfaceCore
    import TerminalUI
    import UniformTypeIdentifiers
    import VTCore
    import Vault

    /// A shell that is only a script: what it printed is fed in, and it says which program
    /// runs where, as a pane's pill and status bar ask.
    final class ScriptedSession: PaneSession, @unchecked Sendable {
        let replay: ReplaySession
        let id = SessionID.next()
        let foreground: ForegroundProcess
        var outlivesItsClient: Bool { false }

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
        func promptSpan(at line: UInt64, generation: UInt64) async -> PromptSpan? {
            await replay.promptSpan(at: line, generation: generation)
        }
        func foregroundProcess() async -> ForegroundProcess? { foreground }
        func close() {}
        func detach() {}
    }

    /// `DeathRace --render-chrome DIR` (debug builds): the Pit Lane in each of the eight themes,
    /// as PNGs for review without building the app.
    ///
    /// No screen recording is needed. The layer tree draws the chrome; each pane's Metal layer
    /// is not in it, so the pane's own frame is drawn offscreen and put where the layer is, its
    /// cursor over it. The window server's part is missing: the traffic lights and the glow's
    /// blur. SwiftUI's windows (Settings, Hear Me Calling's rows) are left out: drawn this way
    /// their text comes out flipped in places, which would mislead more than it shows.
    @MainActor
    public enum ChromePreview {
        static let size = NSSize(width: 1180, height: 720)
        static var directory: String { NSHomeDirectory() + "/code/death-race-for-code" }

        /// What each pane runs, in order: the first tab's two panes, then a tab each.
        static let scripts: [(program: String, output: String)] = [
            // With the shell integration's marks, so every theme's picture shows Conversations:
            // a rail beside each command, a badge on the slow one, and the band on the prompt
            // being typed at. A ⌘-less `ls` is quick enough to get no badge, which is the point.
            (
                "zsh",
                "\u{1B}]133;A\u{7}\u{1B}[38;5;213m❯\u{1B}[0m swift build\u{1B}]133;B\u{7}"
                    + "\u{1B}]633;E;swift build\u{7}\u{1B}]133;C\u{7}\r\n"
                    + "\u{1B}[2m[412/412]\u{1B}[0m Linking DeathRace\r\n"
                    + "\u{1B}[32mBuild complete!\u{1B}[0m \u{1B}[2m(12.4s)\u{1B}[0m"
                    + "\u{1B}]133;D;0;dur=12400\u{7}\r\n"
                    + "\u{1B}]133;A\u{7}\u{1B}[38;5;213m❯\u{1B}[0m ls --hyperlink\u{1B}]133;B\u{7}"
                    + "\u{1B}]633;E;ls --hyperlink\u{7}\u{1B}]133;C\u{7}\r\n"
                    + "\u{1B}]8;;file:///tmp/App\u{1B}\\\u{1B}[1;34mApp\u{1B}[0m\u{1B}]8;;\u{1B}\\  "
                    + "\u{1B}]8;;file:///tmp/Makefile\u{1B}\\Makefile\u{1B}]8;;\u{1B}\\  "
                    + "\u{1B}[1;34mPackages\u{1B}[0m  README.md  \u{1B}[1;34mdocs\u{1B}[0m"
                    + "\u{1B}]133;D;0;dur=14\u{7}\r\n"
                    + "\u{1B}]133;A\u{7}\u{1B}[38;5;213m❯\u{1B}[0m \u{1B}]133;B\u{7}"
            ),
            // And one that failed, for the rail and badge a failure gets however fast it was.
            (
                "make",
                "\u{1B}]133;A\u{7}\u{1B}[38;5;213m❯\u{1B}[0m make test\u{1B}]133;B\u{7}"
                    + "\u{1B}]633;E;make test\u{7}\u{1B}]133;C\u{7}\r\n"
                    + "\u{1B}[32m✔\u{1B}[0m Suite \u{1B}[1mThemeCatalogTests\u{1B}[0m passed\r\n"
                    + "\u{1B}[32m✔\u{1B}[0m Suite \u{1B}[1mSplitTreeTests\u{1B}[0m passed\r\n"
                    + "\u{1B}[31m✘\u{1B}[0m Test \u{1B}[1mlinksSurviveReflow()\u{1B}[0m failed\r\n"
                    + "  \u{1B}[33mExpectation failed:\u{1B}[0m uris == expected\r\n"
                    + "See https://github.com/ronniekai999/death-race-for-code"
                    + "\u{1B}]133;D;1;dur=48000\u{7}\r\n"
            ),
            ("vim", "\u{1B}]2;notes.md\u{7}\u{1B}[1m# Legends Never Die\u{1B}[0m\r\n\r\n- 999\r\n- Lucid Dreams\r\n"),
            ("ssh", "\u{1B}]2;prod-api\u{7}prod-api ~ \u{1B}[32m$\u{1B}[0m uptime\r\n 18:42  up 99 days\r\n"),
        ]

        /// The armed picture's panes: three servers taking the same deploy, as on the board.
        static let armedScripts: [(program: String, output: String)] = (1...3).map { number in
            let deploy =
                "\u{1B}[38;5;213m❯\u{1B}[0m ./deploy.sh prod --version 2.4.1\r\n"
                + "\u{1B}[36m→\u{1B}[0m uploading release 2.4.1\r\n"
            let end =
                number == 3
                ? "\u{1B}[31m✗ health check failed: 502 from :8080\u{1B}[0m\r\n\u{1B}[2m  rolled back to 2.4.0\u{1B}[0m\r\n"
                : "\u{1B}[36m→\u{1B}[0m linking current → releases/2.4.1\r\n"
                    + "\u{1B}[32m✓\u{1B}[0m healthy in 3.\(number * 2)s\r\n"
            return ("prod-api-\(number)", deploy + end + "\u{1B}[38;5;213m❯\u{1B}[0m ")
        }

        public static func run(arguments: [String]) -> Int32 {
            let index = arguments.firstIndex(of: "--render-chrome")!
            let folder = URL(
                fileURLWithPath: index + 1 < arguments.count ? arguments[index + 1] : "build/chrome",
                isDirectory: true)
            do {
                _ = NSApplication.shared
                // Active, as the app makes itself at launch: only an active app's key window
                // has a focused pane, with a solid cursor.
                NSApp.setActivationPolicy(.regular)
                NSApp.finishLaunching()
                NSApp.activate()
                let active = (try? wait("the app to be active", within: 3, until: { NSApp.isActive })) != nil
                if !active { print("the app is not active here: the panes show as in a window in the background") }
                FontRegistry.registerBundledFonts()
                NSWindow.allowsAutomaticWindowTabbing = false
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let renderer = try? OffscreenRenderer()
                if renderer == nil { print("no Metal device: the panes are left empty") }
                for theme in ThemeCatalog.all {
                    try write(window(theme: theme, renderer: renderer), to: folder, name: theme.id)
                    try write(armedWindow(theme: theme, renderer: renderer), to: folder, name: theme.id + "-armed")
                }
                print("wrote \(ThemeCatalog.all.count * 2) pictures to \(folder.path)")
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
            /// The Main board's WRLD, so the sidebar shows as it does there.
            let preview = PreviewWRLD()
            var connections: (any HostConnecting)? { preview }
            // A picture keeps no records and interrupts nobody.
            var bests: BestsService? { nil }
            var notifier: (any Notifier)? { nil }
            var sidebarPreferred: Bool {
                get { true }
                set {}
            }
            var scripts = ChromePreview.scripts
            private(set) var sessions: [ScriptedSession] = []
            var makeSession: SessionMaker {
                { [unowned self] _, configuration, _, _ in
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

        /// A window in `theme`, running `scripts`.
        private static func makeWindow(theme: NamedTheme, scripts: [(program: String, output: String)])
            -> PitLaneWindowController
        {
            var config = Config()
            config.themeID = theme.id
            // The pills and headers name the shell the mockups show, whatever the runner's is.
            config.command = "/bin/zsh"
            let host = Host()
            host.scripts = scripts
            let controller = PitLaneWindowController(config: config, host: host, directory: directory)
            // The window holds its host weakly: keep it for as long as the window is drawn.
            hosts.append(host)
            controller.window?.setContentSize(size)
            controller.showWindow(nil)
            return controller
        }

        /// Hosts of the windows being drawn.
        private static var hosts: [Host] = []

        /// A window in `theme`: a split tab and two more tabs.
        private static func window(theme: NamedTheme, renderer: OffscreenRenderer?) throws -> CGImage {
            let controller = makeWindow(theme: theme, scripts: scripts)
            defer { controller.window?.close() }
            controller.splitRight(nil)
            try wait("the split") { controller.panes.count == 2 }
            controller.newTab(nil)
            try wait("the second tab") { controller.model.tabs.count == 2 }
            controller.newTab(nil)
            try wait("the third tab") { controller.model.tabs.count == 3 }
            // Back to the split tab, its left pane in use.
            _ = controller.selectTab(number: 1)
            _ = controller.selectPane(number: 1)
            return try picture(of: try ready(controller), renderer: renderer)
        }

        /// Armed and Dangerous in `theme`: a tab of three panes, typing going to all of them.
        private static func armedWindow(theme: NamedTheme, renderer: OffscreenRenderer?) throws -> CGImage {
            let controller = makeWindow(theme: theme, scripts: armedScripts)
            defer { controller.window?.close() }
            controller.splitRight(nil)
            try wait("the first split") { controller.panes.count == 2 }
            controller.splitDown(nil)
            try wait("the second split") { controller.panes.count == 3 }
            _ = controller.selectPane(number: 1)
            controller.toggleArmed(nil)
            return try picture(of: try ready(controller), renderer: renderer)
        }

        /// `controller` once its panes show their screens and name their programs.
        private static func ready(_ controller: PitLaneWindowController) throws -> PitLaneWindowController {
            for pane in controller.panes.values {
                pane.surface.sessionDidUpdate()
                // What runs in it and where: for the pills, headers and status bar.
                pane.refreshForeground()
            }
            try wait("the panes' screens and programs") {
                controller.panes.values.allSatisfy {
                    $0.surface.model?.mirror.generation != nil && $0.programName != nil
                }
            }
            // As the app does when it becomes active, should that have come after the window.
            for pane in controller.panes.values { pane.surface.focusChanged() }
            settle()
            return controller
        }

        // MARK: - WRLD for the pictures

        /// The Main board's hosts, snippets and tunnel, for the sidebar. Nothing in it
        /// connects.
        @MainActor
        final class PreviewWRLD: HostConnecting {
            let vault: Vault
            let state: WRLDState
            let now: Date

            init() {
                let now = Date()
                self.now = now
                let homelab = Group(id: GroupID(rawValue: "g1"), name: "Homelab")
                let work = Group(id: GroupID(rawValue: "g2"), name: "Work")
                func host(_ id: String, _ name: String, _ address: String, group: GroupID? = nil, legend: Bool = false)
                    -> WRLDHost
                {
                    WRLDHost(
                        id: HostID(rawValue: id), name: name, source: .wrld(Connection(address: address)),
                        groupID: group, isLegend: legend)
                }
                var prod = host("h1", "prod-api", "10.0.4.21", group: work.id, legend: true)
                prod.tunnels = [
                    Tunnel(
                        id: TunnelID(rawValue: "t1"),
                        spec: TunnelSpec(kind: .local, listenPort: 5432, target: .init(host: "db", port: 5432)))
                ]
                let hosts =
                    [
                        prod, host("h2", "nas-999", "nas.local", group: homelab.id, legend: true),
                        host("h3", "jellyfin", "192.168.12.40", group: homelab.id),
                        host("h4", "bastion", "bastion.lan", group: homelab.id),
                        host("h5", "media", "192.168.12.41", group: homelab.id),
                        host("h6", "pi-hole", "192.168.12.2"),
                    ] + (1...6).map { host("w\($0)", "work-\($0)", "work\($0).example.com", group: work.id) }
                vault = Vault(
                    hosts: hosts, groups: [homelab, work],
                    snippets: [
                        Snippet(name: "deploy", text: "./deploy.sh {{env:prod|staging}}"),
                        Snippet(name: "tail api logs", text: "journalctl -fu api"),
                        Snippet(name: "restart caddy", text: "sudo systemctl restart caddy"),
                    ])
                var state = WRLDState()
                for (id, latency) in [("h1", 18), ("h2", 4)] {
                    state.update(.vault(HostID(rawValue: id))) { facts in
                        facts.latency = latency
                        facts.latencyCheckedAt = now
                    }
                }
                state.update(.vault(HostID(rawValue: "h6"))) { $0.latencyCheckedAt = now }
                self.state = state
            }

            func sidebar(query: String, expanded: Set<GroupID>) -> SidebarModel {
                SidebarModel(
                    .init(
                        vault: vault, state: state, connected: ["h1"], openTunnels: [TunnelID(rawValue: "t1")],
                        expandedGroups: expanded, query: query, now: now))
            }

            func name(of host: HostRef) -> String { "host" }
            func address(of host: HostRef) -> String? { nil }
            func connect(_ host: HostRef, for pane: PaneID) async -> ConnectResult { .failed(.cancelled) }
            func plainLaunch(_ host: HostRef) async -> ShellLaunch? { nil }
            func openSFTP(_ host: HostRef) async -> (any RemoteFiles)? { nil }
            func closeSFTP(_ host: HostRef) {}
            func release(_ pane: PaneID) {}
            func cancel(_ host: HostRef) {}
            func paletteHosts() -> [PaletteItem] { [] }
            var openConnections: [String] { [] }
            var openTunnelCount: Int { 1 }
            func paletteTunnels() -> [PaletteItem] { [] }
            func toggleTunnel(_ id: TunnelID) async {}
            func paletteSnippets() -> [PaletteItem] { [] }
            func snippet(_ id: SnippetID) -> Snippet? { nil }
            func save(_ snippet: Snippet) -> Bool { false }
            func onConnectCommand(for host: HostRef) -> String? { nil }
            func used(_ snippet: SnippetID) {}
            func host(_ id: HostID) -> WRLDHost? { vault.host(id) }
            func setLegend(_ host: HostID, _ isLegend: Bool) {}
            func remove(_ host: HostID) async {}
            func shown(by viewer: AnyObject) {}
            func hidden(by viewer: AnyObject) {}
            func knownKeys(_ removal: KeyRemoval, for host: HostRef?) async -> [KnownHosts.Entry] { [] }
            func forgetKey(_ removal: KeyRemoval, for host: HostRef?) async -> String? { nil }
        }

        // MARK: - Pictures

        /// The window's content: the chrome from the layer tree, then each shown pane's own
        /// frame where its Metal layer is.
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

            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            // The root view is flipped, so its layer tree runs down the page: turn the context
            // the same way for it, and back for the panes, which are placed in the window's
            // own coordinates.
            context.saveGState()
            context.translateBy(x: 0, y: content.bounds.height)
            context.scaleBy(x: 1, y: -1)
            layer.render(in: context)
            context.restoreGState()
            if let renderer, let tab = controller.model.activeTab {
                for id in tab.panes {
                    guard let surface = controller.panes[id]?.surface, !surface.isHiddenOrHasHiddenAncestor,
                        let image = try surface.snapshot(using: renderer)?.cgImage()
                    else { continue }
                    context.draw(image, in: surface.convert(surface.bounds, to: nil))
                    surface.drawCursor(in: context)
                    // Badges are layers, which an offscreen frame leaves out, so a picture of a
                    // pane draws them over it — the same obligation the cursor has.
                    surface.drawBadges(in: context)
                }
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
        /// until `done` or `seconds`.
        private static func wait(_ what: String, within seconds: TimeInterval = 5, until done: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(seconds)
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
