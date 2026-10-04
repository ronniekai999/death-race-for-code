import Foundation
import PTYKit
import Vault

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Come & Go's tunnels, as requests to a host's master over its control socket: no new
/// login, and no terminal. OpenSSH can't list what a master forwards, so the app keeps the
/// record of what it opened; this only opens and closes.
public struct TunnelController: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// Something on this Mac already listens on the port.
        case portInUse(Int)
        /// The master or the server said no: the port is taken on the server, or forwarding
        /// isn't allowed there. ssh's own words.
        case refused(String)
        /// No master answers on the control socket.
        case noConnection
        case other(String)

        public var sentence: String {
            switch self {
            case .portInUse(let port): "Port \(port) is in use on this Mac."
            case .refused: "The server refused the tunnel."
            case .noConnection: "The connection isn't open."
            case .other(let line): line
            }
        }
    }

    let runner: any ProcessRunner
    let environment: [String: String]

    public init(runner: any ProcessRunner, environment: [String: String]) {
        self.runner = runner
        self.environment = environment
    }

    /// Opens `spec` on the master at `socket`. A local or dynamic forward checks its port
    /// first, so "in use" says so instead of ssh's "forwarding request failed".
    public func open(_ spec: TunnelSpec, socket: String) async throws(Failure) {
        if spec.kind != .remote, !Self.isFree(port: spec.listenPort, address: spec.bindAddress) {
            throw .portInUse(spec.listenPort)
        }
        try await send(.forward(spec), socket: socket)
    }

    /// Closes `spec`: new connections are refused, ones already open run on.
    public func close(_ spec: TunnelSpec, socket: String) async throws(Failure) {
        try await send(.cancel(spec), socket: socket)
    }

    private func send(_ control: SSHCommand.Control, socket: String) async throws(Failure) {
        let result: ChildResult
        do {
            result = try await runner.run(
                Command(SSHCommand.control(control, socket: socket), environment: environment))
        } catch {
            throw .other("ssh couldn't be started.")
        }
        guard !result.succeeded else { return }
        throw Self.failure(from: result.errorText)
    }

    /// What `ssh -O` said when it failed.
    static func failure(from errors: String) -> Failure {
        let lines = errors.split(whereSeparator: \.isNewline).map { String($0).trimmingWhitespace }.filter {
            !$0.isEmpty
        }
        if lines.contains(where: { $0.hasPrefix("Control socket connect") }) { return .noConnection }
        if let line = lines.last(where: { $0.contains("request failed") }) { return .refused(line) }
        return .other(lines.last ?? "ssh couldn't change the tunnel.")
    }

    /// Whether this Mac can listen on `port` at `address` (loopback when nil, as ssh binds a
    /// forward without one). Names other than localhost aren't checked: ssh will say.
    static func isFree(port: Int, address: String?) -> Bool {
        let host = address.map { $0 == "localhost" ? "127.0.0.1" : $0 } ?? "127.0.0.1"
        let wildcard = host == "*" || host.isEmpty
        let v6 = host.contains(":")
        #if canImport(Darwin)
            let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        #else
            let fd = socket(v6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return true }
        defer { closeDescriptor(fd) }
        // ssh sets this too, so a port in TIME_WAIT counts as free.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if v6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { return true }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 || errno != EADDRINUSE
                }
            }
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        if wildcard {
            address.sin_addr.s_addr = INADDR_ANY
        } else {
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return true }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 || errno != EADDRINUSE
            }
        }
    }
}

/// close(2), which `TunnelController.close` hides inside the type.
private func closeDescriptor(_ fd: Int32) {
    close(fd)
}
