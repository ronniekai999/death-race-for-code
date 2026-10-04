import Foundation

/// What `deathrace-askpass` and the app's broker say to each other over the broker's Unix
/// socket: one request, one reply, each a 4-byte big-endian length and a JSON object.
///
/// The request carries the token the app gave the ssh it started, ssh's prompt and its
/// `SSH_ASKPASS_PROMPT`. The reply is the answer, or a cancel, or "done" for a notice that
/// needs no answer. Secrets travel only in replies, only over this socket.
public enum AskpassWire {
    public static let version = 1
    /// Prompts and answers are short; anything longer is refused rather than buffered.
    public static let largestMessage = 64 * 1024

    public struct Request: Codable, Equatable, Sendable {
        public var version: Int
        public var token: String
        public var prompt: String
        public var hint: String?

        public init(token: String, prompt: String, hint: String?) {
            version = AskpassWire.version
            self.token = token
            self.prompt = prompt
            self.hint = hint
        }
    }

    public enum Reply: Equatable, Sendable {
        case answer(String)
        case cancel
        /// For a notice: nothing to print, and no failure.
        case done
    }

    private struct ReplyBody: Codable {
        var version: Int
        var answer: String?
        var cancel: Bool?
        var done: Bool?
    }

    public static func encode(_ request: Request) -> [UInt8] {
        frame((try? JSONEncoder().encode(request)).map(Array.init) ?? [])
    }

    public static func encode(_ reply: Reply) -> [UInt8] {
        var body = ReplyBody(version: version)
        switch reply {
        case .answer(let text): body.answer = text
        case .cancel: body.cancel = true
        case .done: body.done = true
        }
        return frame((try? JSONEncoder().encode(body)).map(Array.init) ?? [])
    }

    public static func decodeRequest(_ payload: [UInt8]) -> Request? {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(payload)), request.version == version
        else { return nil }
        return request
    }

    public static func decodeReply(_ payload: [UInt8]) -> Reply? {
        guard let body = try? JSONDecoder().decode(ReplyBody.self, from: Data(payload)), body.version == version
        else { return nil }
        if let answer = body.answer { return .answer(answer) }
        if body.cancel == true { return .cancel }
        if body.done == true { return .done }
        return nil
    }

    /// A payload with its length in front.
    public static func frame(_ payload: [UInt8]) -> [UInt8] {
        let count = UInt32(payload.count)
        return [UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)] + payload
    }

    /// Collects bytes as they arrive and hands back whole payloads.
    public struct Reader: Sendable {
        private var buffer: [UInt8] = []
        public private(set) var isBroken = false

        public init() {}

        /// The payloads `bytes` completes. A length past `largestMessage` breaks the reader
        /// for good: the connection should be dropped.
        public mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
            guard !isBroken else { return [] }
            buffer += bytes
            var payloads: [[UInt8]] = []
            while buffer.count >= 4 {
                let length =
                    Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
                guard length <= largestMessage else {
                    isBroken = true
                    buffer = []
                    return payloads
                }
                guard buffer.count >= 4 + length else { break }
                payloads.append(Array(buffer[4..<(4 + length)]))
                buffer.removeFirst(4 + length)
            }
            return payloads
        }
    }

    /// Compares tokens in time that doesn't depend on where they differ.
    public static func sameToken(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    /// A new token: 32 random bytes, as hex.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}
