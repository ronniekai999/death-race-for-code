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
    /// The file's permission bits, without the type.
    public let permissions: UInt32

    public init(path: String) throws {
        fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            close(fd)
            throw SFTPError.invalid("only regular files can be uploaded")
        }
        size = UInt64(info.st_size)
        permissions = UInt32(info.st_mode) & 0o777
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

    /// `link`, which never replaces a file that appeared since the check. A FAT or exFAT
    /// drive, or a share, has no hard links, and every new download there failed with
    /// "Operation not supported": there the name is claimed with an exclusive create first,
    /// which also never replaces anything, and the download renamed onto its own claim.
    private func publishWithoutReplacing() -> Int32 {
        if link(temporary, path) == 0 { return 0 }
        guard errno != EEXIST else { return -1 }
        let claim = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard claim >= 0 else { return -1 }
        close(claim)
        if rename(temporary, path) == 0 { return 0 }
        let failure = errno
        unlink(path)
        errno = failure
        return -1
    }

    public static func exists(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// What a new file here would get: the process's umask, read once. Reading it means
    /// setting it, so it is done once rather than per download.
    private static let umaskBits: mode_t = {
        let current = umask(0o022)
        umask(current)
        return current
    }()

    /// The remote file's permission bits, masked as a new file here would be: a script
    /// downloaded stays executable, where the staged file was 0600 and stayed it.
    public func setPermissions(_ permissions: UInt32) throws {
        try lock.withLock {
            let mode = mode_t(permissions & 0o777) & ~Self.umaskBits
            guard fchmod(fd, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
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
            let result = overwrite ? rename(temporary, path) : publishWithoutReplacing()
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            unlink(temporary)
            committed = true
        }
    }
}
