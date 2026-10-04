/// Local Network privacy, as it touches ssh. Terminal.app is exempt, but Death Race is the
/// app responsible for the ssh it starts (Apple's TN3179). So the first connection to a host
/// on your network raises macOS's alert, and can fail while the alert is showing, with "No
/// route to host". `LocalNetwork` tells that failure apart from a real one.
public enum LocalNetwork {
    /// Whether `address` is on what macOS counts as the local network: private IPv4
    /// (10/8, 172.16/12, 192.168/16), link-local (169.254/16, fe80::/10), unique-local IPv6
    /// (fc00::/7), `.local` names, and single-label names, which only a local resolver
    /// answers. Loopback isn't: it needs no permission.
    public static func isLocal(_ address: String) -> Bool {
        let host = address.lowercased()
        if host.hasSuffix(".local") || host.hasSuffix(".local.") { return true }
        if let octets = ipv4(host) {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, let second): return (16...31).contains(second)
            default: return false
            }
        }
        if host.contains(":") {
            let first = host.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
            guard let value = UInt16(first, radix: 16), !first.isEmpty else { return false }
            return value & 0xFFC0 == 0xFE80 || value & 0xFE00 == 0xFC00
        }
        return !host.contains(".") && host != "localhost" && !host.isEmpty
    }

    /// Whether a connection that failed with `failure` should offer "Allow Local Network
    /// access": no route to a host on the local network.
    public static func suggestsPermission(address: String, failure: ConnectionFailure) -> Bool {
        guard case .noRoute = failure else { return false }
        return isLocal(address)
    }

    static func ipv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part),
                value <= 255
            else { return nil }
            octets.append(value)
        }
        return octets
    }
}
