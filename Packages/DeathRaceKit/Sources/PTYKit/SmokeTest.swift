#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// End-to-end check that a shell runs on our pseudo-terminal: spawn it, type
/// `echo $((900+99))`, and wait for `999`. The typed text never contains "999", so seeing
/// it proves the shell executed the command rather than the terminal echoing input.
///
/// Used by the PTYKit tests on Linux and by `DeathRace --smoke-test` on macOS CI.
public enum SmokeTest {
    public struct Failure: Error, CustomStringConvertible {
        public let reason: String
        public let transcript: String
        public var description: String { "\(reason)\n--- transcript ---\n\(transcript)" }
    }

    @discardableResult
    public static func run(_ launch: ShellLaunch, timeoutMilliseconds: Int = 5_000) throws -> String {
        let terminal = try PseudoTerminal.spawn(launch, size: TerminalSize(rows: 24, columns: 80))
        defer { terminal.hangUp() }

        guard terminal.writeAll("echo $((900+99))\n") else {
            throw Failure(reason: "could not type into the terminal", transcript: "")
        }
        var transcript: [UInt8] = []
        let found = readUntil(
            terminal, contains: Array("999".utf8), into: &transcript, timeoutMilliseconds: timeoutMilliseconds)
        let text = String(decoding: transcript, as: UTF8.self)
        guard found else {
            throw Failure(reason: "the shell did not print 999 within \(timeoutMilliseconds) ms", transcript: text)
        }
        return text
    }

    /// Reads until `needle` appears in `transcript`, the terminal closes, or time runs out.
    public static func readUntil(
        _ terminal: PseudoTerminal,
        contains needle: [UInt8],
        into transcript: inout [UInt8],
        timeoutMilliseconds: Int
    ) -> Bool {
        let deadline = PseudoTerminal.monotonicMilliseconds() + timeoutMilliseconds
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if transcript.contains(subsequence: needle) { return true }
            let remaining = deadline - PseudoTerminal.monotonicMilliseconds()
            if remaining <= 0 { return false }
            guard terminal.poll(timeoutMilliseconds: Int32(min(remaining, 250))) else { continue }
            // Drain everything that is ready before checking again.
            drain: while true {
                let result = buffer.withUnsafeMutableBytes { terminal.read(into: $0) }
                switch result {
                case .bytes(let n): transcript.append(contentsOf: buffer[0..<n])
                case .wouldBlock: break drain
                case .closed: return transcript.contains(subsequence: needle)
                }
            }
        }
    }
}

extension Array where Element: Equatable {
    func contains(subsequence needle: [Element]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return needle.isEmpty }
        for start in 0...(count - needle.count) where self[start] == needle[0] {
            if self[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }
}
