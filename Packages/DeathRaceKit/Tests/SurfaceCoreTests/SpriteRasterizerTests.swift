import Testing

@testable import SurfaceCore

@Suite struct SpriteRasterizerTests {
    /// Cell sizes from 1x and 2x displays and odd and even dimensions.
    static let sizes: [(Int, Int)] = [(8, 16), (9, 18), (10, 21), (16, 32), (17, 35), (24, 48)]

    private struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init(_ scalar: UInt32, _ width: Int, _ height: Int) {
            self.width = width
            self.height = height
            pixels = SpriteRasterizer.rasterize(scalar, width: width, height: height) ?? []
        }

        func column(_ x: Int) -> [UInt8] { (0..<height).map { pixels[$0 * width + x] } }
        func row(_ y: Int) -> [UInt8] { Array(pixels[(y * width)..<((y + 1) * width)]) }
        var left: [UInt8] { column(0) }
        var right: [UInt8] { column(width - 1) }
        var top: [UInt8] { row(0) }
        var bottom: [UInt8] { row(height - 1) }

        var picture: String {
            (0..<height).map { y in String((0..<width).map { pixels[y * width + $0] == 0 ? "." : "#" }) }
                .joined(separator: "\n")
        }
    }

    /// The four arms of every line character, arcs and half lines included.
    private static var arms: [(UInt32, SpriteRasterizer.Arms)] {
        var out: [(UInt32, SpriteRasterizer.Arms)] = []
        for scalar in UInt32(0x2500)...0x257F {
            let code = SpriteRasterizer.armTable[Int(scalar - 0x2500)]
            if code != 0 { out.append((scalar, SpriteRasterizer.Arms(code: code))) }
        }
        // Arcs: light arms toward their two ends.
        out.append((0x256D, SpriteRasterizer.Arms(code: 0x11)))  // down, right
        out.append((0x256E, SpriteRasterizer.Arms(code: 0x14)))  // down, left
        out.append((0x256F, SpriteRasterizer.Arms(code: 0x44)))  // up, left
        out.append((0x2570, SpriteRasterizer.Arms(code: 0x41)))  // up, right
        return out
    }

    @Test func aLightLineInANineByEighteenCell() {
        let line = Bitmap(0x2500, 9, 18)
        #expect(line.pixels.count == 9 * 18)
        for y in 0..<18 { #expect(line.row(y) == Array(repeating: y == 8 ? 255 : 0, count: 9), "row \(y)") }
        let box = Bitmap(0x250C, 9, 18)
        #expect(
            box.picture == """
                .........
                .........
                .........
                .........
                .........
                .........
                .........
                .........
                ....#####
                ....#....
                ....#....
                ....#....
                ....#....
                ....#....
                ....#....
                ....#....
                ....#....
                ....#....
                """)
    }

    /// Whatever the characters, an arm leaving one cell meets the arm of the same weight
    /// entering the next exactly: horizontally across columns and vertically across rows.
    @Test(arguments: sizes)
    func armsJoinAcrossCells(size: (Int, Int)) {
        let (width, height) = size
        let straight: [SpriteRasterizer.Arms.Weight: (horizontal: UInt32, vertical: UInt32)] = [
            .light: (0x2500, 0x2502), .heavy: (0x2501, 0x2503), .double: (0x2550, 0x2551),
        ]
        for (scalar, arms) in Self.arms {
            let bitmap = Bitmap(scalar, width, height)
            let name = String(UnicodeScalar(scalar)!)
            if arms.right != .none, let line = straight[arms.right] {
                #expect(
                    bitmap.right == Bitmap(line.horizontal, width, height).left, "\(name) right, \(width)x\(height)")
            }
            if arms.left != .none, let line = straight[arms.left] {
                #expect(bitmap.left == Bitmap(line.horizontal, width, height).right, "\(name) left, \(width)x\(height)")
            }
            if arms.down != .none, let line = straight[arms.down] {
                #expect(bitmap.bottom == Bitmap(line.vertical, width, height).top, "\(name) down, \(width)x\(height)")
            }
            if arms.up != .none, let line = straight[arms.up] {
                #expect(bitmap.top == Bitmap(line.vertical, width, height).bottom, "\(name) up, \(width)x\(height)")
            }
            // And nothing reaches an edge it has no arm toward.
            if arms.right == .none { #expect(bitmap.right.allSatisfy { $0 == 0 }, "\(name) has no right arm") }
            if arms.up == .none { #expect(bitmap.top.allSatisfy { $0 == 0 }, "\(name) has no up arm") }
        }
    }

    /// Straight lines are solid pixels: no antialiased edges to blur where cells meet.
    @Test(arguments: sizes)
    func linesAreWholePixels(size: (Int, Int)) {
        for scalar in UInt32(0x2500)...0x257F where !(0x256D...0x2573).contains(scalar) {
            let bitmap = Bitmap(scalar, size.0, size.1)
            #expect(bitmap.pixels.allSatisfy { $0 == 0 || $0 == 255 }, "\(String(UnicodeScalar(scalar)!))")
            #expect(bitmap.pixels.contains(255))
        }
    }

    @Test func weightsAndDoubles() {
        let light = Bitmap(0x2500, 16, 32)
        let heavy = Bitmap(0x2501, 16, 32)
        let double = Bitmap(0x2550, 16, 32)
        #expect(light.left.filter { $0 == 255 }.count == 2)
        #expect(heavy.left.filter { $0 == 255 }.count == 4)
        // Two light lines a light line apart.
        #expect(double.left.filter { $0 == 255 }.count == 4)
        let rows = double.left.indices.filter { double.left[$0] == 255 }
        #expect(rows == [13, 14, 17, 18])
    }

    /// ╬ is four corners: no line crosses the space between the pairs.
    @Test func doubleCrossesLeaveTheMiddleOpen() {
        let cross = Bitmap(0x256C, 16, 32)
        // The square between the two pairs is empty.
        for y in 15...16 {
            for x in 7...8 { #expect(cross.pixels[y * 16 + x] == 0) }
        }
        // ╔: the outer corner and the inner corner.
        let corner = Bitmap(0x2554, 16, 32)
        #expect(corner.pixels[13 * 16 + 5] == 255)  // outer corner
        #expect(corner.pixels[17 * 16 + 9] == 255)  // inner corner
        #expect(corner.pixels[17 * 16 + 5] == 255)  // outer vertical passes the lower line
        #expect(corner.pixels[13 * 16 + 9] == 255)  // outer horizontal passes the inner line
    }

    @Test func blocks() {
        let full = Bitmap(0x2588, 9, 18)
        #expect(full.pixels.allSatisfy { $0 == 255 })
        let upper = Bitmap(0x2580, 9, 18)
        #expect(upper.row(8) == Array(repeating: 255, count: 9) && upper.row(9) == Array(repeating: 0, count: 9))
        let lower = Bitmap(0x2584, 9, 18)
        #expect(lower.row(8) == Array(repeating: 0, count: 9) && lower.row(9) == Array(repeating: 255, count: 9))
        #expect(Bitmap(0x2592, 9, 18).pixels.allSatisfy { $0 == 128 })
        let quadrant = Bitmap(0x259A, 8, 16)  // upper left and lower right
        #expect(quadrant.pixels[0] == 255 && quadrant.pixels[7] == 0)
        #expect(quadrant.pixels[15 * 8] == 0 && quadrant.pixels[15 * 8 + 7] == 255)
        let eighth = Bitmap(0x2581, 8, 16)
        #expect(eighth.row(13) == Array(repeating: 0, count: 8) && eighth.row(14) == Array(repeating: 255, count: 8))
        let leftHalf = Bitmap(0x258C, 8, 16)
        #expect(leftHalf.row(0) == [255, 255, 255, 255, 0, 0, 0, 0])
    }

    @Test func dashesRepeatEvenly() {
        let dashes = Bitmap(0x2504, 9, 18)
        let row = dashes.row(8)
        // Three runs of lit pixels.
        var runs = 0
        for x in row.indices where row[x] == 255 && (x == 0 || row[x - 1] == 0) { runs += 1 }
        #expect(runs == 3)
        #expect(row.first == 0 || row.last == 0)
    }

    @Test func arcsAndDiagonalsAreSmooth() {
        let arc = Bitmap(0x256D, 16, 32)
        #expect(arc.pixels.contains { $0 > 0 && $0 < 255 })
        let cross = Bitmap(0x2573, 16, 32)
        #expect(cross.pixels[0] > 0 && cross.pixels[15] > 0)
        #expect(cross.pixels[31 * 16] > 0 && cross.pixels[31 * 16 + 15] > 0)
    }

    @Test func powerlineArrows() {
        let solid = Bitmap(0xE0B0, 9, 18)
        // The base fills the left edge (its corners are the triangle's thin ends); the point
        // reaches the right edge only in the middle.
        #expect(solid.left[1...16].allSatisfy { $0 == 255 })
        #expect(solid.left[0] > 0 && solid.left[17] > 0)
        #expect(solid.right[8] > 100 && solid.right[0] == 0 && solid.right[17] == 0)
        let mirrored = Bitmap(0xE0B2, 9, 18)
        #expect(mirrored.right[1...16].allSatisfy { $0 == 255 })
        let outline = Bitmap(0xE0B1, 9, 18)
        #expect(outline.pixels.filter { $0 > 128 }.count < solid.pixels.filter { $0 > 128 }.count / 2)
    }

    @Test func otherScalarsAreTheFontsJob() {
        #expect(!SpriteRasterizer.handles(0x41))
        #expect(SpriteRasterizer.rasterize(0x41, width: 9, height: 18) == nil)
        #expect(SpriteRasterizer.handles(0x2500) && SpriteRasterizer.handles(0x259F))
        #expect(!SpriteRasterizer.handles(0x25A0))
        #expect(SpriteRasterizer.handles(0xE0B3) && !SpriteRasterizer.handles(0xE0B4))
    }
}
