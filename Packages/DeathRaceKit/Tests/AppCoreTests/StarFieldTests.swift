import Testing

@testable import AppCore

@Suite struct StarFieldTests {
    @Test func aTileAlwaysHasTheSameStars() {
        let tile = StarField.Tile(column: 2, row: 1)
        #expect(tile.stars == tile.stars)
        #expect(!tile.stars.isEmpty)
        #expect(tile.stars != StarField.Tile(column: 1, row: 2).stars)
        for star in tile.stars {
            #expect((800..<1200).contains(star.x) && (400..<800).contains(star.y))
        }
    }

    /// Growing the window shows more sky; the stars it had stay put.
    @Test func aBiggerAreaKeepsTheStarsItHad() {
        let small = StarField.stars(width: 700, height: 500)
        let big = StarField.stars(width: 1400, height: 900)
        let kept = big.filter { $0.x < 700 && $0.y < 500 }
        #expect(kept == small)
        #expect(small.allSatisfy { $0.x < 700 && $0.y < 500 })
    }

    @Test func densityAndBrightnessFollowLegendsUI() {
        let stars = StarField.stars(width: 4000, height: 4000)
        let expected = StarField.density * 4000 * 4000 / 600_000
        #expect(abs(Double(stars.count) - expected) < expected * 0.1, "\(stars.count) stars")
        let bright = Double(stars.filter(\.bright).count) / Double(stars.count)
        #expect(abs(bright - 0.2) < 0.05, "\(bright) bright")
        #expect(StarField.stars(width: 0, height: 100).isEmpty)
    }
}
