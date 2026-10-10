import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// An upload's open descriptor and size. Reads are bounded and run on transfer workers.
public final class LocalUpload: @unchecked Sendable {
    private let fd: Int32
    public let size: UInt64

    public init(path: String) throws {
        fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            close(fd)
            throw SFTPError.invalid("only regular files can be uploaded")
        }
        size = UInt64(info.st_size)
    }

    deinit { close(fd) }

    public func read(offset: UInt64, length: Int) throws -> [UInt8] {
        guard offset <= UInt64(Int64.max), (0...SFTPClient.chunkSize).contains(length) else {
            throw SFTPError.invalid("invalid local read range")
        }
        var bytes = [UInt8](repeating: 0, count: length)
        var count: Int
        repeat {
            count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset)) }
        } while count < 0 && errno == EINTR
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Array(bytes.prefix(count))
    }
}

/// Stage in the destination directory. Publishing with link() when replacement was not
/// approved is atomic: a file appearing after the existence check is never overwritten.
/// Unlike Vault's configuration writes, replacing a download replaces a symlink itself.
public final class LocalDownload: @unchecked Sendable {
    private let lock = NSLock()
    private let fd: Int32
    private let path: String
    private let temporary: String
    private var committed = false

    public init(path: String) throws {
        self.path = path
        temporary = Listing.join(Listing.parent(of: path), ".deathrace-\(UUID().uuidString).part")
        fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit {
        close(fd)
        unlink(temporary)
    }

    public static func exists(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    public func write(_ bytes: [UInt8], offset: UInt64) throws {
        try lock.withLock {
            guard !committed, offset <= UInt64(Int64.max) - UInt64(bytes.count) else {
                throw SFTPError.invalid("invalid local write range")
            }
            var done = 0
            while done < bytes.count {
                let count = bytes.withUnsafeBytes {
                    pwrite(fd, $0.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done))
                }
                if count > 0 {
                    done += count
                } else if count == 0 || errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    public func commit(overwrite: Bool) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard !committed else { throw SFTPError.invalid("download already published") }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try Task.checkCancellation()
            let result = overwrite ? rename(temporary, path) : link(temporary, path)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            unlink(temporary)
            committed = true
        }
    }
}
