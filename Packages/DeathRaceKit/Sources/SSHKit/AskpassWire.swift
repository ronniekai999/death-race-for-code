import Foundation
import IPCKit

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
    /// The askpass wire's reader: `FrameReader` at this message size, so the helper and the
    /// broker keep speaking exactly what they always have.
    public struct Reader: Sendable {
        private var frames = FrameReader(limit: AskpassWire.largestMessage)

        public init() {}

        public var isBroken: Bool { frames.isBroken }

        /// The payloads `bytes` completes.
        public mutating func append(_ bytes: [UInt8]) -> [[UInt8]] { frames.append(bytes) }
    }

    /// Compares tokens in time that doesn't depend on where they differ.
    public static func sameToken(_ a: String, _ b: String) -> Bool {
        sameBytes(Array(a.utf8), Array(b.utf8))
    }

    /// A new token: 32 random bytes, as hex.
    public static func makeToken() -> String {
        hexText(randomBytes(32))
    }
}
