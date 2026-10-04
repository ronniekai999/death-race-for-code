import AppCore
import AppKit
import ConfigKit
import PTYKit
import ScreenProtocol
import SessionKit
import SurfaceCore
import Testing
import VTCore

@testable import DeathRaceApp

/// A shell that is only an engine: what the program prints is fed in by the test.
final class FakeSession: PaneSession, @unchecked Sendable {
    let replay: ReplaySession
    var foreground = ForegroundProcess(pid: 1, name: "zsh", workingDirectory: "/tmp", isShell: true)
    private(set) var closed = false

    init(_ configuration: Terminal.Configuration) {
        replay = ReplaySession(configuration)
    }

    func takeDelta() -> ScreenDelta? { replay.takeDelta() }
    var status: Session.Status { closed ? .exited(.exited(code: 0)) : .running }
    func send(_ bytes: [UInt8]) -> Bool { replay.send(bytes) }
    func sendReport(_ bytes: [UInt8]) -> Bool { replay.sendReport(bytes) }
    func resize(columns: Int, rows: Int, cellPixelWidth: Int, cellPixelHeight: Int) {
        replay.resize(columns: columns, rows: rows, cellPixelWidth: cellPixelWidth, cellPixelHeight: cellPixelHeight)
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
    func foregroundProcess() async -> ForegroundProcess? { closed ? nil : foreground }
    func close() { closed = true }
}

@MainActor
final class TestHost: WindowHost {
    let ids = IDSource()
    let makeSession: SessionMaker = { _, configuration, _ in FakeSession(configuration) }
    private(set) var closed: [PitLaneWindowController] = []
    private(set) var opened: [PitLaneWindowController] = []

    func windowClosed(_ controller: PitLaneWindowController) { closed.append(controller) }
    func inputStateChanged() {}
    func open(
        detached tab: TabModel, panes: [PaneController], area: PaneAreaView, from controller: PitLaneWindowController
    ) {
        let window = PitLaneWindowController(config: Config(), host: self, adopting: tab, panes: panes, area: area)
        window.showWindow(nil)
        opened.append(window)
    }
}

/// Waits for work the window starts in a task (a new tab asks its pane where it is first).
@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Set while a window test runs. The first run of these tests on CI ended the test process
/// midway through one, with status 0 and no word: if anything calls `exit` again, the
/// handler below names the caller.
nonisolated(unsafe) var windowTestRunning = false

private let reportExitDuringWindowTest: Void = {
    _ = atexit {
        guard windowTestRunning else { return }
        let stack = Thread.callStackSymbols.joined(separator: "\n")
        FileHandle.standardError.write(Data("exit() during a window test, called from:\n\(stack)\n".utf8))
    }
}()

@MainActor
@Suite(.serialized)
final class WindowTests {
    private static var described = false

    init() {
        _ = NSApplication.shared
        _ = reportExitDuringWindowTest
        windowTestRunning = true
        if !Self.described {
            Self.described = true
            let facts =
                "window tests: main thread \(Thread.isMainThread), screens \(NSScreen.screens.count), "
                + "app active \(NSApp.isActive)\n"
            FileHandle.standardError.write(Data(facts.utf8))
        }
    }

    deinit {
        windowTestRunning = false
    }

    func makeWindow(_ host: TestHost) -> PitLaneWindowController {
        let controller = PitLaneWindowController(config: Config(), host: host, directory: nil)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return controller
    }

    @Test func aWindowOpensWithOneTabAndPane() {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        #expect(controller.model.tabs.count == 1)
        #expect(controller.panes.count == 1)
        #expect(controller.window?.firstResponder === controller.activePane?.surface)
        #expect(controller.window?.styleMask.contains(.fullSizeContentView) == true)
        #expect(controller.window?.tabbingMode == .disallowed)
    }

    @Test func newTabsOpenAfterTheActiveOneAndShowAlone() async {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        controller.newTab(nil)
        await eventually { controller.model.tabs.count == 2 }
        #expect(controller.model.tabs.count == 2)
        #expect(controller.model.activeIndex == 1)
        #expect(controller.selectTab(number: 1))
        #expect(controller.model.activeIndex == 0)
        #expect(!controller.selectTab(number: 3))
        let visible = controller.root.tabArea.subviews.filter { !$0.isHidden }
        #expect(visible.count == 1)
    }

    @Test func closingGoesPaneThenTabThenWindow() async {
        let host = TestHost()
        let controller = makeWindow(host)
        controller.splitRight(nil)
        await eventually { controller.panes.count == 2 }
        #expect(controller.model.activeTab?.isSplit == true)
        // Closing asks the session whether a program would be lost first.
        controller.closePane(nil)
        await eventually { controller.panes.count == 1 }
        #expect(controller.panes.count == 1)
        #expect(controller.model.tabs.count == 1)
        controller.newTab(nil)
        await eventually { controller.model.tabs.count == 2 }
        controller.closePane(nil)
        await eventually { controller.model.tabs.count == 1 }
        #expect(controller.model.tabs.count == 1)
        #expect(controller.window?.isVisible == true)
        controller.closePane(nil)
        await eventually { host.closed.count == 1 }
        #expect(host.closed.count == 1)
    }

    @Test func aTabMovesToANewWindowWithItsPanes() async {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        controller.newTab(nil)
        await eventually { controller.model.tabs.count == 2 }
        let moving = controller.activePane
        controller.detachTab(nil)
        #expect(controller.model.tabs.count == 1)
        #expect(host.opened.count == 1)
        let other = host.opened[0]
        defer { other.window?.close() }
        #expect(other.activePane === moving)
        #expect(moving?.surface.window === other.window)
    }

    @Test func splitsLayOutSideBySide() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        controller.splitRight(nil)
        await eventually { controller.panes.count == 2 }
        controller.window?.layoutIfNeeded()
        let surfaces = controller.panes.values.map { $0.surface }
        let frames = surfaces.map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
        try #require(frames.count == 2)
        #expect(frames[0].maxX < frames[1].minX)
        #expect(abs(frames[0].width - frames[1].width) <= 1)
        #expect(controller.stepPane(forward: true))
        #expect(controller.window?.firstResponder === controller.activePane?.surface)
    }

    @Test func theTrafficLightsSitInTheMiddleOfTheTitleRow() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        let close = try #require(window.standardWindowButton(.closeButton))
        let center = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        // Window coordinates count up from the bottom.
        #expect(abs(center.y - (window.frame.height - Chrome.titleRowHeight / 2)) <= 1)
    }

    /// The title bar sits over the title row: a click on a pill must still reach the pill.
    @Test func clicksOnTabPillsReachThem() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        controller.root.layoutSubtreeIfNeeded()
        let tab = try #require(controller.model.activeTabID)
        let pill = try #require(controller.root.titleBar.strip.pills[tab])
        let point = pill.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)
        let frameView = try #require(window.contentView?.superview)
        let hit = frameView.hitTest(point)
        #expect(hit === pill, "the click went to \(String(describing: hit))")
    }

    @Test func theStatusBarShowsTheGrid() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        controller.refreshStatus()
        let grid = try #require(controller.activePane?.surface.grid)
        #expect(controller.root.statusBar.line.trailing.first?.text == "\(grid.columns)×\(grid.rows)")
    }

    @Test func aThemeChangeReachesTheWindow() {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        var config = Config()
        config.themeID = "righteous"
        controller.apply(config)
        #expect(controller.window?.appearance?.name == .aqua)
        #expect(controller.activePane?.surface.theme == ThemeCatalog.righteous.terminal)
    }

    @Test func closeQuestionsNameThePrograms() {
        #expect(
            PitLaneWindowController.closeQuestion(["vim"], place: "tab")
                == "vim is still running in this tab. Close it anyway?")
        #expect(
            PitLaneWindowController.closeQuestion(["vim", "htop"], place: "window")
                == "vim and htop are still running in this window. Close them anyway?")
    }
}
