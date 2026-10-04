import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Writing a file the way WRLD's files need: all at once (a temporary file renamed into
/// place, so a crash never leaves half a file), readable by you alone (0600), and through a
/// symbolic link rather than over it, so a file kept in a dotfiles repo stays a link.
public enum AtomicFile {
    public enum Failure: Error, Equatable, Sendable {
        case cannotRead(path: String, errno: Int32)
        case cannotWrite(path: String, errno: Int32)
    }

    /// The file's bytes; nil when there is no file. Throws when it exists but can't be read.
    public static func read(_ path: String) throws(Failure) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw .cannotRead(path: path, errno: errno)
        }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { systemRead(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return bytes
            } else if errno != EINTR {
                throw .cannotRead(path: path, errno: errno)
            }
        }
    }

    /// Replaces the file at `path`, or the file its symbolic link points to, with `bytes`,
    /// mode 0600. Missing folders are made, mode 0700.
    public static func write(_ bytes: [UInt8], to path: String) throws(Failure) {
        let target = resolvingLinks(path)
        let folder = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        if !folder.isEmpty { try makeFolders(folder) }
        let temporary = (folder.isEmpty ? "." : folder) + "/.\(name).\(UInt32.random(in: .min ... .max))"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .cannotWrite(path: target, errno: errno) }
        var failure: Int32 = 0
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { systemWrite(fd, $0.baseAddress! + offset, $0.count - offset) }
            if count > 0 {
                offset += count
            } else if errno != EINTR {
                failure = errno
                break
            }
        }
        if failure == 0, fsync(fd) != 0 { failure = errno }
        close(fd)
        if failure == 0, rename(temporary, target) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary)
            throw .cannotWrite(path: target, errno: failure)
        }
    }

    /// Where writing `path` should go: the end of its chain of symbolic links (even one that
    /// points to a file not made yet), else `path` itself.
    static func resolvingLinks(_ path: String) -> String {
        var current = path
        for _ in 0..<32 {
            var info = stat()
            guard lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return current }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(current, &buffer, buffer.count - 1)
            guard length > 0 else { return current }
            let destination = String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            current =
                destination.hasPrefix("/")
                ? destination
                : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        }
        return current
    }

    private static func makeFolders(_ folder: String) throws(Failure) {
        var info = stat()
        if stat(folder, &info) == 0 { return }
        let parent = (folder as NSString).deletingLastPathComponent
        if !parent.isEmpty, parent != folder { try makeFolders(parent) }
        if mkdir(folder, 0o700) != 0, errno != EEXIST { throw .cannotWrite(path: folder, errno: errno) }
    }
}

private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, buffer, count)
}
