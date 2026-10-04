import AppCore
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
}
