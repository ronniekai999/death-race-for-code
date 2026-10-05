import Vault

/// The command lines Death Race runs ssh with. `argv[0]` is the full path, so ProxyJump's
/// hops run the same ssh.
public enum SSHCommand {
    public static let ssh = "/usr/bin/ssh"

    /// The app's own master for a host: no terminal, no remote command, in the foreground
    /// as the app's child (never `ControlPersist`, which forks into the background). Once
    /// its control socket listens, ssh runs `LocalCommand`, which prints `readyMarker`: the
    /// sign it is connected, with no polling.
    public static func master(alias: String, config: String, readyMarker: String) -> [String] {
        [
            ssh, "-F", config, "-M", "-N",
            "-o", "ControlPersist=no",
            "-o", "PermitLocalCommand=yes",
            "-o", "LocalCommand=echo \(readyMarker)",
            alias,
        ]
    }

    /// A session in a pane, through the host's master.
    public static func session(alias: String, config: String) -> [String] {
        [ssh, "-F", config, alias]
    }

    /// A plain ssh in a pane, with its own login, for when the master can't be used.
    public static func plainSession(alias: String, config: String) -> [String] {
        [ssh, "-F", config, "-o", "ControlPath=none", alias]
    }

    /// What ssh will use for `alias` (`-G`), parsed by `EffectiveConfig`.
    public static func effectiveConfig(alias: String, config: String) -> [String] {
        [ssh, "-F", config, "-G", alias]
    }

    /// A command run on the host through its master, with no terminal and no prompts: if
    /// the master is gone it fails instead of asking to log in.
    public static func remote(alias: String, config: String, command: String) -> [String] {
        [ssh, "-F", config, "-T", "-o", "BatchMode=yes", alias, command]
    }

    /// The SFTP subsystem on the host, through its master — Maze speaks SFTP v3 over this, so
    /// there is no second login. The `-s -- <host> sftp` form matches how OpenSSH's own sftp
    /// launches ssh: options, then the subsystem name as the command after `--`. `-F <config>`
    /// routes onto the existing master via its `ControlPath`, exactly as `session` does.
    public static func sftp(alias: String, config: String) -> [String] {
        [ssh, "-F", config, "-o", "BatchMode=yes", "-s", "--", alias, "sftp"]
    }

    public enum Control: Equatable, Sendable {
        case check
        case exit
        case forward(TunnelSpec)
        case cancel(TunnelSpec)
    }

    /// A request to a master over its control socket. `-F none`: with a config loaded, ssh
    /// would also send every forward the config names, so a cancel would close your own
    /// `LocalForward`s too. The host argument is required but never looked up.
    public static func control(_ control: Control, socket: String) -> [String] {
        var arguments = [ssh, "-F", "none", "-S", socket, "-O"]
        switch control {
        case .check: arguments.append("check")
        case .exit: arguments.append("exit")
        case .forward(let spec): arguments += ["forward", spec.flag, spec.argument]
        case .cancel(let spec): arguments += ["cancel", spec.flag, spec.argument]
        }
        return arguments + ["x"]
    }
}
