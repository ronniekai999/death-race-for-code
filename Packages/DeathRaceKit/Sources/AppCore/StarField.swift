/// MenuGlance's starfield (LegendsUI's `Starfield`): specks on the ground, a fifth of them
/// bright. Here it is laid out in fixed tiles, each with its own seed, so a window that grows
/// shows more sky and the stars it already had stay where they were.
public enum StarField {
    public struct Star: Equatable, Sendable {
        /// Points from the area's top left.
        public var x: Double
        public var y: Double
        /// A brighter, bigger speck: 2 points at 55%, where the rest are 1 point at 22%.
        public var bright: Bool

        public var diameter: Double { bright ? 2 : 1 }
        public var opacity: Double { bright ? 0.55 : 0.22 }
    }

    /// A tile is this many points square.
    public static let tileSize = 400.0
    /// Specks per 1000×600 points, as LegendsUI's `Starfield` draws them.
    public static let density = 50.0
    public static let seed: UInt64 = 999

    /// The tiles that cover `width` by `height` points, row by row.
    public static func tiles(width: Double, height: Double) -> [Tile] {
        guard width > 0, height > 0 else { return [] }
        let columns = Int((width / tileSize).rounded(.up))
        let rows = Int((height / tileSize).rounded(.up))
        return (0..<rows).flatMap { row in (0..<columns).map { Tile(column: $0, row: row) } }
    }

    public struct Tile: Hashable, Sendable {
        public var column: Int
        public var row: Int

        public init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }

        /// This tile's stars, in the area's points. The same tile always has the same stars.
        public var stars: [Star] {
            var random = SplitMix64(seed: StarField.seed ^ (UInt64(column) &* 0x9E37_79B9) ^ (UInt64(row) << 32))
            let expected = StarField.density * StarField.tileSize * StarField.tileSize / 600_000
            let count = Int(expected) + (random.unit() < expected - expected.rounded(.down) ? 1 : 0)
            let left = Double(column) * StarField.tileSize
            let top = Double(row) * StarField.tileSize
            return (0..<count).map { _ in
                let x = left + random.unit() * StarField.tileSize
                let y = top + random.unit() * StarField.tileSize
                return Star(x: x, y: y, bright: random.unit() < 0.2)
            }
        }
    }

    /// Every star in `width` by `height` points.
    public static func stars(width: Double, height: Double) -> [Star] {
        tiles(width: width, height: height).flatMap(\.stars).filter { $0.x < width && $0.y < height }
    }
}

/// A small deterministic generator (as LegendsUI's), so a starfield never reshuffles.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
