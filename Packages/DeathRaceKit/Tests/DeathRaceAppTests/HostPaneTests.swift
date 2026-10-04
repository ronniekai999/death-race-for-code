import AppCore
import AppKit
import ConfigKit
import Foundation
import PTYKit
import SSHKit
import Testing
import Vault

@testable import DeathRaceApp

/// WRLD with no ssh behind it: each connection comes out as the test says, in order, or
/// waits until `finish`.
@MainActor
final class FakeConnections: HostConnecting {
    var results: [ConnectResult] = []
    private(set) var connected: [(host: HostRef, pane: PaneID)] = []
    private(set) var released: [PaneID] = []
    private(set) var cancelled: [HostRef] = []
    private var waiting: [CheckedContinuation<ConnectResult, Never>] = []

    static let session = ShellLaunch(
        executable: "/usr/bin/ssh", arguments: ["/usr/bin/ssh", "-F", "/x/ssh_config", "nas-999"], environment: [:])

    func name(of host: HostRef) -> String {
        switch host {
        case .vault(let id): "host-\(id.rawValue)"
        case .sshConfig(let alias): alias
        }
    }

    func address(of host: HostRef) -> String? { "192.168.1.5" }

    func connect(_ host: HostRef, for pane: PaneID) async -> ConnectResult {
        connected.append((host, pane))
        if !results.isEmpty { return results.removeFirst() }
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Ends every connection still waiting.
    func finish(_ result: ConnectResult) {
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(returning: result) }
    }

    var isWaiting: Bool { !waiting.isEmpty }

    func plainLaunch(_ host: HostRef) async -> ShellLaunch? {
        ShellLaunch(
            executable: "/usr/bin/ssh", arguments: ["/usr/bin/ssh", "-o", "ControlPath=none"], environment: [:])
    }

    func release(_ pane: PaneID) { released.append(pane) }

    func cancel(_ host: HostRef) {
        cancelled.append(host)
        finish(.failed(.cancelled))
    }

    func paletteHosts() -> [PaletteItem] { PaletteSearch.hosts(vault: Vault(), aliases: ["nas-999"]) }

    var openConnections: [String] { [] }

    private(set) var toggled: [TunnelID] = []
    var openTunnelCount: Int { toggled.count % 2 }

    func paletteTunnels() -> [PaletteItem] {
        let tunnel = Tunnel(id: TunnelID(rawValue: "t1"), spec: TunnelSpec(kind: .dynamic, listenPort: 1080))
        let host = WRLDHost(
            id: HostID(rawValue: "h1"), name: "bastion", source: .wrld(Connection(address: "10.0.0.1")),
            tunnels: [tunnel])
        return PaletteSearch.tunnels(vault: Vault(hosts: [host]), open: openTunnelCount == 1 ? [tunnel.id] : [])
    }

    func toggleTunnel(_ id: TunnelID) async {
        toggled.append(id)
        NotificationCenter.default.post(name: .tunnelsChanged, object: nil)
    }

    /// Wishing Well, kept in memory.
    private(set) var snippets: [Snippet] = []
    /// The on-connect command for every host, when a test sets one.
    var onConnect: String?

    func paletteSnippets() -> [PaletteItem] { PaletteSearch.snippets(vault: Vault(snippets: snippets)) }
    func snippet(_ id: SnippetID) -> Snippet? { snippets.first { $0.id == id } }

    func save(_ snippet: Snippet) -> Bool {
        snippets.removeAll { $0.id == snippet.id }
        snippets.append(snippet)
        return true
    }

    func onConnectCommand(for host: HostRef) -> String? { onConnect }

    private(set) var uses: [SnippetID] = []
    func used(_ snippet: SnippetID) { uses.append(snippet) }
}

extension WindowTests {
    private func hostWindow() -> (TestHost, FakeConnections, PitLaneWindowController) {
        let host = TestHost()
        let connections = FakeConnections()
        host.connections = connections
        return (host, connections, makeWindow(host))
    }

    private var nas: HostRef { .sshConfig(alias: "nas-999") }

    @Test func aPaneOnAHostSaysItsConnectingThenRunsItsSession() async throws {
        let (_, connections, controller) = hostWindow()
        defer { controller.window?.close() }

        controller.open(nas, beside: false)
        #expect(controller.model.tabs.count == 2)
        let pane = try #require(controller.activePane)
        #expect(pane.launch == .connection(nas))
        #expect(pane.banner == .connecting(to: "nas-999"))
        #expect(pane.session == nil)
        await eventually { connections.isWaiting }

        connections.finish(.ready(FakeConnections.session))
        await eventually { pane.session != nil }
        #expect(pane.banner == nil)
        #expect(pane.programName == "nas-999")
        #expect(pane.directory == nil)
        #expect(await pane.runningProgram() == "nas-999’s session")
    }

    @Test func aConnectionThatFailsSaysWhyAndReconnects() async throws {
        let (_, connections, controller) = hostWindow()
        defer { controller.window?.close() }
        connections.results = [.failed(.noRoute), .ready(FakeConnections.session)]

        controller.open(nas, beside: false)
        let pane = try #require(controller.activePane)
        await eventually { pane.banner?.buttons.contains(.allowLocalNetwork) == true }
        #expect(pane.banner == .failed(.noRoute, host: "nas-999", address: "192.168.1.5"))

        pane.press(.reconnect)
        await eventually { pane.session != nil }
        #expect(pane.banner == nil)
        #expect(connections.connected.count == 2)
    }

    @Test func cancellingAConnectionLeavesReconnect() async throws {
        let (_, connections, controller) = hostWindow()
        defer { controller.window?.close() }

        controller.open(nas, beside: false)
        let pane = try #require(controller.activePane)
        await eventually { connections.isWaiting }
        pane.press(.cancel)
        #expect(connections.cancelled == [nas])
        await eventually { pane.banner?.buttons == [.reconnect] }
        #expect(pane.session == nil)
    }

    @Test func aSplitFromAPaneOnAHostOpensTheSameHost() async throws {
        let (_, connections, controller) = hostWindow()
        defer { controller.window?.close() }
        connections.results = [.ready(FakeConnections.session), .ready(FakeConnections.session)]

        controller.open(nas, beside: false)
        let first = try #require(controller.activePane)
        await eventually { first.session != nil }
        controller.splitRight(nil)
        await eventually { controller.model.activeTab?.panes.count == 2 }
        let second = try #require(controller.activePane)
        #expect(second !== first)
        #expect(second.launch == .connection(nas))
        await eventually { second.session != nil }
        #expect(connections.connected.map { $0.host } == [nas, nas])
    }

    @Test func aPaneOnAHostLetsItGoWhenItCloses() async throws {
        let (_, connections, controller) = hostWindow()
        defer { controller.window?.close() }
        connections.results = [.ready(FakeConnections.session)]

        controller.open(nas, beside: false)
        let pane = try #require(controller.activePane)
        await eventually { pane.session != nil }
        pane.shutDown()
        #expect(connections.released == [pane.id])
    }

    @Test func aTunnelIsToggledFromHearMeCallingAndCountedInTheStatusBar() async throws {
        let (_, connections, controller) = hostWindow()
        defer { controller.window?.close() }

        controller.showHearMeCalling(nil)
        let overlay = try #require(controller.hearMeCalling)
        type("1080", into: overlay)
        #expect(overlay.model.state.selected?.target == .tunnel(TunnelID(rawValue: "t1")))
        press(#selector(NSResponder.insertNewline(_:)), in: overlay)
        await eventually { connections.toggled == [TunnelID(rawValue: "t1")] }
        await eventually { controller.root.statusBar.line.leading.contains { $0.text == "1 tunnel" } }
    }

    @Test func quittingNamesWhatItEnds() {
        #expect(AppDelegate.quitQuestion(programs: ["vim"], tunnels: 0) == "vim is still running. Quit anyway?")
        #expect(AppDelegate.quitQuestion(programs: [], tunnels: 1) == "1 tunnel is open. Quit anyway?")
        #expect(
            AppDelegate.quitQuestion(programs: ["vim", "prod-api’s session"], tunnels: 2)
                == "vim and prod-api’s session are still running, and 2 tunnels are open. Quit anyway?")
    }

    @Test func hostsAreInHearMeCallingAndCommandReturnOpensOneBeside() async throws {
        let (_, connections, controller) = hostWindow()
        defer { controller.window?.close() }
        connections.results = [.ready(FakeConnections.session)]

        controller.showHearMeCalling(nil)
        let overlay = try #require(controller.hearMeCalling)
        type("nas-999", into: overlay)
        let selected = try #require(overlay.model.state.selected)
        #expect(selected.target == .host(nas))
        #expect(selected.alternate == "Open Beside")
        overlay.model.chooseAlternate()
        #expect(controller.hearMeCalling == nil)
        // Beside the pane that was there, in the same tab.
        #expect(controller.model.tabs.count == 1)
        #expect(controller.model.activeTab?.panes.count == 2)
        #expect(controller.activePane?.launch == .connection(nas))
    }
}
