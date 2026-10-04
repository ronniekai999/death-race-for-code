import Foundation
import Testing

@testable import Vault

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A folder of its own for each test, removed afterwards.
private final class Scratch {
    let path: String

    init() {
        path = NSTemporaryDirectory() + "wrld-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    func text(_ file: String) -> String? {
        FileManager.default.contents(atPath: file).map { String(decoding: $0, as: UTF8.self) }
    }

    func mode(_ file: String) -> mode_t {
        var info = stat()
        stat(file, &info)
        return info.st_mode & 0o777
    }
}

@Suite("The vault's store")
struct VaultStoreTests {
    @Test func noFileIsAnEmptyVault() throws {
        let scratch = Scratch()
        #expect(try VaultStore(path: scratch.path + "/wrld.json").load() == Vault())
    }

    @Test func savedIsLoaded() throws {
        let scratch = Scratch()
        let store = VaultStore(path: scratch.path + "/deathrace/wrld.json")
        try store.save(sampleVault())
        #expect(try store.load() == sampleVault())
    }

    @Test func theFileAndItsFolderAreYoursAlone() throws {
        let scratch = Scratch()
        let folder = scratch.path + "/made/here"
        try VaultStore(path: folder + "/wrld.json").save(sampleVault())
        #expect(scratch.mode(folder + "/wrld.json") == 0o600)
        #expect(scratch.mode(folder) == 0o700)
        // No temporary files are left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["wrld.json"])
    }

    @Test func aLinkIntoADotfilesRepoStaysALink() throws {
        let scratch = Scratch()
        let real = scratch.path + "/dotfiles/wrld.json"
        try FileManager.default.createDirectory(atPath: scratch.path + "/dotfiles", withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: real))
        let link = scratch.path + "/wrld.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        try VaultStore(path: link).save(sampleVault())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == real)
        #expect(scratch.text(real)?.contains("prod-api") == true)
        #expect(try VaultStore(path: link).load() == sampleVault())
    }

    @Test func aLinkToAFileNotMadeYetIsFollowed() throws {
        let scratch = Scratch()
        let real = scratch.path + "/dotfiles/wrld.json"
        let link = scratch.path + "/wrld.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "dotfiles/wrld.json")
        try VaultStore(path: link).save(Vault())
        #expect(scratch.text(real) != nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "dotfiles/wrld.json")
    }

    @Test func aFileThatIsntAVaultIsLeftAlone() throws {
        let scratch = Scratch()
        let path = scratch.path + "/wrld.json"
        let original = "{ \"hosts\": [ { \"name\": \"no id\" } ] }"
        try Data(original.utf8).write(to: URL(fileURLWithPath: path))
        let store = VaultStore(path: path)
        #expect {
            try store.save(Vault())
        } throws: { error in
            guard case .undecodable(_, let reason) = error as? VaultStore.Failure else { return false }
            return reason.contains("id")
        }
        #expect(scratch.text(path) == original)
        #expect(throws: VaultStore.Failure.self) { try store.load() }
    }

    @Test func aFileFromANewerDeathRaceIsReadButNeverWrittenOver() throws {
        let scratch = Scratch()
        let path = scratch.path + "/wrld.json"
        let original = #"{"version": 2, "hosts": [{"id": "h1", "name": "pi", "address": "pi.local"}], "tags": {}}"#
        try Data(original.utf8).write(to: URL(fileURLWithPath: path))
        let store = VaultStore(path: path)
        let vault = try store.load()
        #expect(vault.version == 2)
        #expect(vault.hosts.count == 1)
        #expect(throws: VaultStore.Failure.newer(path: path, version: 2)) { try store.save(vault) }
        #expect(scratch.text(path) == original)
    }

    @Test func anEmptyFileIsAnEmptyVault() throws {
        let scratch = Scratch()
        let path = scratch.path + "/wrld.json"
        try Data(" \n".utf8).write(to: URL(fileURLWithPath: path))
        let store = VaultStore(path: path)
        #expect(try store.load() == Vault())
        try store.save(sampleVault())
        #expect(try store.load() == sampleVault())
    }

    @Test(.enabled(if: getuid() != 0, "root reads every file")) func aFileItCantReadIsLeftAlone() throws {
        let scratch = Scratch()
        let path = scratch.path + "/wrld.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0)
        defer { chmod(path, 0o600) }
        #expect(throws: VaultStore.Failure.unreadable(path: path)) { try VaultStore(path: path).save(Vault()) }
    }

    @Test func savingWritesTheCurrentFormat() throws {
        let scratch = Scratch()
        let store = VaultStore(path: scratch.path + "/wrld.json")
        var vault = sampleVault()
        vault.version = 0
        try store.save(vault)
        #expect(try store.load().version == Vault.formatVersion)
    }

    @Test func theFileLivesNextToTheSettings() {
        #expect(VaultLocation.path(environment: [:], home: "/Users/r") == "/Users/r/.config/deathrace/wrld.json")
        #expect(VaultLocation.path(environment: [:], home: "/Users/r/") == "/Users/r/.config/deathrace/wrld.json")
        #expect(
            VaultLocation.path(environment: ["XDG_CONFIG_HOME": "/x/conf/"], home: "/Users/r")
                == "/x/conf/deathrace/wrld.json")
        #expect(
            VaultLocation.path(environment: ["XDG_CONFIG_HOME": "relative"], home: "/Users/r")
                == "/Users/r/.config/deathrace/wrld.json")
    }
}
