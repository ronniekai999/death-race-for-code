import Foundation
import Testing

@testable import VTCore

/// Real programs (vim, less, tmux, htop, nano…) recorded through vthost by
/// scripts/record-corpus.sh. Replaying a recording must leave exactly the screen in its golden:
/// text, cursor and styles. After a deliberate change to the engine, regenerate the goldens with
/// `scripts/record-corpus.sh --goldens` and review the diff.
@Suite struct CorpusTests {
    static let directory: String = {
        var path = #filePath
        while let last = path.last, last != "/" { path.removeLast() }
        return path + "../Fixtures/corpus/"
    }()

    static let names: [String] =
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        .filter { $0.hasSuffix(".bin") }
        .map { String($0.dropLast(4)) }
        .sorted()

    private func load(_ name: String) throws -> (recording: [UInt8], golden: String) {
        let recording = try #require(FileManager.default.contents(atPath: Self.directory + name + ".bin"))
        let golden = try #require(FileManager.default.contents(atPath: Self.directory + name + ".screen"))
        return ([UInt8](recording), String(decoding: golden, as: UTF8.self))
    }

    /// The goldens are 80x24, the size the programs were recorded at.
    private func replay(_ chunks: [ArraySlice<UInt8>]) -> String {
        let terminal = Terminal(Terminal.Configuration(columns: 80, rows: 24))
        for chunk in chunks { terminal.feed(Array(chunk)) }
        return terminal.dump()
    }

    @Test func corpusIsThere() {
        #expect(Self.names.count >= 7, "no recordings found in \(Self.directory)")
    }

    @Test(arguments: names)
    func replayMatchesGolden(_ name: String) throws {
        let (recording, golden) = try load(name)
        expectSame(replay([recording[...]]), golden, name)
    }

    /// Programs' output arrives in arbitrary pieces: splitting it anywhere, inside escape
    /// sequences and UTF-8 characters included, must not change the screen.
    @Test(arguments: names)
    func replayInPiecesMatchesGolden(_ name: String) throws {
        let (recording, golden) = try load(name)
        let bytes = recording.map { [$0][...] }
        expectSame(replay(bytes), golden, "\(name), a byte at a time")
        var random = SplitMix64(seed: 999)
        var chunks: [ArraySlice<UInt8>] = []
        var start = 0
        while start < recording.count {
            let end = min(start + Int(random.next() % 64) + 1, recording.count)
            chunks.append(recording[start..<end])
            start = end
        }
        expectSame(replay(chunks), golden, "\(name), in random pieces")
    }

    /// Compares line by line, so a failure names the first line that differs.
    private func expectSame(_ actual: String, _ golden: String, _ label: String) {
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let goldenLines = golden.split(separator: "\n", omittingEmptySubsequences: false)
        guard actualLines != goldenLines else { return }
        let common = min(actualLines.count, goldenLines.count)
        let index = (0..<common).first { actualLines[$0] != goldenLines[$0] } ?? common
        let got = index < actualLines.count ? String(actualLines[index]) : "(nothing)"
        let want = index < goldenLines.count ? String(goldenLines[index]) : "(nothing)"
        Issue.record("\(label): line \(index + 1) differs\n  got:  \(got)\n  want: \(want)")
    }
}

/// A small seeded generator, so random splits are the same on every run.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
