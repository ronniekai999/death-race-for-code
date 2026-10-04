/// An OSC 8 hyperlink. Cells that share one are one link, across rows: the program names
/// the link with `id=`, or each sequence that opens a link makes a new one.
public struct Hyperlink: Hashable, Sendable {
    /// The program's `id`, or one the terminal made up (":" and a number, which no
    /// program's can be, as a colon separates the sequence's parameters).
    public var id: String
    public var uri: String

    public init(id: String, uri: String) {
        self.id = id
        self.uri = uri
    }

    /// Longer URIs and ids are dropped, link and all, rather than cut into another address.
    public static let maxURILength = 2048
    public static let maxIDLength = 256

    /// What a link may hold: a URI and an id within their limits, with no control
    /// characters, which have no business in an address and can mislead whatever shows it.
    public static func isAcceptable(id: some Collection<UInt8>, uri: some Collection<UInt8>) -> Bool {
        !id.isEmpty && id.count <= maxIDLength && !uri.isEmpty && uri.count <= maxURILength
            && id.allSatisfy(isPrintable) && uri.allSatisfy(isPrintable)
    }

    public static func isAcceptable(_ link: Hyperlink) -> Bool {
        isAcceptable(id: link.id.utf8, uri: link.uri.utf8)
    }

    private static func isPrintable(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte != 0x7F
    }
}
