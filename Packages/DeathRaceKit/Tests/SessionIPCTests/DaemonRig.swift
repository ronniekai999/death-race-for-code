import Foundation
import IPCKit
import PTYKit
import SessionIPC
import SessionKit
import Testing
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// `legendsd` and its stand-in client, as `swift build` left them. The test target depends on
/// both products so that `swift test` builds them, the way SSHKitTests does with the askpass
/// helper.
enum BuiltBinary {
    static func path(_ name: String) -> String? {
        candidates(name).first { access($0, X_OK) == 0 }
    }

    static func candidates(_ name: String) -> [String] {
        var folders: [String] = []
        #if os(macOS)
            folders.append(Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().path)
        #else
            folders.append(Bundle.main.bundleURL.path)
        #endif
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        folders.append(package.appendingPathComponent(".build/debug").path)
        return folders.map { $0 + "/" + name }
    }

    static func missing(_ name: String) -> Comment { "\(name) wasn't built; looked at \(candidates(name))" }
}

#if os(macOS)
    private final class TestBundleMarker: NSObject {}
#endif

/// A daemon of its own, in a folder of its own, with the stand-in client to drive it.
///
/// Every test gets its own socket and lock, so nothing here depends on there being one
/// daemon on the machine — and `finish()` leaves nothing running.
final class DaemonRig {
    let folder: String
    let socket: String
    let lock: String
    let logPath: String
    private var daemon: ChildProcess?
    private var probes: [ChildProcess] = []

    /// `idleExit` nil means the daemon never tidies itself away, which most tests want so
    /// that it cannot vanish mid-assertion.
    init(sessions: Int? = nil, idleExitMilliseconds: Int? = nil, writeStallMilliseconds: Int? = nil) throws {
        folder = NSTemporaryDirectory() + "lgd-" + String(UInt32.random(in: .min ... .max), radix: 16)
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socket = folder + "/s.sock"
        lock = folder + "/s.lock"
        logPath = folder + "/d.log"

        let executable = try #require(BuiltBinary.path("legendsd"), BuiltBinary.missing("legendsd"))
        var arguments = ["legendsd", "--socket", socket, "--lock", lock, "--log", logPath]
        if let sessions { arguments += ["--sessions", String(sessions)] }
        if let writeStallMilliseconds {
            arguments += ["--write-stall", String(patience(writeStallMilliseconds))]
        }
        if let idleExitMilliseconds {
            arguments += ["--idle-exit", String(patience(idleExitMilliseconds))]
        } else {
            arguments.append("--stay")
        }
        daemon = try ChildProcess.spawn(
            executable: executable, arguments: arguments, environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/")
        #expect(waitUntilListening(), "the daemon never listened; log: \(log)")
    }

    var daemonPID: Int32? { daemon?.pid }

    var log: String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    @discardableResult
    func waitUntilListening(_ milliseconds: Int = 5_000) -> Bool {
        let until = UnixSocket.monotonicMilliseconds() + milliseconds
        while UnixSocket.monotonicMilliseconds() < until {
            if UnixSocket.accepts(socket) { return true }
            usleep(20_000)
        }
        return false
    }

    func waitUntilGone(_ milliseconds: Int = 5_000) -> Bool {
        let until = UnixSocket.monotonicMilliseconds() + milliseconds
        while UnixSocket.monotonicMilliseconds() < until {
            if daemon?.reap() != nil || !isRunning(daemon?.pid ?? -1) { return true }
            usleep(20_000)
        }
        return false
    }

    var daemonIsRunning: Bool { isRunning(daemon?.pid ?? -1) }

    /// Runs the stand-in client to completion and gives back what it said, a line each.
    func probe(_ arguments: [String], milliseconds: Int = 20_000) throws -> [String] {
        let executable = try #require(BuiltBinary.path("legendsd-probe"), BuiltBinary.missing("legendsd-probe"))
        let result = try ChildProcess.run(
            executable: executable, arguments: ["legendsd-probe", "--socket", socket, "--lock", lock] + arguments,
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", timeoutMilliseconds: milliseconds)
        return String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Starts a client that stays, and waits until it says it is ready. Its lines so far come
    /// back with it, so a test can read the session ids before killing it.
    func startProbe(
        _ arguments: [String], milliseconds: Int = 20_000
    ) throws -> (child: ChildProcess, lines: [String]) {
        let executable = try #require(BuiltBinary.path("legendsd-probe"), BuiltBinary.missing("legendsd-probe"))
        let child = try ChildProcess.spawn(
            executable: executable,
            arguments: ["legendsd-probe", "--socket", socket, "--lock", lock] + arguments + ["--stay"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/")
        probes.append(child)
        var said = ""
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let until = UnixSocket.monotonicMilliseconds() + milliseconds
        while UnixSocket.monotonicMilliseconds() < until, !said.contains("ready") {
            guard UnixSocket.wait(child.outputFD, forWriting: false, timeoutMilliseconds: 100).readable else {
                continue
            }
            let count = buffer.withUnsafeMutableBytes { read(child.outputFD, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            said += String(decoding: buffer[0..<count], as: UTF8.self)
        }
        return (child, said.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// The app's own end, in this process, for what does not need a client that can be killed.
    func host(deadlineMilliseconds: Int = 5_000) throws -> DaemonHost {
        try DaemonHost(
            paths: DaemonHost.Paths(socket: socket, lock: lock), launcher: NothingLauncher(),
            deadlineMilliseconds: deadlineMilliseconds)
    }

    /// Takes a session up, waiting out a detach the daemon has not noticed yet: letting go
    /// is a message, so for a moment after it the session is still watched.
    func adoptWhenFree(
        _ host: DaemonHost, _ id: SessionID, milliseconds: Int = 5_000
    ) throws -> any ShellSession {
        let until = UnixSocket.monotonicMilliseconds() + milliseconds
        while true {
            do {
                return try host.adopt(id, onUpdate: {})
            } catch {
                var watched = false
                if case .alreadyAttached = error { watched = true }
                guard watched, UnixSocket.monotonicMilliseconds() < until else { throw error }
                usleep(50_000)
            }
        }
    }

    func finish() {
        for probe in probes {
            probe.signal(SIGKILL)
            _ = probe.waitForExit(timeoutMilliseconds: 1_000)
        }
        probes = []
        if let daemon {
            daemon.signal(SIGKILL)
            _ = daemon.waitForExit(timeoutMilliseconds: 2_000)
        }
        daemon = nil
        try? FileManager.default.removeItem(atPath: folder)
    }
}

/// For a host that must talk to the daemon the test started, and never start one itself.
struct NothingLauncher: DaemonLauncher {
    func start(socketPath: String, lockPath: String) {}
}

/// A process still running; a zombie counts as gone.
func isRunning(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    guard kill(pid, 0) == 0 else { return false }
    #if os(Linux)
        guard let raw = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
            let close = raw.lastIndex(of: ")")
        else { return true }
        let fields = raw[raw.index(after: close)...].split(separator: " ")
        return fields.first != "Z"
    #else
        return true
    #endif
}

/// What `pid` has spent on the processor, in milliseconds.
///
/// The second field of /proc/<pid>/stat is the program's name in brackets, and a program may
/// be called anything — spaces and brackets included — so the fields are counted from the
/// last bracket rather than from the start.
func processorMilliseconds(_ pid: Int32) -> Int? {
    #if os(Linux)
        guard let raw = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
            let close = raw.lastIndex(of: ")")
        else { return nil }
        let fields = raw[raw.index(after: close)...].split(separator: " ")
        guard fields.count > 12, let user = Int(fields[11]), let system = Int(fields[12]) else { return nil }
        let tick = Int(sysconf(Int32(_SC_CLK_TCK)))
        return (user + system) * 1_000 / max(tick, 1)
    #else
        return nil
    #endif
}

/// A shell whose prompt says nothing, so what is on screen is only what was asked for.
func testShell() -> ShellLaunch {
    ShellLaunch(
        executable: "/bin/sh", arguments: ["sh"],
        environment: ShellLaunch.terminalEnvironment(
            inheriting: ["PATH": "/usr/bin:/bin", "PS1": ""], appVersion: "test"))
}
