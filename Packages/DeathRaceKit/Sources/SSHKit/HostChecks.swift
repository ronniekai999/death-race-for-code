import Foundation
import PTYKit
import Vault

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The two things WRLD finds out about hosts by itself, and the rules for when it may:
/// how quickly a host answers, and what it runs. Both are cheap, and both are kept rare on
/// purpose: a check of a host on your network raises macOS's Local Network question, and
/// each one leaves a line in the server's log, which tools like fail2ban count.
public enum HostChecks {
    /// How long between checks of one host while the sidebar or WRLD window shows it.
    public static let latencyInterval: TimeInterval = 300
    /// How long a check waits for an answer.
    public static let latencyTimeout = 2_000
    /// How long between reads of a host's `/etc/os-release`.
    public static let osInterval: TimeInterval = 7 * 86_400

    /// What a latency check found.
    public enum Answer: Equatable, Sendable {
        /// It connected, after this many milliseconds.
        case answered(Int)
        /// Nothing connected in time.
        case silent
        /// The address is on the local network and the host has never been connected to:
        /// not checked, so macOS doesn't ask about the Local Network before you did anything.
        case skipped
    }

    /// Whether `host` may be checked now:
    /// - `wrld-check-hosts` is on, and the sidebar or the WRLD window shows it;
    /// - it's a Legend that WRLD describes itself (one from `~/.ssh/config` may be reached
    ///   through a ProxyCommand only `ssh -G` would tell of), reached directly, not through
    ///   a jump host;
    /// - on the local network, only once you've connected to it yourself;
    /// - five minutes since its last check, or the network changed since.
    public static func latencyIsDue(
        _ host: WRLDHost, facts: WRLDState.HostFacts, enabled: Bool, visible: Bool, networkChangedAt: Date?,
        now: Date
    ) -> Bool {
        guard enabled, visible, host.isLegend, let connection = host.connection, connection.jumpHostID == nil else {
            return false
        }
        if LocalNetwork.isLocal(connection.address) && facts.lastConnected == nil { return false }
        guard let checked = facts.latencyCheckedAt else { return true }
        if let networkChangedAt, networkChangedAt > checked { return true }
        return now.timeIntervalSince(checked) >= latencyInterval
    }

    /// Whether to read what `host` runs: only after a session on it, and at most weekly.
    public static func osIsDue(facts: WRLDState.HostFacts, enabled: Bool, now: Date) -> Bool {
        guard enabled, facts.lastConnected != nil else { return false }
        guard let read = facts.osReadAt else { return true }
        return now.timeIntervalSince(read) >= osInterval
    }

    /// Times a TCP connection to `host`:`port`, on a thread of its own (the name lookup
    /// blocks). Nothing is sent: the connection closes as soon as it's made. Addresses on
    /// the local network are skipped unless `allowLocal`.
    public static func latency(
        host: String, port: Int, allowLocal: Bool, timeoutMilliseconds: Int = latencyTimeout
    ) async -> Answer {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(
                    returning: connectTime(
                        host: host, port: port, allowLocal: allowLocal, timeoutMilliseconds: timeoutMilliseconds))
            }
            thread.name = "Death Race: latency"
            thread.start()
        }
    }

    static func connectTime(host: String, port: Int, allowLocal: Bool, timeoutMilliseconds: Int) -> Answer {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
            hints.ai_socktype = SOCK_STREAM
        #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        let deadline = UnixSocket.monotonicMilliseconds() + timeoutMilliseconds
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return .silent }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        var skipped = false
        while let current = node {
            node = current.pointee.ai_next
            guard let address = current.pointee.ai_addr else { continue }
            if !allowLocal, LocalNetwork.isLocal(numeric(address) ?? host) {
                skipped = true
                continue
            }
            let remaining = deadline - UnixSocket.monotonicMilliseconds()
            guard remaining > 0 else { break }
            if let milliseconds = connect(
                family: current.pointee.ai_family, address: address, length: current.pointee.ai_addrlen,
                timeoutMilliseconds: remaining)
            {
                return .answered(milliseconds)
            }
        }
        return skipped ? .skipped : .silent
    }

    /// One non-blocking connect, waited for up to `timeoutMilliseconds`; its time, or nil.
    private static func connect(
        family: Int32, address: UnsafePointer<sockaddr>, length: socklen_t, timeoutMilliseconds: Int
    ) -> Int? {
        #if canImport(Darwin)
            let fd = socket(family, SOCK_STREAM, 0)
        #else
            let fd = socket(family, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let start = UnixSocket.monotonicMilliseconds()
        #if canImport(Darwin)
            let result = Darwin.connect(fd, address, length)
        #else
            let result = Glibc.connect(fd, address, length)
        #endif
        if result != 0 {
            guard errno == EINPROGRESS else { return nil }
            var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&wait, 1, Int32(timeoutMilliseconds)) == 1 else { return nil }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else { return nil }
        }
        return max(UnixSocket.monotonicMilliseconds() - start, 1)
    }

    /// An address as text ("192.168.1.5", "fe80::1"), for the local network check.
    private static func numeric(_ address: UnsafePointer<sockaddr>) -> String? {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                var raw = inet.pointee.sin_addr
                return inet_ntop(AF_INET, &raw, &text, socklen_t(text.count)).map { _ in string(text) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet in
                var raw = inet.pointee.sin6_addr
                return inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count)).map { _ in string(text) }
            }
        default:
            return nil
        }
    }

    /// A C string in `characters`, up to its NUL.
    private static func string(_ characters: [CChar]) -> String {
        String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// What `alias` runs, from its `/etc/os-release`, read through its master: no new
    /// login. Nil when it couldn't be read.
    public static func readOS(
        alias: String, config: String, runner: any ProcessRunner, environment: [String: String]
    ) async -> String? {
        let command = SSHCommand.remote(alias: alias, config: config, command: "cat /etc/os-release")
        guard
            let result = try? await runner.run(Command(command, environment: environment, timeoutMilliseconds: 5_000)),
            result.succeeded
        else { return nil }
        return OSRelease(parsing: result.outputText).display
    }
}
