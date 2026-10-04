import AppCore
import Foundation
import PTYKit
import SSHKit
import Vault

/// How a pane's connection to a host came out.
enum ConnectResult: Equatable {
    /// The host's master is up: the pane runs this, a session through it.
    case ready(ShellLaunch)
    case failed(ConnectionFailure)
}

/// What panes on hosts need of WRLD: `WRLDService` in the app, a fake in the window tests.
@MainActor
protocol HostConnecting: AnyObject, Sendable {
    /// WRLD's name for `host`, as pills, banners and sheets show it.
    func name(of host: HostRef) -> String
    /// Where `host` is, when WRLD knows: for "Allow Local Network Access".
    func address(of host: HostRef) -> String?
    /// Connects to `host` for `pane`, or joins the master it has.
    func connect(_ host: HostRef, for pane: PaneID) async -> ConnectResult
    /// ssh to `host` on its own in the pane, logging in there, without the app's master.
    func plainLaunch(_ host: HostRef) async -> ShellLaunch?
    /// `pane` is done with its host; the last one out lets the master go after a while.
    func release(_ pane: PaneID)
    /// Stops connecting to `host`: a pending pane's Cancel.
    func cancel(_ host: HostRef)
    /// Hear Me Calling's hosts.
    func paletteHosts() -> [PaletteItem]
    /// The hosts with a connection open, by name, for the quit question.
    var openConnections: [String] { get }
    /// Come & Go's tunnels that are open.
    var openTunnelCount: Int { get }
    /// Hear Me Calling's tunnels.
    func paletteTunnels() -> [PaletteItem]
    /// Turns a tunnel on, or off when it's open.
    func toggleTunnel(_ id: TunnelID) async
    /// Hear Me Calling's snippets.
    func paletteSnippets() -> [PaletteItem]
    func snippet(_ id: SnippetID) -> Snippet?
    /// Adds `snippet` to Wishing Well, or changes the one with its id; false when it
    /// couldn't be saved.
    func save(_ snippet: Snippet) -> Bool
    /// What a session on `host` types first: its on-connect snippet, its fields at their
    /// defaults. Nil when it has none.
    func onConnectCommand(for host: HostRef) -> String?
    /// A snippet was typed in: Wishing Well counts its uses.
    func used(_ snippet: SnippetID)
    /// The sidebar's sections, searched for `query`, with the `expanded` groups open.
    func sidebar(query: String, expanded: Set<GroupID>) -> SidebarModel
    func host(_ id: HostID) -> WRLDHost?
    func setLegend(_ host: HostID, _ isLegend: Bool)
    /// Takes the host out of WRLD, closing its open tunnels first.
    func remove(_ host: HostID) async
    /// Something on screen shows WRLD (a sidebar, the WRLD window): the Legends are checked
    /// while anything does, and not otherwise.
    func shown(by viewer: AnyObject)
    func hidden(by viewer: AnyObject)
    /// The keys ssh trusts under `removal`'s name, in its file.
    func knownKeys(_ removal: KeyRemoval) async -> [KnownHosts.Entry]
    /// Forgets them, as ssh said to; why not, when it couldn't.
    func forgetKey(_ removal: KeyRemoval) async -> String?
}

extension Notification.Name {
    /// A tunnel opened or closed: status bars count them again.
    static let tunnelsChanged = Notification.Name("local.deathraceforcode.tunnelsChanged")
    /// WRLD's hosts, groups, snippets or tunnels changed, or what it knows of them: the
    /// sidebar and the WRLD window draw again.
    static let wrldChanged = Notification.Name("local.deathraceforcode.wrldChanged")
}
