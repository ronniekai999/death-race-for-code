import CPTY

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The program in a terminal's foreground: the shell itself at its prompt, or a job it
/// started (vim, a build, ssh). Closing a tab asks first when it is not the shell, and a new
/// tab starts in its working directory.
public struct ForegroundProcess: Sendable, Equatable {
    /// The foreground process group's id: its leader's pid.
    public var pid: Int32
    /// The leader's short name ("vim", "zsh").
    public var name: String
    /// The leader's working directory, when it can be read.
    public var workingDirectory: String?
    /// The shell itself is in the foreground.
    public var isShell: Bool

    public init(pid: Int32, name: String, workingDirectory: String?, isShell: Bool) {
        self.pid = pid
        self.name = name
        self.workingDirectory = workingDirectory
        self.isShell = isShell
    }
}

extension PseudoTerminal {
    /// Who is in the foreground now, or nil once the terminal is gone.
    public func foregroundProcess() -> ForegroundProcess? {
        let group = cpty_foreground_group(masterFD)
        guard group > 0 else { return nil }
        return ForegroundProcess(
            pid: group, name: Self.processName(group) ?? "", workingDirectory: Self.workingDirectory(of: group),
            isShell: group == pid)
    }

    /// The short name of process `pid`, as `ps -c` shows it.
    public static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard cpty_process_name(pid, &buffer, buffer.count) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The working directory of process `pid`.
    public static func workingDirectory(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard cpty_process_cwd(pid, &buffer, buffer.count) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
