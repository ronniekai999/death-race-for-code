import Foundation
import Testing

@testable import SFTPKit

/// A throwaway directory that cleans itself up, for exercising `LocalFileSystem.local`.
private final class Scratch {
    let path: String
    init() {
        path = NSTemporaryDirectory() + "sftp-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

@Suite struct SFTPListingTests {
    @Test func remoteListingDropsDotEntriesAndSortsDirectoriesFirst() {
        let names = [
            SFTPName(filename: ".", longname: ".", attributes: SFTPAttributes(permissions: 0o040_755)),
            SFTPName(filename: "..", longname: "..", attributes: SFTPAttributes(permissions: 0o040_755)),
            SFTPName(filename: "Zebra.txt", longname: "", attributes: SFTPAttributes(size: 10, permissions: 0o100_644)),
            SFTPName(filename: "apple", longname: "", attributes: SFTPAttributes(permissions: 0o040_755)),
            SFTPName(filename: "beta.log", longname: "", attributes: SFTPAttributes(size: 3, permissions: 0o100_644)),
            SFTPName(filename: "Config", longname: "", attributes: SFTPAttributes(permissions: 0o040_755)),
            SFTPName(filename: "link", longname: "", attributes: SFTPAttributes(permissions: 0o120_777)),
        ]
        let rows = Listing.remote(names)
        // No "." or ".."; directories (apple, Config) first in case-insensitive order, then the
        // rest (beta.log, link, Zebra.txt).
        #expect(rows.map(\.name) == ["apple", "Config", "beta.log", "link", "Zebra.txt"])
        #expect(rows.first { $0.name == "Zebra.txt" }?.size == 10)
        #expect(rows.first { $0.name == "apple" }?.kind == .directory)
        #expect(rows.first { $0.name == "link" }?.kind == .symlink)
    }

    @Test func parentWalksUpAndJoinBuildsPaths() {
        #expect(Listing.parent(of: "/home/user/code") == "/home/user")
        #expect(Listing.parent(of: "/home/user/") == "/home")
        #expect(Listing.parent(of: "/home") == "/")
        #expect(Listing.parent(of: "/") == "/")
        #expect(Listing.join("/", "etc") == "/etc")
        #expect(Listing.join("/var/www", "app") == "/var/www/app")
        #expect(Listing.join("/var/www/", "app") == "/var/www/app")
    }

    @Test func localFileSystemListsWritesAndReads() throws {
        let scratch = Scratch()
        let fs = LocalFileSystem.local

        #expect(fs.writeFile([1, 2, 3, 4], Listing.join(scratch.path, "a.bin")))
        #expect(fs.createDirectory(Listing.join(scratch.path, "sub")))

        let rows = fs.entries(scratch.path)
        #expect(Set(rows.map(\.name)) == ["a.bin", "sub"])
        #expect(rows.map(\.name) == ["sub", "a.bin"])  // directory first
        let aFile = try #require(rows.first { $0.name == "a.bin" })
        #expect(aFile.kind == .file)
        #expect(aFile.size == 4)
        #expect(try #require(rows.first { $0.name == "sub" }).kind == .directory)

        #expect(fs.readFile(Listing.join(scratch.path, "a.bin")) == [1, 2, 3, 4])
        #expect(fs.readFile(Listing.join(scratch.path, "missing")) == nil)
        #expect(fs.entries(Listing.join(scratch.path, "does-not-exist")).isEmpty)
    }
}
