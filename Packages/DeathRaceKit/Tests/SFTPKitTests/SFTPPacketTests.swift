import Testing

@testable import SFTPKit

/// One of every packet, with awkward contents (empty and non-UTF-8 byte strings, every
/// attribute flag, a multi-entry NAME), so the round-trip and corruption tests cover the
/// whole wire format.
private let samplePackets: [SFTPPacket] = [
    .initialize(version: 3),
    .version(version: 3),
    .open(id: 1, path: "/var/www/app.tar.gz", pflags: SFTP.Open.read, attributes: .none),
    .open(
        id: 2, path: "upload.bin", pflags: SFTP.Open.write | SFTP.Open.create | SFTP.Open.truncate,
        attributes: SFTPAttributes(permissions: 0o644)),
    .close(id: 3, handle: [0x00, 0xFF, 0x10, 0x7F]),
    .read(id: 4, handle: [1, 2, 3], offset: 0, length: 32_768),
    .read(id: 5, handle: [], offset: 0xDEAD_BEEF_0000, length: 1),
    .write(id: 6, handle: [9], offset: 4_096, data: [0, 1, 2, 3, 255, 254]),
    .lstat(id: 7, path: "/etc/os-release"),
    .fstat(id: 8, handle: [0xAB]),
    .setstat(id: 9, path: "f", attributes: SFTPAttributes(times: .init(accessed: 1, modified: 2))),
    .fsetstat(id: 10, handle: [0xCD], attributes: SFTPAttributes(size: 100)),
    .opendir(id: 11, path: "/home/user"),
    .readdir(id: 12, handle: [0x01, 0x02]),
    .remove(id: 13, path: "junk"),
    .mkdir(id: 14, path: "/tmp/new", attributes: .none),
    .rmdir(id: 15, path: "/tmp/old"),
    .realpath(id: 16, path: "."),
    .stat(id: 17, path: "sym"),
    .rename(id: 18, oldPath: "a", newPath: "b"),
    .status(id: 19, code: SFTP.Status.noSuchFile, message: "no such file"),
    .status(id: 20, code: SFTP.Status.ok, message: ""),
    .handle(id: 21, handle: [0x00, 0x00, 0x00, 0x01]),
    .data(id: 22, data: [UInt8](0...63)),
    .name(
        id: 23,
        entries: [
            SFTPName(
                filename: "app.tar.gz", longname: "-rw-r--r-- 1 u u 48M app.tar.gz",
                attributes: SFTPAttributes(
                    size: 48_000_000, owner: .init(uid: 1_000, gid: 1_000), permissions: 0o100_644,
                    times: .init(accessed: 0, modified: 7))),
            SFTPName(
                filename: "builds", longname: "drwxr-xr-x 2 u u 4096 builds",
                attributes: SFTPAttributes(permissions: 0o040_755)),
        ]),
    .attrs(
        id: 24,
        attributes: SFTPAttributes(
            size: 1, owner: .init(uid: 2, gid: 3), permissions: 4, times: .init(accessed: 5, modified: 6))),
]

@Suite struct SFTPPacketTests {
    @Test func everyPacketRoundTripsThroughAFrame() throws {
        for packet in samplePackets {
            let frame = packet.encode()
            #expect(try SFTPPacket.decode(frame: frame) == packet)
            // The body is the frame without its 4-byte length prefix.
            #expect(try SFTPPacket.decode(body: Array(frame.dropFirst(4))) == packet)
        }
    }

    @Test func theFrameLengthMustMatchTheBody() {
        let frame = SFTPPacket.realpath(id: 1, path: ".").encode()
        #expect(throws: SFTPError.self) { try SFTPPacket.decode(frame: Array(frame.dropLast())) }
        #expect(throws: SFTPError.self) { try SFTPPacket.decode(frame: frame + [0]) }
    }

    @Test func everyTruncationOfAFixedPacketThrows() {
        // These packets have only required fields (no v3 STATUS message leniency, no empty
        // NAME), so any short read must throw rather than yield a shorter valid packet.
        let fixed: [SFTPPacket] = [
            .read(id: 4, handle: [1, 2, 3], offset: 10, length: 32_768),
            .write(id: 6, handle: [9], offset: 4_096, data: [0, 1, 2, 3]),
            .open(id: 2, path: "upload.bin", pflags: SFTP.Open.write, attributes: SFTPAttributes(permissions: 0o644)),
            .name(
                id: 23,
                entries: [SFTPName(filename: "a", longname: "b", attributes: SFTPAttributes(size: 1))]),
        ]
        for packet in fixed {
            let body = Array(packet.encode().dropFirst(4))
            for k in 0..<body.count {
                #expect(throws: SFTPError.self) { try SFTPPacket.decode(body: Array(body.prefix(k))) }
            }
            #expect((try? SFTPPacket.decode(body: body)) == packet)
        }
    }

    @Test func aForgedNameCountDoesNotAllocate() {
        // type NAME, id, then a count of UInt32.max with no entries behind it.
        var w = SFTPWriter()
        w.u8(SFTP.Kind.name)
        w.u32(1)
        w.u32(.max)
        #expect(throws: SFTPError.truncated) { try SFTPPacket.decode(body: w.bytes) }
    }

    @Test func aForgedStringLengthDoesNotAllocate() {
        // type REALPATH, id, then a string claiming UInt32.max bytes.
        var w = SFTPWriter()
        w.u8(SFTP.Kind.realpath)
        w.u32(1)
        w.u32(.max)
        #expect(throws: SFTPError.truncated) { try SFTPPacket.decode(body: w.bytes) }
    }

    @Test func anUnknownPacketTypeIsRejected() {
        #expect(throws: SFTPError.unknownPacket(200)) { try SFTPPacket.decode(body: [200, 0, 0, 0, 1]) }
    }

    @Test func corruptionNeverCrashes() {
        var seed: UInt64 = 0x5F74_7020_636F_6465
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }
        for packet in samplePackets {
            let frame = packet.encode()
            for _ in 0..<80 {
                var bytes = frame
                let flips = Int(next() % 5) + 1
                for _ in 0..<flips where !bytes.isEmpty {
                    let at = Int(next() % UInt64(bytes.count))
                    bytes[at] ^= UInt8(next() & 0xFF)
                }
                // Must not crash: a throw or a decoded packet are both fine.
                _ = try? SFTPPacket.decode(frame: bytes)
                _ = try? SFTPPacket.decode(body: Array(bytes.dropFirst(4)))
            }
        }
    }

    @Test func integersAreBigEndianOnTheWire() {
        // A REALPATH's id is the first u32 after the type byte; 0x01020304 must be MSB-first.
        let body = Array(SFTPPacket.realpath(id: 0x0102_0304, path: "").encode().dropFirst(4))
        #expect(Array(body[1...4]) == [0x01, 0x02, 0x03, 0x04])
    }

    @Test func attributesCarryOnlyTheirSetFields() throws {
        let cases: [SFTPAttributes] = [
            .none,
            SFTPAttributes(size: 42),
            SFTPAttributes(owner: .init(uid: 1, gid: 2)),
            SFTPAttributes(permissions: 0o755),
            SFTPAttributes(times: .init(accessed: 100, modified: 200)),
            SFTPAttributes(
                size: 1, owner: .init(uid: 2, gid: 3), permissions: 0o644, times: .init(accessed: 5, modified: 6)),
        ]
        for attributes in cases {
            let packet = SFTPPacket.attrs(id: 1, attributes: attributes)
            #expect(try SFTPPacket.decode(frame: packet.encode()) == packet)
        }
    }

    @Test func permissionBitsClassifyDirectoriesAndLinks() {
        #expect(SFTPAttributes(permissions: 0o040_755).isDirectory)
        #expect(!SFTPAttributes(permissions: 0o100_644).isDirectory)
        #expect(SFTPAttributes(permissions: 0o120_777).isSymlink)
        #expect(!SFTPAttributes(permissions: 0o100_644).isSymlink)
        #expect(!SFTPAttributes.none.isDirectory)
    }
}
