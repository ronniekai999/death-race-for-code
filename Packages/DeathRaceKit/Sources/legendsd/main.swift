// legendsd: the session daemon behind Legends Never Die. It holds the pseudo-terminals and
// the terminal engines, so a session outlives the app that started it — quit, crash, or
// update — and can be taken up again when one comes back.
//
//   legendsd --socket PATH --lock PATH [--log PATH] [--sessions N] [--idle-exit MS]
//            [--write-stall MS] [--stay]
//
// The app starts it and never speaks to it except over the socket. It exits on its own once
// it holds no sessions and nobody is connected, so an app that is uninstalled leaves nothing
// behind. A signal ends the sessions it holds, and ends them properly: it owns every one of
// their pseudo-terminals, so it cannot hand them on to anything — which is also why it only
// exits on its own once it holds nothing at all.

import Foundation
import IPCKit
import PTYKit
import SessionIPC

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Who the daemon will talk to: the app, and nothing else. Its own signing identifier is
/// what `scripts/bundle.sh` gives it.
let trustedClientIdentifier = "local.deathraceforcode.DeathRace"

let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard let socketPath = value(after: "--socket"), let lockPath = value(after: "--lock") else {
    let usage = "usage: legendsd --socket PATH --lock PATH [--log PATH] [--sessions N] [--idle-exit MS]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}

// Standard output and error go to a file of their own before anything else can write to them.
//
// The app starts the daemon, so without this they are pipes the app holds — and when the app
// goes, a write to one would fail, or worse, fill and block the thread that made it. A daemon
// that freezes on a log line takes every session it holds with it.
//
// The path is ours, but what is at it need not be. The folder is 0700, which keeps other
// users out and does nothing at all about another process of this one — and this daemon is
// the app's own child precisely so that it carries the app's privacy attribution, so it can
// open files a process without that attribution cannot. A symlink planted at this path would
// otherwise be followed, and the pruning below would truncate whatever it pointed at: a
// process with no grants of its own would have found a way to destroy a file macOS was
// keeping it out of. So the folder is checked first, the open refuses a symlink, and what
// comes back has to be an ordinary file belonging to this user.
var logFD: Int32 = -1
if let logPath = value(after: "--log") {
    let folder = (logPath as NSString).deletingLastPathComponent
    if (try? secureFolder(folder, what: "the session daemon's folder")) != nil {
        let log = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var info = stat()
        if log >= 0, fstat(log, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() {
            // A log nobody prunes is a disk nobody has. A megabyte is plenty to see why
            // something went wrong, and the daemon starts often enough that losing the old one
            // costs little.
            if info.st_size > 1 << 20 { ftruncate(log, 0) }
            logFD = log
        } else if log >= 0 {
            close(log)
        }
    }
}
// Whatever happened above, this is not writing down the app's pipes: with no log to be had,
// output goes nowhere rather than somewhere that can block.
let out = logFD >= 0 ? logFD : open("/dev/null", O_WRONLY)
if out >= 0 {
    dup2(out, 1)
    dup2(out, 2)
    close(out)
}
// And nothing is read from standard input ever again.
let null = open("/dev/null", O_RDONLY)
if null >= 0 {
    dup2(null, 0)
    close(null)
}

var options = Daemon.Options(socketPath: socketPath, lockPath: lockPath)
// Only the app may speak to it, pinned by signature where there is one to pin. Said out loud
// when there is not, because a check that is not being made must not be assumed.
options.peerPolicy = PeerPolicy.strongest(for: trustedClientIdentifier)
if options.peerPolicy.isOnlySameUser {
    let note =
        "legendsd: no signature to pin, so any process of this user may connect"
        + " (an ad-hoc or unsigned build)\n"
    FileHandle.standardError.write(Data(note.utf8))
}
if let sessions = value(after: "--sessions").flatMap(Int.init), sessions > 0 {
    options.limits.sessions = sessions
}
if let idle = value(after: "--idle-exit").flatMap(Int.init), idle >= 0 {
    options.idleExitMilliseconds = idle
}
if let stall = value(after: "--write-stall").flatMap(Int.init), stall > 0 {
    options.limits.writeStallMilliseconds = stall
}
// For a test that wants a daemon to sit still rather than tidy itself away mid-assertion.
if arguments.contains("--stay") { options.stopWhenIdle = false }

do {
    let daemon = try Daemon(options)
    exit(daemon.run())
} catch {
    FileHandle.standardError.write(Data("legendsd could not start: \(error)\n".utf8))
    exit(71)
}
