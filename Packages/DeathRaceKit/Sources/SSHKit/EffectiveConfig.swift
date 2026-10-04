/// What ssh says it will use for a host (`ssh -G <alias>`), after every `Include`, `Match`
/// and first-value-wins rule: the inspector's "What ssh will use", and the facts the
/// broker needs to recognize a prompt ("ubuntu@10.0.4.21's password:").
///
/// `ssh -G` prints one `keyword value` per line, the keyword in lowercase and the value as
/// is, spaces and all; keywords that add up (`identityfile`, `localforward`) repeat.
public struct EffectiveConfig: Equatable, Sendable {
    public private(set) var values: [String: [String]] = [:]

    public init(parsing output: String) {
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let text = line.hasSuffix("\r") ? line.dropLast() : line[...]
            guard let space = text.firstIndex(of: " ") else { continue }
            let keyword = text[..<space].lowercased()
            let value = String(text[text.index(after: space)...])
            guard !keyword.isEmpty else { continue }
            values[keyword, default: []].append(value)
        }
    }

    public subscript(_ keyword: String) -> String? { values[keyword.lowercased()]?.first }

    public func all(_ keyword: String) -> [String] { values[keyword.lowercased()] ?? [] }

    public var hostName: String? { self["hostname"] }
    public var user: String? { self["user"] }
    public var port: Int? { self["port"].flatMap { Int($0) } }
    public var proxyJump: String? { self["proxyjump"].flatMap { $0 == "none" ? nil : $0 } }
    public var hostKeyAlias: String? { self["hostkeyalias"].flatMap { $0 == "none" ? nil : $0 } }
    public var identityFiles: [String] { all("identityfile") }
    public var controlPath: String? { self["controlpath"].flatMap { $0 == "none" ? nil : $0 } }
    public var controlMaster: String? { self["controlmaster"] }
    public var controlPersist: String? { self["controlpersist"] }

    /// The host name ssh writes in its own prompts: `HostKeyAlias` when there is one.
    public var promptHost: String? { hostKeyAlias ?? hostName }
}
