/// Compares in time that doesn't depend on where the two differ, so what it took to answer
/// says nothing about how much of a token was guessed right.
public func sameBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in a.indices { difference |= a[index] ^ b[index] }
    return difference == 0
}

/// `count` bytes nobody can guess.
public func randomBytes(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
}

/// `bytes` as lower-case hex, for a token that has to travel as text.
public func hexText(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }.joined()
}
