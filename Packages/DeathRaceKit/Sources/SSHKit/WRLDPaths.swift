/// The files Death Race keeps for its connections, under `~/.deathrace` (mode 0700):
///
/// | Path | What |
/// |---|---|
/// | `ssh_config` | the config WRLD compiles to (`GeneratedConfig`) |
/// | `cm/` | the masters' control sockets, one fixed name per host |
/// | `run/` | the askpass broker's socket, and the session daemon's |
/// | `keys/` | Secure Enclave key handles |
/// | `state.json` | what changes on its own: last connected, OS, latency, use counts |
///
/// The folder is short on purpose: a Unix socket's path is limited to 104 bytes, and mux
/// binds a control socket's path plus `.` and 16 random characters before renaming it.
public struct WRLDPaths: Equatable, Sendable {
    /// The longest a control socket's path may be: 104 bytes for `sun_path`, less the NUL,
    /// less the 17 characters mux adds to bind it first.
    public static let longestControlPath = 86
    /// The longest path a Unix socket can have (`sun_path`, less the NUL).
    public static let longestSocketPath = 103

    public let root: String
    /// Where control sockets go: `cm/` under the root, unless that would make their paths
    /// too long, then a folder in the per-user temporary directory.
    public let controlFolder: String

    public init(root: String, temporaryDirectory: String? = nil) {
        self.root = root
        let preferred = root + "/cm"
        if preferred.utf8.count + 1 + 16 <= Self.longestControlPath || temporaryDirectory == nil {
            controlFolder = preferred
        } else {
            let base = temporaryDirectory!.hasSuffix("/") ? String(temporaryDirectory!.dropLast()) : temporaryDirectory!
            controlFolder = base + "/deathrace-cm"
        }
    }

    /// `~/.deathrace` for `home`.
    public static func standard(home: String, temporaryDirectory: String? = nil) -> WRLDPaths {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return WRLDPaths(root: trimmed + "/.deathrace", temporaryDirectory: temporaryDirectory)
    }

    public var generatedConfig: String { root + "/ssh_config" }
    public var runFolder: String { root + "/run" }
    public var keysFolder: String { root + "/keys" }
    public var state: String { root + "/state.json" }

    /// The broker's socket for the app process `pid`.
    public func brokerSocket(pid: Int32) -> String { runFolder + "/askpass-\(pid).sock" }

    /// The session daemon's socket. One per user, not one per app process: the whole point is
    /// that what is behind it outlives any one of them.
    public var daemonSocket: String { runFolder + "/legendsd.sock" }
    /// What a daemon holds to be the only one at `daemonSocket`. The file is left behind; it
    /// is the lock on it that means something, so finding one says nothing about whether a
    /// daemon is running.
    public var daemonLock: String { runFolder + "/legendsd.lock" }
    /// Where the daemon's own output goes. It has no terminal and no app to tell.
    public var daemonLog: String { runFolder + "/legendsd.log" }

    /// A host's control socket: a fixed name from `key` (a host id, or `alias:` and a name
    /// from `~/.ssh/config`), not ssh's `%C`, which hashes this Mac's host name and so
    /// changes from one network to the next.
    public func controlPath(for key: String) -> String {
        controlFolder + "/" + Self.stableHex(key)
    }

    /// Whether `path` is short enough to bind as a control socket.
    public static func fitsControlSocket(_ path: String) -> Bool {
        path.utf8.count <= longestControlPath
    }

    /// 16 hex digits from 64-bit FNV-1a: the same for the same key on every launch.
    static func stableHex(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
