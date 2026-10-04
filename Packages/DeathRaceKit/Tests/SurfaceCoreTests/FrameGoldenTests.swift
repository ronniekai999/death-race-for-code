import Foundation
import Testing

@testable import SurfaceCore

/// Real programs' recordings (Tests/Fixtures/corpus) built into the frames the app would draw
/// with the default theme, compared with the goldens in Tests/Fixtures/frames. They check the
/// whole path from bytes to GPU data: engine, deltas, mirror, colors and the frame builder.
/// After a deliberate change, regenerate them with `scripts/record-corpus.sh --goldens` and
/// review the diff.
@Suite struct FrameGoldenTests {
    static let fixtures: String = {
        var path = #filePath
        while let last = path.last, last != "/" { path.removeLast() }
        return path + "../Fixtures/"
    }()

    static let names: [String] =
        ((try? FileManager.default.contentsOfDirectory(atPath: fixtures + "frames")) ?? [])
        .filter { $0.hasSuffix(".frame") }
        .map { String($0.dropLast(".frame".count)) }
        .sorted()

    @Test func goldensAreThere() {
        #expect(Self.names.count >= 5, "no frame goldens in \(Self.fixtures)frames")
    }

    @Test(arguments: names)
    func framesMatchGoldens(_ name: String) throws {
        let recording = try #require(FileManager.default.contents(atPath: Self.fixtures + "corpus/\(name).bin"))
        let golden = try #require(FileManager.default.contents(atPath: Self.fixtures + "frames/\(name).frame"))
        let marks =
            FileManager.default.contents(atPath: Self.fixtures + "corpus/\(name).marks").map {
                String(decoding: $0, as: UTF8.self).split(separator: "\n").compactMap { Int($0) }
            } ?? []
        let actual = FrameReplay.summaries(of: [UInt8](recording), marks: marks, columns: 80, rows: 24)
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let goldenLines = String(decoding: golden, as: UTF8.self).split(
            separator: "\n", omittingEmptySubsequences: false)
        guard actualLines != goldenLines else { return }
        let common = min(actualLines.count, goldenLines.count)
        let index = (0..<common).first { actualLines[$0] != goldenLines[$0] } ?? common
        let got = index < actualLines.count ? String(actualLines[index]) : "(nothing)"
        let want = index < goldenLines.count ? String(goldenLines[index]) : "(nothing)"
        Issue.record("\(name): line \(index + 1) differs\n  got:  \(got)\n  want: \(want)")
    }
}
