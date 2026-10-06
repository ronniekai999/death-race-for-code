#if os(macOS)
    import CPTY
    import Foundation
    import Security

    /// Whether the code at the other end of a socket is what we expect.
    ///
    /// The uid check says only that the peer is this user, which is all a machine without code
    /// signing can say — and for the askpass broker it is nearly enough, since a process of
    /// yours can already run anything you can. A session daemon is different: what it holds
    /// that a plain process of yours does not is the privacy attribution it inherited from the
    /// app. So what may speak to it is pinned to the app's own signature, not merely to your
    /// account, and this is the part of that which only a Mac can do.
    public enum PeerCode {
        /// The peer's audit token: it names one run of one program, where a pid can be reused
        /// and can be outlived by something the process exec'd in its place.
        public static func auditToken(of fd: Int32) -> [UInt32]? {
            var token = [UInt32](repeating: 0, count: 8)
            guard cpty_peer_audit_token(fd, &token) == 0 else { return nil }
            return token
        }

        /// Whether the peer on `fd` is code satisfying `requirement`.
        public static func peer(_ fd: Int32, satisfies requirement: String) -> Bool {
            guard let token = auditToken(of: fd) else { return false }
            let data = token.withUnsafeBufferPointer { Data(buffer: $0) }
            var code: SecCode?
            let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code
            else { return false }
            var pinned: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &pinned) == errSecSuccess,
                let pinned
            else { return false }
            return SecCodeCheckValidity(code, [], pinned) == errSecSuccess
        }

        /// This process's signing identifier and team, as macOS sees them. The team is nil for
        /// an ad-hoc signature, which names nobody and so can pin nothing.
        public static func ourSignature() -> (identifier: String, team: String?)? {
            var code: SecCode?
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                SecCodeCopySigningInformation(
                    staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                let dictionary = information as? [String: Any],
                let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
            else { return nil }
            return (identifier, dictionary[kSecCodeInfoTeamIdentifier as String] as? String)
        }

        /// A requirement naming `identifier` signed by whoever signed this process, or nil
        /// when there is no team to name.
        ///
        /// Built at runtime rather than written down, so a build signed with an Apple
        /// Development certificate and one signed for distribution both work without the team
        /// appearing in the source.
        public static func requirement(identifier: String) -> String? {
            guard let team = ourSignature()?.team, !team.isEmpty else { return nil }
            return "identifier \"\(identifier)\" and anchor apple generic"
                + " and certificate leaf[subject.OU] = \"\(team)\""
        }
    }
#endif
