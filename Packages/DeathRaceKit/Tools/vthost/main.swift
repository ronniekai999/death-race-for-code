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
          vthost run [--columns N] [--rows N] [--checksums] [--dump] [--record FILE]
                     [--marks FILE] [--keys TEXT]... -- program [args...]
              Runs program on a pseudo-terminal with VTCore as the terminal, answering its
              queries, until it exits. --checksums answers DECRQCRA (for esctest); --dump
              prints the final screen; --record saves the program's output. Each --keys is
              typed once the output has been quiet for a moment (\\e \\r \\n \\t \\xHH
              escapes); after the last one and another quiet moment, the run ends with a
              hang-up. --marks saves how much output came before each --keys, one count a
              line. Exits with the program's status.
          vthost replay [--columns N] [--rows N] [--scrollback] [--marks FILE] file
              Feeds a recorded byte stream to the engine and prints the screen: its text,
              the cursor and the styled runs, the form the corpus goldens hold. With
              --marks, prints the screen at each mark too, as it was when keys were typed.
          vthost bench [--seconds S] [--only ascii|sgr|unicode|cursor] [file...]
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
    var only: String?
    var record: String?
    var marks: String?
    var keys: [[UInt8]] = []
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
            case "--only": only = value()
            case "--record": record = value()
            case "--marks": marks = value()
            case "--keys": keys.append(unescape(value()))
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
    var recording: [UInt8] = []
    var recorded = 0  // bytes of output so far, recorded or not
    var marks: [Int] = []
    var keys = options.keys[...]
    let settle = 300  // ms of quiet output before typing the next keys
    var lastOutput = PseudoTerminal.monotonicMilliseconds()
    // A scripted run ends after its last keys, once the screen has settled.
    var scripted = !options.keys.isEmpty
    var exited = false
    var closed = false
    while !closed {
        var fds = [
            pollfd(fd: pty.masterFD, events: Int16(POLLIN) | (outgoing.isEmpty ? 0 : Int16(POLLOUT)), revents: 0)
        ]
        if let exitWatch, !exited { fds.append(pollfd(fd: exitWatch, events: Int16(POLLIN), revents: 0)) }
        let quietFor = PseudoTerminal.monotonicMilliseconds() - lastOutput
        let timeout: Int32 = scripted ? Int32(max(settle - quietFor, 0)) : -1
        while poll(&fds, nfds_t(fds.count), timeout) < 0 && errno == EINTR {}
        if fds.count > 1 && fds[1].revents != 0 { exited = true }

        reading: while true {
            switch buffer.withUnsafeMutableBytes({ pty.read(into: $0) }) {
            case .bytes(let n):
                buffer.withUnsafeBufferPointer { terminal.feed(UnsafeBufferPointer(rebasing: $0[0..<n])) }
                if options.record != nil { recording += buffer[0..<n] }
                recorded += n
                outgoing += terminal.takeReplies()
                lastOutput = PseudoTerminal.monotonicMilliseconds()
            case .wouldBlock:
                break reading
            case .closed:
                closed = true
                break reading
            }
        }
        if scripted && PseudoTerminal.monotonicMilliseconds() - lastOutput >= settle {
            if let next = keys.popFirst() {
                outgoing += next
                marks.append(recorded)
                lastOutput = PseudoTerminal.monotonicMilliseconds()
            } else {
                scripted = false
                closed = true
            }
        }
        while !outgoing.isEmpty {
            guard case .wrote(let n) = outgoing.withUnsafeBytes({ pty.write($0) }), n > 0 else { break }
            outgoing.removeFirst(n)
        }
        if exited { closed = true }
    }

    if let path = options.record, !writeFile(path, recording) {
        printError("vthost: cannot write \(path)")
    }
    if let path = options.marks, !writeFile(path, Array(marks.map { "\($0)\n" }.joined().utf8)) {
        printError("vthost: cannot write \(path)")
    }
    let status = pty.waitForExit(timeoutMilliseconds: options.keys.isEmpty ? 1_000 : 0) ?? pty.hangUp()
    pty.close()
    if let exitWatch { close(exitWatch) }
    if options.dump { print(terminal.dump(), terminator: "") }
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
    var marks: [Int] = []
    if let path = options.marks {
        guard let text = readFile(path) else {
            printError("vthost: cannot read \(path)")
            return 1
        }
        marks = String(decoding: text, as: UTF8.self).split(separator: "\n").compactMap { Int($0) }
        guard marks.allSatisfy({ $0 <= bytes.count }), marks == marks.sorted() else {
            printError("vthost: \(path) does not fit \(file)")
            return 1
        }
    }
    let terminal = Terminal(Terminal.Configuration(columns: options.columns, rows: options.rows))
    var fed = 0
    for (index, mark) in marks.enumerated() {
        terminal.feed(Array(bytes[fed..<mark]))
        fed = mark
        print("==== before keys \(index + 1), after \(mark) bytes ====")
        print(terminal.dump(), terminator: "")
    }
    terminal.feed(Array(bytes[fed...]))
    if !marks.isEmpty { print("==== at the end, after \(bytes.count) bytes ====") }
    print(terminal.dump(scrollback: options.scrollback), terminator: "")
    return 0
}

func writeFile(_ path: String, _ bytes: [UInt8]) -> Bool {
    guard let file = fopen(path, "wb") else { return false }
    defer { fclose(file) }
    return fwrite(bytes, 1, bytes.count, file) == bytes.count
}

/// `\e`, `\r`, `\n`, `\t`, `\\` and `\xHH` escapes, for scripted keys.
func unescape(_ text: String) -> [UInt8] {
    var out: [UInt8] = []
    var bytes = Array(text.utf8)[...]
    while let byte = bytes.popFirst() {
        guard byte == UInt8(ascii: "\\"), let next = bytes.popFirst() else {
            out.append(byte)
            continue
        }
        switch next {
        case UInt8(ascii: "e"): out.append(0x1B)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "x"):
            out.append(UInt8(String(decoding: bytes.prefix(2), as: UTF8.self), radix: 16) ?? 0x3F)
            bytes = bytes.dropFirst(2)
        default: out.append(next)
        }
    }
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
        workloads = Workloads.all.filter { options.only == nil || $0.0 == options.only }
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
