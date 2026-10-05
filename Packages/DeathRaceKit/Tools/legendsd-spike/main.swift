// legendsd-spike: what macOS privacy protection (TCC) lets this process read, and a shell it
// starts on a pseudo-terminal, and whom macOS holds responsible for each. Phase 7 moves the
// shells into a daemon (legendsd); this one-day spike finds out whether those shells would
// still be attributed to Death Race, before anything is built on it. See docs/SPIKE.md for
// the steps on a Mac. Temporary: it goes once the verdict is in.
//
//   legendsd-spike --probe [--as child|agent|spawned] [--probe-again-after SECONDS] [--stay SECONDS]
//
// `--as` says how the helper was started, because nothing outside can tell: a daemon the app
// spawned has launchd for a parent once the app has gone, exactly like an agent.
// `--probe-again-after` probes a second time that many seconds later, so one run records
// attribution both while the process that started it is alive and after it has gone.
//
// The results go to ~/Library/Logs/DeathRace/legendsd-spike-*.json, standard output and the
// unified log (subsystem local.deathraceforcode.DeathRace, category Spike). Afterwards the
// helper stays alive for --stay seconds (30 by default), so `launchctl procinfo` can look at it.

import Darwin
import Foundation
import PTYKit
import Security
import os

struct ProbeResult: Codable {
    var name: String
    var path: String
    /// allowed, denied (a TCC refusal, EPERM), missing, or an errno.
    var result: String
}

struct ProcessFacts: Codable {
    var pid: Int32
    var name: String
    var parentPID: Int32?
    var responsiblePID: Int32?
    var responsibleName: String?
}

struct Report: Codable {
    var date: String
    var system: String
    var signing: String
    /// How this helper was started: child, agent or spawned (`--as`).
    var launchedBy: String
    /// `first`, or `again` once whatever started it has had time to go.
    var when: String
    var helper: ProcessFacts
    var inProcess: [ProbeResult]
    var shell: ProcessFacts?
    var fromShell: [ProbeResult]
    var shellError: String?
}

let log = Logger(subsystem: "local.deathraceforcode.DeathRace", category: "Spike")
let arguments = CommandLine.arguments
guard arguments.contains("--probe") else {
    let usage = "usage: legendsd-spike --probe [--as child|agent|spawned] [--probe-again-after S] [--stay S]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}

/// The word after `flag`, if it is there.
func word(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let stay = word(after: "--stay").flatMap(Int.init) ?? 30
let again = word(after: "--probe-again-after").flatMap(Int.init) ?? 0
let watchPID = word(after: "--probe-again-when-gone").flatMap(Int32.init)
let launchedBy = word(after: "--as") ?? (getppid() == 1 ? "agent" : "child")
/// Long enough for the slowest step of docs/SPIKE.md, short enough not to be left behind.
let longestWait = 600

// The pipe to whatever started this helper closes when it goes, and the helper has to outlive
// that to answer the question it exists for. So a closed standard output is nothing: the JSON
// file and the unified log are the real results.
signal(SIGPIPE, SIG_IGN)

/// Writes to standard output, and says nothing when nobody is reading any more.
func say(_ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buffer in
        guard let start = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = write(1, start + offset, buffer.count - offset)
            if written > 0 {
                offset += written
            } else if !(written < 0 && errno == EINTR) {
                return
            }
        }
    }
}

/// The places TCC guards that a terminal user reaches for, and a mounted volume if there is one.
func targets() -> [(name: String, path: String)] {
    let home = NSHomeDirectory()
    var list: [(name: String, path: String)] = [
        ("Desktop", home + "/Desktop"),
        ("Documents", home + "/Documents"),
        ("Downloads", home + "/Downloads"),
        ("iCloud Drive", home + "/Library/Mobile Documents/com~apple~CloudDocs"),
        ("Mail (Full Disk Access)", home + "/Library/Mail"),
        ("Safari (Full Disk Access)", home + "/Library/Safari"),
    ]
    let volumes =
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    if let volume = volumes.first(where: { $0.path.hasPrefix("/Volumes/") }) {
        list.append(("Volume " + volume.lastPathComponent, volume.path))
    }
    return list
}

/// Lists `path` the way `ls` would, from this process.
func probe(_ path: String) -> String {
    var info = stat()
    guard stat(path, &info) == 0 else { return errno == ENOENT ? "missing" : "error \(errno)" }
    guard let directory = opendir(path) else { return errno == EPERM ? "denied" : "error \(errno)" }
    defer { closedir(directory) }
    errno = 0
    _ = readdir(directory)
    return errno == EPERM ? "denied" : "allowed"
}

/// Whom macOS holds responsible for `pid` (the process TCC asks about), through the private
/// call `launchctl procinfo` reports. Spike only: never in the app.
func responsiblePID(for pid: Int32) -> Int32? {
    typealias Responsible = @convention(c) (Int32) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    else { return nil }
    let responsible = unsafeBitCast(symbol, to: Responsible.self)(pid)
    return responsible > 0 ? responsible : nil
}

func facts(_ pid: Int32, parent: Int32? = nil) -> ProcessFacts {
    let responsible = responsiblePID(for: pid)
    return ProcessFacts(
        pid: pid, name: PseudoTerminal.processName(pid) ?? "?", parentPID: parent, responsiblePID: responsible,
        responsibleName: responsible.flatMap(PseudoTerminal.processName))
}

/// This executable's signing identifier and team, as macOS sees them.
func signing() -> String {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
        SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess,
        let dictionary = information as? [String: Any]
    else { return "unsigned or unreadable" }
    let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String ?? "?"
    let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? "no team (ad-hoc)"
    return "\(identifier), \(team)"
}

/// One pass over `places`: from this process, then from zsh on a pseudo-terminal, with whom
/// macOS holds responsible for each.
func runPass(_ when: String, as launchedBy: String, over places: [(name: String, path: String)]) -> Report {
    var report = Report(
        date: ISO8601DateFormatter().string(from: Date()), system: ProcessInfo.processInfo.operatingSystemVersionString,
        signing: signing(), launchedBy: launchedBy, when: when, helper: facts(getpid(), parent: getppid()),
        inProcess: [], shell: nil, fromShell: [], shellError: nil)
    report.inProcess = places.map { ProbeResult(name: $0.name, path: $0.path, result: probe($0.path)) }

    // The same places from zsh on a pseudo-terminal, the way Death Race runs shells: a direct
    // child, no double fork. A TCC prompt holds `ls` until it is answered, hence the long wait.
    let script = """
        i=0
        for p in "$@"; do
          if [ ! -e "$p" ]; then r=missing
          elif ls "$p" >/dev/null 2>&1; then r=allowed
          else r=denied; fi
          echo "PROBE:$i:$r"; i=$((i+1))
        done
        echo PROBE-DONE
        sleep 2
        """
    do {
        let launch = ShellLaunch(
            executable: "/bin/zsh", arguments: ["zsh", "-f", "-c", script, "zsh"] + places.map { $0.path },
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TERM": "xterm-256color"],
            workingDirectory: NSHomeDirectory())
        let shell = try PseudoTerminal.spawn(launch, size: TerminalSize(rows: 24, columns: 80))
        var transcript: [UInt8] = []
        let finished = SmokeTest.readUntil(
            shell, contains: Array("PROBE-DONE".utf8), into: &transcript, timeoutMilliseconds: 300_000)
        // The shell sleeps after its last probe, so it can still be asked about.
        report.shell = facts(shell.pid, parent: getpid())
        _ = shell.hangUp()
        let lines = String(decoding: transcript, as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines where line.hasPrefix("PROBE:") {
            let fields = line.split(separator: ":")
            guard fields.count == 3, let index = Int(fields[1]), index < places.count else { continue }
            report.fromShell.append(
                ProbeResult(name: places[index].name, path: places[index].path, result: String(fields[2])))
        }
        if !finished { report.shellError = "the shell did not finish within five minutes" }
    } catch {
        report.shellError = "the shell did not start: \(error)"
    }
    return report
}

/// Writes `report` where docs/SPIKE.md says to look for it, and says it out loud.
func keep(_ report: Report) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = (try? encoder.encode(report)) ?? Data()
    let text = String(decoding: json, as: UTF8.self)
    let directory = NSHomeDirectory() + "/Library/Logs/DeathRace"
    let stamp = report.date.replacingOccurrences(of: ":", with: "-")
    let file = "\(directory)/legendsd-spike-\(stamp)-\(report.launchedBy)-\(report.when).json"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: file, contents: json)
    say(text + "\n")
    log.notice("legendsd-spike wrote \(file, privacy: .public): \(text, privacy: .public)")
}

/// Waits for `pid` to go, up to `longestWait`. True once it has. A pid this process is not the
/// parent of leaves no zombie, so `kill(pid, 0)` failing with ESRCH is the whole answer.
func waitForExit(of pid: Int32) -> Bool {
    for _ in 0..<(longestWait * 4) {
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        usleep(250_000)
    }
    return false
}

let places = targets()
keep(runPass("first", as: launchedBy, over: places))
if let watchPID {
    say("pid \(getpid()); waiting for pid \(watchPID) to go, then probing again — quit Death Race now\n")
    if waitForExit(of: watchPID) {
        keep(runPass("again", as: launchedBy, over: places))
    } else {
        say("pid \(watchPID) was still running after \(longestWait) s; no second pass\n")
    }
} else if again > 0 {
    say("pid \(getpid()); probing again in \(again) s — quit Death Race now, to see what changes without it\n")
    sleep(UInt32(again))
    keep(runPass("again", as: launchedBy, over: places))
}
if stay > 0 {
    say("pid \(getpid()); staying \(stay) s for `sudo launchctl procinfo \(getpid())`\n")
    sleep(UInt32(stay))
}
