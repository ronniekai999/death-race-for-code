// legendsd-probe: a stand-in for the app, so the daemon's tests can kill their client.
//
// The exit criterion is "kill -9 the app and relaunch: every session reattaches", and that
// cannot be tested in process — killing the test is killing the test. So this plays the app:
// it starts sessions, or takes them up again, and says what it found in lines a test can read.
//
//   legendsd-probe --socket PATH --lock PATH [--launch EXE] <what to do>
//
//     --spawn N [--marker TEXT]   start N sessions, echo the marker in each, print their ids
//     --list                      print every session the daemon holds
//     --reattach [--expect TEXT]  take every session up and print what is on its screen
//     --type TEXT                 with --reattach: type it and wait for it to come back
//     --end-all                   end every session
//     --wedge                     take one up and then stop reading, for the stall test
//     --detach                    take every session up and let go of it again, cleanly
//     --stay                      do not exit: wait to be killed
//
// Prints `ready` when what was asked for is done, then one line per finding. Output is
// unbuffered, because a test reads it before killing this process.

import Foundation
import IPCKit
import PTYKit
import ScreenProtocol
import SessionIPC
import SessionKit
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func say(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = write(1, base + offset, buffer.count - offset)
            if written > 0 {
                offset += written
            } else if !(written < 0 && errno == EINTR) {
                return
            }
        }
    }
}

guard let socketPath = value(after: "--socket"), let lockPath = value(after: "--lock") else {
    say("usage: legendsd-probe --socket PATH --lock PATH ...")
    exit(64)
}

let launcher: any DaemonLauncher = {
    if let executable = value(after: "--launch") {
        return SpawnLauncher(executable: executable, extra: ["--stay"])
    }
    return NoLauncher()
}()

/// For a probe that must talk to a daemon the test started, and never start one itself.
struct NoLauncher: DaemonLauncher {
    func start(socketPath: String, lockPath: String) {}
}

let host: DaemonHost
do {
    host = try DaemonHost(
        paths: DaemonHost.Paths(socket: socketPath, lock: lockPath), launcher: launcher,
        deadlineMilliseconds: 5_000)
} catch {
    say("failed=\(error)")
    exit(70)
}
say("daemon=\(host.daemon.pid)")

/// A shell with a prompt that says nothing, so what is on screen is only what was asked for.
func shell() -> ShellLaunch {
    ShellLaunch(
        executable: "/bin/sh", arguments: ["sh"],
        environment: ShellLaunch.terminalEnvironment(
            inheriting: ["PATH": "/usr/bin:/bin", "PS1": ""], appVersion: "probe"))
}

/// Applies deltas until `condition` holds, or the time runs out.
@discardableResult
func wait(
    on session: any ShellSession, mirror: inout MirrorGrid, milliseconds: Int = 5_000,
    until condition: (MirrorGrid) -> Bool
) -> Bool {
    let until = UnixSocket.monotonicMilliseconds() + milliseconds
    while true {
        while let delta = session.takeDelta() {
            do {
                try mirror.apply(delta)
            } catch {
                session.requestSnapshot()
            }
        }
        if condition(mirror) { return true }
        if UnixSocket.monotonicMilliseconds() >= until { return false }
        usleep(10_000)
    }
}

func text(of mirror: MirrorGrid) -> String {
    mirror.lines.map { line in
        var out = ""
        for column in line.cells.indices where line.cells[column].width != .spacerTail {
            let scalars = line.scalars(at: column)
            if scalars.isEmpty {
                out += " "
            } else {
                for scalar in scalars { out.unicodeScalars.append(Unicode.Scalar(scalar)!) }
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }.joined(separator: " ")
}

let marker = value(after: "--marker") ?? "999"

if let count = value(after: "--spawn").flatMap(Int.init) {
    var kept: [any ShellSession] = []
    for index in 0..<count {
        let metadata = Array("pane=\(index)".utf8)
        do {
            let session = try host.start(
                shell(), configuration: Terminal.Configuration(columns: 40, rows: 8), metadata: metadata,
                onUpdate: {})
            var mirror = MirrorGrid()
            wait(on: session, mirror: &mirror) { $0.generation != nil }
            session.send(Array("echo \(marker)-\(index)\n".utf8))
            let arrived = wait(on: session, mirror: &mirror) { text(of: $0).contains("\(marker)-\(index)") }
            say("session=\(session.id.value) marker=\(arrived)")
            kept.append(session)
        } catch {
            say("failed=\(error)")
            exit(70)
        }
    }
    say("ready")
    // The sessions are held so their connections stay open until this process is killed.
    if arguments.contains("--stay") {
        while true { sleep(60) }
    }
    _ = kept
}

if arguments.contains("--list") {
    do {
        for session in try host.existing() {
            say(
                "session=\(session.id.value) running=\(session.status == .running) "
                    + "columns=\(session.columns) metadata=\(String(decoding: session.metadata, as: UTF8.self))")
        }
        say("ready")
    } catch {
        say("failed=\(error)")
        exit(70)
    }
}

if arguments.contains("--reattach") {
    do {
        let found = try host.existing()
        for description in found {
            let session = try host.adopt(description.id, onUpdate: {})
            var mirror = MirrorGrid()
            let expected = value(after: "--expect") ?? marker
            let sawExpected = wait(on: session, mirror: &mirror) { text(of: $0).contains(expected) }
            say(
                "screen=\(description.id.value) expected=\(sawExpected) scrollback=\(mirror.scrollbackCount) "
                    + "text=\(text(of: mirror))")
            if let typed = value(after: "--type") {
                session.send(Array((typed + "\n").utf8))
                let echoed = wait(on: session, mirror: &mirror) { text(of: $0).contains("alive") }
                say("typed=\(description.id.value) echoed=\(echoed)")
            }
            session.detach()
        }
        say("ready")
    } catch {
        say("failed=\(error)")
        exit(70)
    }
}

if arguments.contains("--detach") {
    do {
        for description in try host.existing() {
            let session = try host.adopt(description.id, onUpdate: {})
            session.detach()
            say("detached=\(description.id.value)")
        }
        say("ready")
    } catch {
        say("failed=\(error)")
        exit(70)
    }
}

if arguments.contains("--wedge") {
    do {
        guard let first = try host.existing().first else {
            say("failed=nothing to wedge")
            exit(70)
        }
        let session = try host.adopt(first.id, onUpdate: {})
        say("wedged=\(first.id.value)")
        say("ready")
        // Never takes a delta, so the acknowledgement never goes and the daemon's writer
        // fills. The session must keep running regardless, and the others must stay answerable.
        _ = session
        while true { sleep(60) }
    } catch {
        say("failed=\(error)")
        exit(70)
    }
}

if arguments.contains("--end-all") {
    do {
        for description in try host.existing() {
            host.end(description.id)
            say("ended=\(description.id.value)")
        }
        say("ready")
    } catch {
        say("failed=\(error)")
        exit(70)
    }
}

if arguments.contains("--stay") {
    while true { sleep(60) }
}
exit(0)
