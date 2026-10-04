import Foundation
import SwiftTerm
import VTCore

// vtdiff: VTCore next to SwiftTerm, the engine most Swift terminals embed.
//
//   vtdiff bench [--seconds S]     throughput on vthost's workloads, both engines
//   vtdiff corpus [--verbose] DIR  every screen of every recording in DIR, both engines
//
// SwiftTerm is a referee, not the reference: where the two disagree, xterm (as esctest
// and vttest encode it) decides. CONFORMANCE.md lists the divergences and who is right.

func usage() -> Never {
    print("usage: vtdiff bench [--seconds S] | vtdiff corpus [--verbose] DIR")
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
arguments.removeFirst()

switch command {
case "bench":
    var seconds = 1.0
    if let i = arguments.firstIndex(of: "--seconds"), i + 1 < arguments.count {
        seconds = Double(arguments[i + 1]) ?? seconds
    }
    bench(seconds: seconds)
case "corpus":
    let verbose = arguments.contains("--verbose")
    guard let directory = arguments.last(where: { !$0.hasPrefix("--") }) else { usage() }
    exit(corpus(directory, verbose: verbose))
default:
    usage()
}

// MARK: - The two engines

/// SwiftTerm wants a delegate; the referee shows nothing and answers nothing.
final class Referee: TerminalDelegate {
    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
}

protocol Engine {
    func feed(_ bytes: ArraySlice<UInt8>)
    /// Each visible row as text, trailing blanks trimmed; then the cursor, 1-based.
    var screen: (rows: [String], cursor: (row: Int, column: Int)) { get }
}

final class Ours: Engine {
    let terminal: VTCore.Terminal

    init(columns: Int, rows: Int) {
        terminal = VTCore.Terminal(
            VTCore.Terminal.Configuration(columns: columns, rows: rows, scrollbackLimitBytes: 10 * 1024 * 1024))
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        bytes.withUnsafeBufferPointer { terminal.feed($0) }
        _ = terminal.takeReplies()
        _ = terminal.takeEvents()
    }

    var screen: (rows: [String], cursor: (row: Int, column: Int)) {
        ((0..<terminal.rows).map { terminal.row($0).text }, (terminal.cursor.y + 1, terminal.cursor.x + 1))
    }
}

final class Theirs: Engine {
    let referee = Referee()
    let terminal: SwiftTerm.Terminal

    init(columns: Int, rows: Int) {
        terminal = SwiftTerm.Terminal(
            delegate: referee, options: TerminalOptions(cols: columns, rows: rows, scrollback: 10_000))
        terminal.silentLog = true
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(buffer: bytes)
    }

    var screen: (rows: [String], cursor: (row: Int, column: Int)) {
        let rows = (0..<terminal.rows).map { row in
            var text = ""
            for column in 0..<terminal.cols {
                guard let cell = terminal.getCharData(col: column, row: row), cell.width != 0 else { continue }
                let character = terminal.getCharacter(for: cell)
                text.append(character == "\u{0}" ? " " : character)
            }
            while text.hasSuffix(" ") { text.removeLast() }
            return text
        }
        let cursor = terminal.getCursorLocation()
        return (rows, (cursor.y + 1, cursor.x + 1))
    }
}

// MARK: - bench

func bench(seconds: Double) {
    #if DEBUG
        print("note: a debug build; measure with `swift run -c release vtdiff bench`")
    #endif
    print("workload     VTCore      SwiftTerm   ratio")
    for (name, bytes) in Workloads.all {
        let ours = throughput(Ours(columns: 120, rows: 40), bytes, seconds)
        let theirs = throughput(Theirs(columns: 120, rows: 40), bytes, seconds)
        let row = [
            name.padding(toLength: 13, withPad: " ", startingAt: 0),
            String(format: "%6.1f MB/s ", ours),
            String(format: "%6.1f MB/s ", theirs),
            String(format: "%5.1fx", ours / theirs),
        ]
        print(row.joined())
    }
}

/// MB/s feeding `bytes` again and again for `seconds`, after one pass to warm up.
func throughput(_ engine: Engine, _ bytes: [UInt8], _ seconds: Double) -> Double {
    engine.feed(bytes[...])
    let clock = ContinuousClock()
    let start = clock.now
    var fed = 0
    var elapsed = 0.0
    repeat {
        engine.feed(bytes[...])
        fed += bytes.count
        let duration = clock.now - start
        elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    } while elapsed < seconds
    return Double(fed) / 1_048_576 / elapsed
}

// MARK: - corpus

/// Replays every recording in `directory` through both engines and compares the screens a
/// golden holds: at every mark (a key press) and at the end. Returns 0; divergences are
/// findings to review, not failures.
func corpus(_ directory: String, verbose: Bool) -> Int32 {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        .filter { $0.hasSuffix(".bin") }.sorted()
    guard !files.isEmpty else {
        print("vtdiff: no recordings in \(directory)")
        return 1
    }
    var screens = 0
    var differing = 0
    for file in files {
        let name = String(file.dropLast(4))
        guard let data = FileManager.default.contents(atPath: directory + "/" + file) else { continue }
        let bytes = [UInt8](data)
        let marks =
            FileManager.default.contents(atPath: directory + "/" + name + ".marks").map {
                String(decoding: $0, as: UTF8.self).split(separator: "\n").compactMap { Int($0) }
            } ?? []
        let ours = Ours(columns: 80, rows: 24)
        let theirs = Theirs(columns: 80, rows: 24)
        var fed = 0
        var findings: [String] = []
        for (index, mark) in (marks + [bytes.count]).enumerated() {
            ours.feed(bytes[fed..<mark])
            theirs.feed(bytes[fed..<mark])
            fed = mark
            screens += 1
            let a = ours.screen
            let b = theirs.screen
            let rows = (0..<a.rows.count).filter { a.rows[$0] != b.rows[$0] }
            let cursor = a.cursor != b.cursor
            guard !rows.isEmpty || cursor else { continue }
            differing += 1
            let label = index < marks.count ? "before keys \(index + 1)" : "at the end"
            var finding = "  \(label): \(rows.count) rows differ"
            if cursor { finding += "; cursor \(a.cursor.row);\(a.cursor.column) vs \(b.cursor.row);\(b.cursor.column)" }
            if verbose, let row = rows.first {
                finding +=
                    "\n    row \(row + 1) VTCore:    \(a.rows[row])\n    row \(row + 1) SwiftTerm: \(b.rows[row])"
            }
            findings.append(finding)
        }
        print("\(name): \(marks.count + 1) screens, \(findings.count) differ")
        for finding in findings { print(finding) }
    }
    print("\(screens) screens, \(differing) differ")
    return 0
}

// MARK: - Workloads (the same as `vthost bench`)

enum Workloads {
    static var all: [(String, [UInt8])] {
        [("ascii", ascii), ("sgr", sgr), ("unicode", unicode), ("cursor", cursor)]
    }

    static var ascii: [UInt8] {
        var out: [UInt8] = []
        var line = 0
        while out.count < 4 << 20 {
            out += Array("[\(line)] Compiling DeathRaceKit module_\(line % 97).swift (\(line * 7 % 1000) ms)\r\n".utf8)
            line += 1
        }
        return out
    }

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

    static var unicode: [UInt8] {
        var out: [UInt8] = []
        while out.count < 4 << 20 {
            out += Array("中文字符 日本語 한국어 café naïve 👍🏽 👨‍👩‍👧 🇺🇸 ❤️ résumé — “quotes” ✦ 999\r\n".utf8)
        }
        return out
    }

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
