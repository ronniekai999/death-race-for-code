// vthost: a headless host for the Death Race terminal engine.
//
//   vthost run [options] -- program [args...]   be the terminal for a program (esctest uses this)
//   vthost replay [options] file                feed a recording to the engine, print the screen
//   vthost bench [file...]                      measure parser and screen throughput
//   vthost smoke                                run a shell on a pseudo-terminal and check it works
//   vthost version

import PTYKit
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

let version = "0.1.0"

func usage() -> Never {
    print(
        """
        usage:
          vthost run [--columns N] [--rows N] [--checksums] [--dump] -- program [args...]
              Runs program on a pseudo-terminal with VTCore as the terminal, answering its
              queries, until it exits. --checksums answers DECRQCRA (for esctest); --dump
              prints the final screen. Exits with the program's status.
          vthost replay [--columns N] [--rows N] [--scrollback] file
              Feeds a recorded byte stream to the engine and prints the screen.
          vthost bench [--seconds S] [file...]
              Measures throughput on built-in workloads, or on the given recordings.
          vthost smoke
              Spawns /bin/sh on a pseudo-terminal, runs a command and checks the output.
          vthost version
        """)
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
arguments.removeFirst()

switch command {
case "run": exit(runCommand(arguments))
case "replay": exit(replayCommand(arguments))
case "bench": exit(benchCommand(arguments))
case "smoke": exit(smokeCommand(arguments))
case "version":
    print("vthost \(version)")
default:
    usage()
}

// MARK: - Options

struct Options {
    var columns = 80
    var rows = 24
    var checksums = false
    var dump = false
    var scrollback = false
    var seconds = 1.0
    var rest: [String] = []

    init(_ arguments: [String]) {
        var index = 0
        func value() -> String {
            index += 1
            guard index < arguments.count else { usage() }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--columns": columns = Int(value()) ?? columns
            case "--rows": rows = Int(value()) ?? rows
            case "--checksums": checksums = true
            case "--dump": dump = true
            case "--scrollback": scrollback = true
            case "--seconds": seconds = Double(value()) ?? seconds
            case "--":
                rest = Array(arguments[(index + 1)...])
                return
            default:
                rest = Array(arguments[index...])
                return
            }
            index += 1
        }
    }
}

// MARK: - run

func runCommand(_ arguments: [String]) -> Int32 {
    let options = Options(arguments)
    guard let program = options.rest.first else { usage() }
    guard let path = resolve(program) else {
        printError("vthost: \(program): not found")
        return 127
    }
    let terminal = Terminal(
        Terminal.Configuration(
            columns: options.columns, rows: options.rows, answersChecksumRequests: options.checksums,
            version: version))
    let launch = ShellLaunch(
        executable: path, arguments: options.rest,
        environment: ShellLaunch.terminalEnvironment(inheriting: ShellLaunch.processEnvironment(), appVersion: version))
    let pty: PseudoTerminal
    do {
        pty = try PseudoTerminal.spawn(
            launch, size: TerminalSize(rows: UInt16(clamping: options.rows), columns: UInt16(clamping: options.columns))
        )
    } catch {
        printError("vthost: could not start \(program): \(error)")
        return 126
    }

    let exitWatch = pty.makeExitWatch()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var outgoing: [UInt8] = []
    var exited = false
    var closed = false
    while !closed {
        var fds = [
            pollfd(fd: pty.masterFD, events: Int16(POLLIN) | (outgoing.isEmpty ? 0 : Int16(POLLOUT)), revents: 0)
        ]
        if let exitWatch, !exited { fds.append(pollfd(fd: exitWatch, events: Int16(POLLIN), revents: 0)) }
        while poll(&fds, nfds_t(fds.count), -1) < 0 && errno == EINTR {}
        if fds.count > 1 && fds[1].revents != 0 { exited = true }

        reading: while true {
            switch buffer.withUnsafeMutableBytes({ pty.read(into: $0) }) {
            case .bytes(let n):
                buffer.withUnsafeBufferPointer { terminal.feed(UnsafeBufferPointer(rebasing: $0[0..<n])) }
                outgoing += terminal.takeReplies()
            case .wouldBlock:
                break reading
            case .closed:
                closed = true
                break reading
            }
        }
        while !outgoing.isEmpty {
            guard case .wrote(let n) = outgoing.withUnsafeBytes({ pty.write($0) }), n > 0 else { break }
            outgoing.removeFirst(n)
        }
        if exited { closed = true }
    }

    let status = pty.waitForExit(timeoutMilliseconds: 1_000) ?? pty.hangUp()
    pty.close()
    if let exitWatch { close(exitWatch) }
    if options.dump { printScreen(terminal, scrollback: false) }
    switch status {
    case .exited(let code)?: return code
    case .signaled(let signal)?: return 128 + signal
    case nil: return 1
    }
}

/// The program's path, searching PATH when it has no slash.
func resolve(_ program: String) -> String? {
    if program.contains("/") { return access(program, X_OK) == 0 ? program : nil }
    let path = ShellLaunch.processEnvironment()["PATH"] ?? "/usr/bin:/bin"
    for directory in path.split(separator: ":") {
        let candidate = "\(directory)/\(program)"
        if access(candidate, X_OK) == 0 { return candidate }
    }
    return nil
}

// MARK: - replay

func replayCommand(_ arguments: [String]) -> Int32 {
    let options = Options(arguments)
    guard let file = options.rest.first else { usage() }
    guard let bytes = readFile(file) else {
        printError("vthost: cannot read \(file)")
        return 1
    }
    let terminal = Terminal(Terminal.Configuration(columns: options.columns, rows: options.rows))
    terminal.feed(bytes)
    printScreen(terminal, scrollback: options.scrollback)
    return 0
}

func printScreen(_ terminal: Terminal, scrollback: Bool) {
    if scrollback {
        for index in 0..<terminal.scrollbackCount { print(text(of: terminal.scrollbackRow(index))) }
        print("---- screen ----")
    }
    for y in 0..<terminal.rows { print(text(of: terminal.row(y))) }
    print("---- cursor \(terminal.cursor.y + 1);\(terminal.cursor.x + 1) ----")
}

func text(of row: Row) -> String {
    var out = ""
    for column in 0..<row.columns where row.cells[column].width != .spacerTail {
        let scalars = row.scalars(at: column)
        if scalars.isEmpty {
            out += " "
        } else {
            for scalar in scalars { out.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}") }
        }
    }
    while out.hasSuffix(" ") { out.removeLast() }
    return out
}

func readFile(_ path: String) -> [UInt8]? {
    guard let file = fopen(path, "rb") else { return nil }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = fread(&chunk, 1, chunk.count, file)
        if n == 0 { break }
        bytes += chunk[0..<n]
    }
    return bytes
}

// MARK: - bench

func benchCommand(_ arguments: [String]) -> Int32 {
    let options = Options(arguments)
    var workloads: [(String, [UInt8])] = []
    if options.rest.isEmpty {
        workloads = Workloads.all
    } else {
        for file in options.rest {
            guard let bytes = readFile(file) else {
                printError("vthost: cannot read \(file)")
                return 1
            }
            workloads.append((file, bytes))
        }
    }
    #if DEBUG
        print("note: a debug build; measure with `swift run -c release vthost bench`")
    #endif
    for (name, bytes) in workloads {
        let terminal = Terminal(Terminal.Configuration(columns: 120, rows: 40, scrollbackLimitBytes: 10 * 1024 * 1024))
        terminal.feed(bytes)  // warm up
        var fed = 0
        let start = PseudoTerminal.monotonicMilliseconds()
        var elapsed = 0
        repeat {
            terminal.feed(bytes)
            _ = terminal.takeReplies()
            _ = terminal.takeEvents()
            fed += bytes.count
            elapsed = PseudoTerminal.monotonicMilliseconds() - start
        } while Double(elapsed) < options.seconds * 1_000
        let megabytesPerSecond = Double(fed) / 1_048_576 / (Double(max(elapsed, 1)) / 1_000)
        let padded = name + String(repeating: " ", count: max(1, 12 - name.count))
        print("\(padded)\(format1(megabytesPerSecond)) MB/s")
    }
    return 0
}

func format1(_ value: Double) -> String {
    let tenths = Int((value * 10).rounded())
    return "\(tenths / 10).\(tenths % 10)"
}

/// Synthetic output resembling what real programs send.
enum Workloads {
    static var all: [(String, [UInt8])] {
        [("ascii", ascii), ("sgr", sgr), ("unicode", unicode), ("cursor", cursor)]
    }

    /// Log-like lines: what `cat` and build output look like.
    static var ascii: [UInt8] {
        var out: [UInt8] = []
        var line = 0
        while out.count < 4 << 20 {
            out += Array("[\(line)] Compiling DeathRaceKit module_\(line % 97).swift (\(line * 7 % 1000) ms)\r\n".utf8)
            line += 1
        }
        return out
    }

    /// Colored output: ls --color, compiler diagnostics, syntax-highlighted diffs.
    static var sgr: [UInt8] {
        var out: [UInt8] = []
        var n = 0
        while out.count < 4 << 20 {
            out += Array("\u{1B}[1;3\(n % 8)mwarning\u{1B}[0m: \u{1B}[38;2;\(n % 256);120;200munused\u{1B}[0m ".utf8)
            out += Array(
                "value \u{1B}[4:3m\u{1B}[58;5;\(n % 256)m'x\(n)'\u{1B}[24;59m in \u{1B}[48;5;\(n % 256)mscope\u{1B}[0m\r\n"
                    .utf8)
            n += 1
        }
        return out
    }

    /// CJK, accents and emoji: wide characters and grapheme clusters.
    static var unicode: [UInt8] {
        var out: [UInt8] = []
        while out.count < 4 << 20 {
            out += Array("中文字符 日本語 한국어 café naïve 👍🏽 👨‍👩‍👧 🇺🇸 ❤️ résumé — “quotes” ✦ 999\r\n".utf8)
        }
        return out
    }

    /// Full-screen redraws: cursor addressing and short writes, like vim, htop and tmux.
    static var cursor: [UInt8] {
        var out: [UInt8] = []
        var n = 0
        while out.count < 4 << 20 {
            let row = n % 40 + 1
            let column = n * 7 % 100 + 1
            out += Array("\u{1B}[\(row);\(column)H\u{1B}[3\(n % 8)m\(n % 1000)\u{1B}[K\u{1B}[0m".utf8)
            n += 1
        }
        return out
    }
}

// MARK: - smoke

func smokeCommand(_ arguments: [String]) -> Int32 {
    do {
        let launch = ShellLaunch(
            executable: "/bin/sh",
            arguments: ["sh"],
            environment: ShellLaunch.terminalEnvironment(
                inheriting: ShellLaunch.processEnvironment(), appVersion: version)
        )
        let transcript = try SmokeTest.run(launch)
        print("smoke test passed")
        if arguments.contains("--verbose") { print(transcript) }
        return 0
    } catch {
        print("smoke test failed: \(error)")
        return 1
    }
}

func printError(_ message: String) {
    let line = Array((message + "\n").utf8)
    _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
}
