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

    /// The server chooses every byte of a filename, and Maze joins it with a local folder and
    /// writes there. A name holding a separator would put a download wherever the host liked:
    /// from the default Downloads folder, `Library/LaunchAgents/x.plist` is a launch agent,
    /// and `../.zshrc` is code that runs in the next tab. None of these may become a row.
    @Test func aNameFromAServerIsOnlyEverAName() {
        for bad in [
            "", ".", "..", "/", "a/b", "Library/LaunchAgents/x.plist", "../../.ssh/authorized_keys",
            "/etc/passwd", ".zshrc\u{0}.txt", "bell\u{7}", "line\nbreak", "esc\u{1B}[2J",
            String(repeating: "x", count: 256),
        ] {
            #expect(!Listing.isUsableName(bad), "\(bad.debugDescription) must not be usable as a name")
        }
        for good in ["notes.md", "app-2.4.1.tar.gz", ".zshrc", "..hidden", "a…b", "日本語.txt", "with space"] {
            #expect(Listing.isUsableName(good), "\(good.debugDescription) is an ordinary name")
        }
        #expect(Listing.isUsableName(String(repeating: "x", count: 255)))

        // And the listing drops them, so no such row can ever be picked and downloaded.
        let names = [
            "ok.txt", "", ".", "..", "Library/LaunchAgents/evil.plist", "../../.ssh/config", "ok.txt",
        ].map { SFTPName(filename: $0, longname: "", attributes: SFTPAttributes(size: 1)) }
        // "ok.txt" twice: a duplicate id would be a SwiftUI programmer error.
        #expect(Listing.remote(names).map(\.name) == ["ok.txt"])
    }

    @Test func nameTakesTheLastComponent() {
        // What a dropped file is called, from the path the drop carried.
        #expect(Listing.name(of: "/var/www/app.tar.gz") == "app.tar.gz")
        #expect(Listing.name(of: "/var/www/releases/") == "releases")
        #expect(Listing.name(of: "/etc") == "etc")
        #expect(Listing.name(of: "notes.md") == "notes.md")
        #expect(Listing.name(of: "/") == "/")
        // A path and its name agree with the join that would rebuild it.
        #expect(Listing.join(Listing.parent(of: "/a/b/c"), Listing.name(of: "/a/b/c")) == "/a/b/c")
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
