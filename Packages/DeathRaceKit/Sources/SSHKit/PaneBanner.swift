import PTYKit

/// What a pane says along its bottom while it connects, when it couldn't, or when its
/// session ended, and the buttons beside the words.
public struct PaneBanner: Equatable, Sendable {
    public enum Button: Equatable, Sendable {
        case cancel
        case reconnect
        /// ssh in the pane itself, logging in on its own.
        case plainSSH
        /// Opens System Settings at Local Network.
        case allowLocalNetwork
        /// A new shell, for a local pane.
        case restart

        public var title: String {
            switch self {
            case .cancel: "Cancel"
            case .reconnect: "Reconnect"
            case .plainSSH: "Try Plain ssh"
            case .allowLocalNetwork: "Allow Local Network Access…"
            case .restart: "Restart"
            }
        }
    }

    public var message: String
    public var buttons: [Button]
    /// Something is under way: the banner shows a spinner.
    public var isWorking: Bool

    public init(message: String, buttons: [Button], isWorking: Bool = false) {
        self.message = message
        self.buttons = buttons
        self.isWorking = isWorking
    }

    public static func connecting(to host: String) -> PaneBanner {
        PaneBanner(message: "Connecting to \(host)…", buttons: [.cancel], isWorking: true)
    }

    /// The connection didn't come up: why, and what may help.
    public static func failed(_ failure: ConnectionFailure, host: String, address: String?) -> PaneBanner {
        PaneBanner(
            message: failure.sentence(host: host),
            buttons: failure.offers(address: address).map { offer in
                switch offer {
                case .reconnect: .reconnect
                case .plainSSH: .plainSSH
                case .allowLocalNetwork: .allowLocalNetwork
                }
            })
    }

    /// The pane's ssh ended with `status`; nil when the session ended cleanly (you typed
    /// `exit`), which closes the pane as a local shell's clean exit does. A `plain` pane ran
    /// ssh on its own rather than through the app's master.
    public static func ended(_ status: ExitStatus?, host: String, plain: Bool) -> PaneBanner? {
        let buttons: [Button] = plain ? [.reconnect] : [.reconnect, .plainSSH]
        switch status {
        case .exited(code: 0):
            return nil
        // ssh's own failures, a dropped connection among them.
        case .exited(code: 255):
            return PaneBanner(message: "The connection to \(host) was lost.", buttons: buttons)
        case .exited(let code):
            return PaneBanner(message: "The session on \(host) ended with status \(code).", buttons: [.reconnect])
        case .signaled(let signal):
            return PaneBanner(message: "ssh was ended by signal \(signal).", buttons: [.reconnect])
        case nil:
            return PaneBanner(message: "The session on \(host) ended.", buttons: [.reconnect])
        }
    }
}
