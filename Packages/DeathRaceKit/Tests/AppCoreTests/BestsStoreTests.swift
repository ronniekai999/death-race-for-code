import Foundation
import Testing

@testable import AppCore

/// `bests.json`: a file of command lines, so its mode, its cap and what it refuses to hold all
/// matter as much as whether it round-trips.
@Suite("Bests on disk") struct BestsStoreTests {

    private func folder() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("deathrace-bests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func store() throws -> BestsStore {
        BestsStore(path: try folder() + "/bests.json")
    }

    // MARK: - There and back

    @Test func nothingOnDiskIsNoRecordsRatherThanAFailure() throws {
        let store = try store()
        #expect(try store.load().count == 0)
        #expect(!FileManager.default.fileExists(atPath: store.path), "loading did not create it")
    }

    @Test func recordsSurviveARestart() throws {
        let store = try store()
        var bests = CommandBests()
        bests.record(command: "swift build", milliseconds: 12_400)
        bests.record(command: "make test", milliseconds: 48_000)
        try store.save(bests)

        let back = try store.load()
        #expect(back.best(for: "swift build") == 12_400)
        #expect(back.best(for: "make test") == 48_000)
        #expect(back.count == 2)
    }

    /// The order is the one the cap drops in, so it has to survive the file — otherwise a
    /// restart would forget the command you use most instead of the one you use least.
    @Test func theOrderTheCapDropsInSurvivesTheFile() throws {
        let store = try store()
        var bests = CommandBests(limit: 3)
        for index in 0..<3 { bests.record(command: "c\(index)", milliseconds: 100) }
        bests.record(command: "c0", milliseconds: 90)  // c0 is now the most recently run
        try store.save(bests)

        var back = try store.load(limit: 3)
        back.record(command: "c3", milliseconds: 100)
        #expect(back.best(for: "c0") == 90, "used most recently, so kept")
        #expect(back.best(for: "c1") == nil, "the one not run in longest went")
    }

    // MARK: - What it will not hold

    /// A leading space is how you tell a shell to forget a command. It is not a record either.
    @Test func aCommandTypedWithALeadingSpaceIsNeverWritten() throws {
        let store = try store()
        var bests = CommandBests()
        bests.record(command: " curl -H 'Authorization: Bearer hunter2' example.com", milliseconds: 900)
        bests.record(command: "ls", milliseconds: 5)
        #expect(bests.count == 1, "it never made it into memory either")
        try store.save(bests)

        let text = try #require(String(data: Data(contentsOf: URL(fileURLWithPath: store.path)), encoding: .utf8))
        #expect(!text.contains("hunter2"), "the file holds it: \(text)")
        #expect(text.contains("ls"))
    }

    /// A file hand-edited to hold one is read back obeying the rule, not trusted.
    @Test func aPrivateCommandPlantedInTheFileIsNotLoaded() throws {
        let store = try store()
        let planted = BestsStore.Contents(
            version: BestsStore.formatVersion,
            commands: [
                .init(command: " secret thing", milliseconds: 10),
                .init(command: "make", milliseconds: 20),
            ])
        try Data(BestsStore.encode(planted)).write(to: URL(fileURLWithPath: store.path))

        let back = try store.load()
        #expect(back.best(for: " secret thing") == nil)
        #expect(back.best(for: "make") == 20)
    }

    /// More commands than the cap allows, planted in the file, come back capped.
    @Test func aFileLongerThanTheCapIsLoadedCapped() throws {
        let store = try store()
        let planted = BestsStore.Contents(
            version: BestsStore.formatVersion,
            commands: (0..<50).map { .init(command: "c\($0)", milliseconds: 1) })
        try Data(BestsStore.encode(planted)).write(to: URL(fileURLWithPath: store.path))
        #expect(try store.load(limit: 5).count == 5)
    }

    // MARK: - Never writing over what it cannot understand

    @Test func aFileFromANewerBuildIsLeftAlone() throws {
        let store = try store()
        let newer = BestsStore.Contents(
            version: BestsStore.formatVersion + 1, commands: [.init(command: "keep me", milliseconds: 1)])
        let bytes = BestsStore.encode(newer)
        try Data(bytes).write(to: URL(fileURLWithPath: store.path))

        var bests = CommandBests()
        bests.record(command: "mine", milliseconds: 2)
        #expect(throws: BestsStore.Failure.newer(path: store.path, version: BestsStore.formatVersion + 1)) {
            try store.save(bests)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.path)) == Data(bytes), "it was written over")
    }

    @Test func aFileThatIsNotABestsFileIsLeftAlone() throws {
        let store = try store()
        let nonsense = Data("not json at all".utf8)
        try nonsense.write(to: URL(fileURLWithPath: store.path))
        #expect(throws: BestsStore.Failure.self) { try store.save(CommandBests()) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.path)) == nonsense)
    }

    // MARK: - The mode, which is the whole reason this is a considered decision

    @Test func theFileIsReadableByYouAlone() throws {
        let store = try store()
        var bests = CommandBests()
        bests.record(command: "ls", milliseconds: 5)
        try store.save(bests)
        let mode = try #require(
            try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber)
        #expect(mode.int16Value & 0o777 == 0o600, "mode was \(String(mode.int16Value & 0o777, radix: 8))")
    }
}
