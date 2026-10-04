import Foundation
import Vault

/// How long ago, in words: "just now", "4 min ago", "3 hours ago", "yesterday", "2 days ago",
/// "3 weeks ago", then the date.
public enum RelativeTime {
    public static func phrase(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        // A date in the future (the clock moved back since it was recorded) isn't "just now":
        // show it as a date rather than claim it just happened.
        if seconds < 0 { return "on " + formatted(date, now: now, calendar: calendar) }
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let days =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now))
            .day ?? 0
        if days == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 35 {
            let weeks = days / 7
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        }
        return "on " + formatted(date, now: now, calendar: calendar)
    }

    /// The day and month, with the year only when it isn't this one.
    private static func formatted(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale.current
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "dMMM" : "dMMMyyyy")
        return formatter.string(from: date)
    }
}

/// What a host's dot and line say: whether it's connected or answered its last check, how
/// quickly, what it runs, and when it was last reached. "18 ms · Ubuntu 24.04", "offline ·
/// last seen 2 days ago".
public struct HostStatus: Equatable, Sendable {
    public enum Dot: Equatable, Sendable {
        /// A connection to it is open now.
        case connected
        /// It answered its last check.
        case answering
        /// It didn't answer its last check.
        case silent
        /// Nothing is known.
        case unknown
    }

    public var dot: Dot
    /// The card's line.
    public var line: String
    /// The sidebar's meta: "18 ms", "offline", or nothing.
    public var meta: String?

    public init(facts: WRLDState.HostFacts, isConnected: Bool, now: Date, calendar: Calendar = .current) {
        let lastSeen = facts.lastConnected.map { "last seen " + RelativeTime.phrase($0, now: now, calendar: calendar) }
        if isConnected {
            dot = .connected
        } else if facts.isSilent {
            dot = .silent
        } else if facts.latency != nil {
            dot = .answering
        } else {
            dot = .unknown
        }
        var parts: [String] = []
        if dot == .silent {
            meta = "offline"
            parts = ["offline"] + [lastSeen].compactMap { $0 }
        } else {
            meta = facts.latency.map { "\($0) ms" }
            if let meta {
                parts.append(meta)
            } else if isConnected {
                parts.append("connected")
            }
            if let os = facts.os { parts.append(os) }
            if parts.isEmpty { parts.append(lastSeen ?? "never connected") }
        }
        line = parts.joined(separator: " · ")
    }
}

/// The chips on a host's card: how it signs in, how it's reached, and its tags.
public struct HostChip: Equatable, Sendable {
    public var text: String
    /// About signing in, drawn in the accent.
    public var isKey: Bool

    public init(_ text: String, isKey: Bool = false) {
        self.text = text
        self.isKey = isKey
    }
}

public enum HostChips {
    /// `savedPassword`: the Keychain holds a password for it.
    public static func chips(for host: WRLDHost, in vault: Vault, savedPassword: Bool = false) -> [HostChip] {
        var chips: [HostChip] = []
        switch host.source {
        case .wrld(let connection):
            switch connection.identity {
            case .secureEnclave: chips.append(HostChip("Secure Enclave · Touch ID", isKey: true))
            case .keyFile(let path): chips.append(HostChip(keyName(path), isKey: true))
            case .automatic: break
            }
            if let jump = connection.jumpHostID.flatMap(vault.host) { chips.append(HostChip("via " + jump.name)) }
        case .sshConfig:
            chips.append(HostChip("~/.ssh/config"))
        }
        if savedPassword { chips.append(HostChip("password in Keychain", isKey: true)) }
        if vault.hosts.contains(where: { $0.connection?.jumpHostID == host.id }) { chips.append(HostChip("jump host")) }
        chips += host.tags.map { HostChip($0) }
        return chips
    }

    /// What a key file is called on a chip: its type for ssh's own names ("ed25519" for
    /// `id_ed25519`), else the file's name.
    static func keyName(_ path: String) -> String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        if file.hasPrefix("id_"), !file.hasSuffix(".pub") {
            let type = file.dropFirst(3)
            if ["ed25519", "rsa", "ecdsa", "dsa", "ed25519_sk", "ecdsa_sk"].contains(type) {
                return type.replacingOccurrences(of: "_sk", with: " security key")
            }
        }
        return file
    }
}
