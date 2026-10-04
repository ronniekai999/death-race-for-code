/// Draws box drawing (U+2500–257F), block elements (U+2580–259F) and the powerline arrows
/// (U+E0B0–E0B3) at the exact cell size, instead of taking them from the font.
///
/// Font glyphs for these rarely fill their cell exactly, so tmux, htop and vim borders show
/// gaps between rows. Drawn here, lines sit on whole pixels at the same place in every cell,
/// so they join across cells and rows, and every weight lines up with the others.
///
/// The output is a coverage bitmap, one byte per pixel, top row first.
public enum SpriteRasterizer {
    public static func handles(_ scalar: UInt32) -> Bool {
        (0x2500...0x259F).contains(scalar) || (0xE0B0...0xE0B3).contains(scalar)
    }

    /// The bitmap for `scalar` in a `width` × `height` cell, or nil for scalars drawn by the
    /// font.
    public static func rasterize(_ scalar: UInt32, width: Int, height: Int) -> [UInt8]? {
        guard handles(scalar), width > 0, height > 0 else { return nil }
        var canvas = Canvas(width: width, height: height)
        switch scalar {
        case 0x2504...0x250B, 0x254C...0x254F:
            canvas.dashes(scalar)
        case 0x256D...0x2570:
            canvas.arc(scalar)
        case 0x2571...0x2573:
            canvas.diagonals(scalar)
        case 0x2500...0x257F:
            canvas.lines(Arms(code: armTable[Int(scalar - 0x2500)]))
        case 0x2580...0x259F:
            canvas.block(scalar)
        default:
            canvas.powerline(scalar)
        }
        return canvas.pixels
    }

    /// Each box-drawing character's four arms, generated from the Unicode character names:
    /// two bits each for up, down, left and right (high to low), 0 none, 1 light, 2 heavy,
    /// 3 double. Dashes, arcs and diagonals are 0 here and drawn separately.
    static let armTable: [UInt8] = [
        0x05, 0x0A, 0x50, 0xA0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x12, 0x21, 0x22,
        0x14, 0x18, 0x24, 0x28, 0x41, 0x42, 0x81, 0x82, 0x44, 0x48, 0x84, 0x88, 0x51, 0x52, 0x91, 0x61,
        0xA1, 0x92, 0x62, 0xA2, 0x54, 0x58, 0x94, 0x64, 0xA4, 0x98, 0x68, 0xA8, 0x15, 0x19, 0x16, 0x1A,
        0x25, 0x29, 0x26, 0x2A, 0x45, 0x49, 0x46, 0x4A, 0x85, 0x89, 0x86, 0x8A, 0x55, 0x59, 0x56, 0x5A,
        0x95, 0x65, 0xA5, 0x99, 0x96, 0x69, 0x66, 0x9A, 0x6A, 0xA9, 0xA6, 0xAA, 0x00, 0x00, 0x00, 0x00,
        0x0F, 0xF0, 0x13, 0x31, 0x33, 0x1C, 0x34, 0x3C, 0x43, 0xC1, 0xC3, 0x4C, 0xC4, 0xCC, 0x53, 0xF1,
        0xF3, 0x5C, 0xF4, 0xFC, 0x1F, 0x35, 0x3F, 0x4F, 0xC5, 0xCF, 0x5F, 0xF5, 0xFF, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x04, 0x40, 0x01, 0x10, 0x08, 0x80, 0x02, 0x20, 0x06, 0x60, 0x09, 0x90,
    ]

    /// The arms of a box-drawing character.
    struct Arms: Equatable {
        enum Weight: Int, Comparable {
            case none = 0, light, heavy, double
            static func < (a: Weight, b: Weight) -> Bool { a.rawValue < b.rawValue }
        }

        var up: Weight
        var down: Weight
        var left: Weight
        var right: Weight

        init(code: UInt8) {
            up = Weight(rawValue: Int(code >> 6 & 3)) ?? .none
            down = Weight(rawValue: Int(code >> 4 & 3)) ?? .none
            left = Weight(rawValue: Int(code >> 2 & 3)) ?? .none
            right = Weight(rawValue: Int(code & 3)) ?? .none
        }
    }
}

/// A coverage bitmap being drawn.
struct Canvas {
    let width: Int
    let height: Int
    var pixels: [UInt8]
    /// A light line's thickness: an eighth of the cell's width, at least a pixel. Heavy is
    /// twice that; a double line is two light lines a light line apart.
    let light: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height)
        light = max(1, Int((Double(width) / 8).rounded()))
    }

    func thickness(_ weight: SpriteRasterizer.Arms.Weight) -> Int {
        weight == .heavy ? 2 * light : light
    }

    /// Where a horizontal line of `thickness` starts, from the top: centered, rounding up.
    func lineTop(_ thickness: Int) -> Int { (height - thickness) / 2 }
    /// Where a vertical line of `thickness` starts, from the left.
    func lineLeft(_ thickness: Int) -> Int { (width - thickness) / 2 }

    /// Fills x in `x0..<x1`, y in `y0..<y1`, clipped to the canvas.
    mutating func fill(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, value: UInt8 = 255) {
        let left = max(0, x0)
        let right = min(width, x1)
        let top = max(0, y0)
        let bottom = min(height, y1)
        guard left < right, top < bottom else { return }
        for y in top..<bottom {
            for x in left..<right {
                pixels[y * width + x] = max(pixels[y * width + x], value)
            }
        }
    }

    /// Sets a pixel to at least `coverage` (0...1).
    mutating func cover(_ x: Int, _ y: Int, _ coverage: Double) {
        guard x >= 0, x < width, y >= 0, y < height, coverage > 0 else { return }
        let value = UInt8(min(255, (coverage * 255).rounded()))
        pixels[y * width + x] = max(pixels[y * width + x], value)
    }

    // MARK: - Lines

    mutating func lines(_ arms: SpriteRasterizer.Arms) {
        let horizontalDouble = arms.left == .double || arms.right == .double
        let verticalDouble = arms.up == .double || arms.down == .double
        switch (horizontalDouble, verticalDouble) {
        case (false, false): singleLines(arms)
        case (true, false): doubleHorizontal(arms)
        case (false, true): doubleVertical(arms)
        case (true, true): doubleBoth(arms)
        }
    }

    /// Light and heavy arms. Each reaches from its edge into the joint, as far as the far side
    /// of the thickest perpendicular arm, so arms of any weight meet without gaps.
    private mutating func singleLines(_ arms: SpriteRasterizer.Arms) {
        let vertical = max(arms.up, arms.down)
        let horizontal = max(arms.left, arms.right)
        if arms.right != .none {
            let t = thickness(arms.right)
            let start = vertical != .none ? lineLeft(thickness(vertical)) : lineLeft(t)
            fill(start, width, lineTop(t), lineTop(t) + t)
        }
        if arms.left != .none {
            let t = thickness(arms.left)
            let end =
                vertical != .none ? lineLeft(thickness(vertical)) + thickness(vertical) : lineLeft(t) + t
            fill(0, end, lineTop(t), lineTop(t) + t)
        }
        if arms.down != .none {
            let t = thickness(arms.down)
            let start = horizontal != .none ? lineTop(thickness(horizontal)) : lineTop(t)
            fill(lineLeft(t), lineLeft(t) + t, start, height)
        }
        if arms.up != .none {
            let t = thickness(arms.up)
            let end =
                horizontal != .none ? lineTop(thickness(horizontal)) + thickness(horizontal) : lineTop(t) + t
            fill(lineLeft(t), lineLeft(t) + t, 0, end)
        }
    }

    /// Double horizontal arms with light (or no) vertical ones: ═ ╒ ╞ ╤ ╪ and the like. The
    /// two lines attach to the vertical stem; the stem spans both lines at a corner, touches
    /// the near line at a tee, and crosses when it runs through.
    private mutating func doubleHorizontal(_ arms: SpriteRasterizer.Arms) {
        let t = light
        let band = lineTop(3 * t)  // the upper line's top; the lower line starts at band + 2t
        let stem = lineLeft(t)
        let hasVertical = arms.up != .none || arms.down != .none
        let centre = width / 2
        if arms.right != .none {
            let start = hasVertical ? stem : centre
            fill(start, width, band, band + t)
            fill(start, width, band + 2 * t, band + 3 * t)
        }
        if arms.left != .none {
            let end = hasVertical ? stem + t : centre
            fill(0, end, band, band + t)
            fill(0, end, band + 2 * t, band + 3 * t)
        }
        let both = arms.left != .none && arms.right != .none
        if arms.up != .none && arms.down != .none {
            fill(stem, stem + t, 0, height)
        } else if arms.up != .none {
            fill(stem, stem + t, 0, both ? band + t : band + 3 * t)
        } else if arms.down != .none {
            fill(stem, stem + t, both ? band + 2 * t : band, height)
        }
    }

    /// Double vertical arms with light (or no) horizontal ones: ║ ╓ ╟ ╥ ╫ and the like.
    private mutating func doubleVertical(_ arms: SpriteRasterizer.Arms) {
        let t = light
        let band = lineLeft(3 * t)  // the left line's left; the right line starts at band + 2t
        let stem = lineTop(t)
        let hasHorizontal = arms.left != .none || arms.right != .none
        let centre = height / 2
        if arms.down != .none {
            let start = hasHorizontal ? stem : centre
            fill(band, band + t, start, height)
            fill(band + 2 * t, band + 3 * t, start, height)
        }
        if arms.up != .none {
            let end = hasHorizontal ? stem + t : centre
            fill(band, band + t, 0, end)
            fill(band + 2 * t, band + 3 * t, 0, end)
        }
        let both = arms.up != .none && arms.down != .none
        if arms.left != .none && arms.right != .none {
            fill(0, width, stem, stem + t)
        } else if arms.right != .none {
            fill(both ? band + 2 * t : band, width, stem, stem + t)
        } else if arms.left != .none {
            fill(0, both ? band + t : band + 3 * t, stem, stem + t)
        }
    }

    /// Double lines both ways: ╔ ╗ ╚ ╝ ╠ ╣ ╦ ╩ ╬. Each of the four lines runs from its edge
    /// to where it meets a line of the other direction: the inner line of a corner stops at
    /// the inner line it turns into, the outer one at the outer one, so lines never cross.
    private mutating func doubleBoth(_ arms: SpriteRasterizer.Arms) {
        let t = light
        let top = lineTop(3 * t)  // upper horizontal line; the lower is at top + 2t
        let left = lineLeft(3 * t)  // left vertical line; the right is at left + 2t
        let up = arms.up != .none
        let down = arms.down != .none
        let leftArm = arms.left != .none
        let rightArm = arms.right != .none

        if rightArm {
            let upper = up ? left + 2 * t : down ? left : width / 2
            let lower = down ? left + 2 * t : up ? left : width / 2
            fill(upper, width, top, top + t)
            fill(lower, width, top + 2 * t, top + 3 * t)
        }
        if leftArm {
            let upper = up ? left + t : down ? left + 3 * t : width / 2
            let lower = down ? left + t : up ? left + 3 * t : width / 2
            fill(0, upper, top, top + t)
            fill(0, lower, top + 2 * t, top + 3 * t)
        }
        if up {
            let leftLine = leftArm ? top + t : rightArm ? top + 3 * t : height / 2
            let rightLine = rightArm ? top + t : leftArm ? top + 3 * t : height / 2
            fill(left, left + t, 0, leftLine)
            fill(left + 2 * t, left + 3 * t, 0, rightLine)
        }
        if down {
            let leftLine = leftArm ? top + 2 * t : rightArm ? top : height / 2
            let rightLine = rightArm ? top + 2 * t : leftArm ? top : height / 2
            fill(left, left + t, leftLine, height)
            fill(left + 2 * t, left + 3 * t, rightLine, height)
        }
    }

    // MARK: - Dashes, arcs, diagonals

    /// ┄ ┅ ┆ ┇ ┈ ┉ ┊ ┋ ╌ ╍ ╎ ╏: dashes centred in equal parts of the cell, so the pattern
    /// repeats evenly across cells.
    mutating func dashes(_ scalar: UInt32) {
        let (count, heavy, vertical): (Int, Bool, Bool) =
            switch scalar {
            case 0x2504: (3, false, false)
            case 0x2505: (3, true, false)
            case 0x2506: (3, false, true)
            case 0x2507: (3, true, true)
            case 0x2508: (4, false, false)
            case 0x2509: (4, true, false)
            case 0x250A: (4, false, true)
            case 0x250B: (4, true, true)
            case 0x254C: (2, false, false)
            case 0x254D: (2, true, false)
            case 0x254E: (2, false, true)
            default: (2, true, true)
            }
        let t = heavy ? 2 * light : light
        let length = vertical ? height : width
        for index in 0..<count {
            let start = index * length / count
            let end = (index + 1) * length / count
            let gap = max(1, (end - start) / 3)
            let from = start + gap / 2
            let to = end - (gap - gap / 2)
            if vertical {
                fill(lineLeft(t), lineLeft(t) + t, from, to)
            } else {
                fill(from, to, lineTop(t), lineTop(t) + t)
            }
        }
    }

    /// ╭ ╮ ╯ ╰: a quarter circle between two straight ends, which sit exactly where the
    /// straight lines they join are.
    mutating func arc(_ scalar: UInt32) {
        let t = light
        let lineX = lineLeft(t)
        let lineY = lineTop(t)
        let centreX = Double(lineX) + Double(t) / 2
        let centreY = Double(lineY) + Double(t) / 2
        let radius = Double(max(1, min(width, height) / 2 - t))
        // Which way the arms go: right or left, down or up.
        let goesRight = scalar == 0x256D || scalar == 0x2570
        let goesDown = scalar == 0x256D || scalar == 0x256E
        let circleX = centreX + (goesRight ? radius : -radius)
        let circleY = centreY + (goesDown ? radius : -radius)

        // The straight ends, from the arc to the edges.
        if goesRight {
            fill(Int(circleX.rounded(.down)), width, lineY, lineY + t)
        } else {
            fill(0, Int(circleX.rounded(.up)), lineY, lineY + t)
        }
        if goesDown {
            fill(lineX, lineX + t, Int(circleY.rounded(.down)), height)
        } else {
            fill(lineX, lineX + t, 0, Int(circleY.rounded(.up)))
        }
        // The quarter circle, antialiased: coverage falls off with the distance from the arc.
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5
                let inQuadrant =
                    (goesRight ? px <= circleX : px >= circleX) && (goesDown ? py <= circleY : py >= circleY)
                guard inQuadrant else { continue }
                let distance = ((px - circleX) * (px - circleX) + (py - circleY) * (py - circleY)).squareRoot()
                cover(x, y, Double(t) / 2 + 0.5 - abs(distance - radius))
            }
        }
    }

    /// ╱ ╲ ╳: corner to corner, antialiased.
    mutating func diagonals(_ scalar: UInt32) {
        let w = Double(width)
        let h = Double(height)
        var segments: [(Double, Double, Double, Double)] = []
        if scalar == 0x2571 || scalar == 0x2573 { segments.append((w, 0, 0, h)) }
        if scalar == 0x2572 || scalar == 0x2573 { segments.append((0, 0, w, h)) }
        let half = Double(light) / 2
        for (x0, y0, x1, y1) in segments {
            let dx = x1 - x0
            let dy = y1 - y0
            let length = (dx * dx + dy * dy).squareRoot()
            for y in 0..<height {
                for x in 0..<width {
                    let px = Double(x) + 0.5
                    let py = Double(y) + 0.5
                    let distance = abs(dy * px - dx * py + x1 * y0 - y1 * x0) / length
                    cover(x, y, half + 0.5 - distance)
                }
            }
        }
    }

    // MARK: - Blocks and powerline

    mutating func block(_ scalar: UInt32) {
        func eighths(_ n: Int, of length: Int) -> Int { (n * length + 4) / 8 }
        let halfX = width / 2
        let halfY = height / 2
        switch scalar {
        case 0x2580: fill(0, width, 0, halfY)
        case 0x2581...0x2587:
            let rows = eighths(Int(scalar - 0x2580), of: height)
            fill(0, width, height - rows, height)
        case 0x2588: fill(0, width, 0, height)
        case 0x2589...0x258F:
            let columns = eighths(Int(0x2590 - scalar), of: width)
            fill(0, columns, 0, height)
        case 0x2590: fill(halfX, width, 0, height)
        case 0x2591: fill(0, width, 0, height, value: 64)
        case 0x2592: fill(0, width, 0, height, value: 128)
        case 0x2593: fill(0, width, 0, height, value: 191)
        case 0x2594: fill(0, width, 0, eighths(1, of: height))
        case 0x2595: fill(width - eighths(1, of: width), width, 0, height)
        default:
            // Quadrants: upper left, upper right, lower left, lower right.
            let quadrants: [UInt32: (Bool, Bool, Bool, Bool)] = [
                0x2596: (false, false, true, false), 0x2597: (false, false, false, true),
                0x2598: (true, false, false, false), 0x2599: (true, false, true, true),
                0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
                0x259C: (true, true, false, true), 0x259D: (false, true, false, false),
                0x259E: (false, true, true, false), 0x259F: (false, true, true, true),
            ]
            guard let quadrant = quadrants[scalar] else { return }
            if quadrant.0 { fill(0, halfX, 0, halfY) }
            if quadrant.1 { fill(halfX, width, 0, halfY) }
            if quadrant.2 { fill(0, halfX, halfY, height) }
            if quadrant.3 { fill(halfX, width, halfY, height) }
        }
    }

    /// U+E0B0 and U+E0B2, solid triangles pointing right and left, sampled 4 × 4 times a pixel
    /// for smooth edges; U+E0B1 and U+E0B3, their outlines.
    mutating func powerline(_ scalar: UInt32) {
        let w = Double(width)
        let h = Double(height)
        let pointsRight = scalar == 0xE0B0 || scalar == 0xE0B1
        if scalar == 0xE0B0 || scalar == 0xE0B2 {
            for y in 0..<height {
                for x in 0..<width {
                    var inside = 0
                    for sy in 0..<4 {
                        for sx in 0..<4 {
                            let px = Double(x) + (Double(sx) + 0.5) / 4
                            let py = Double(y) + (Double(sy) + 0.5) / 4
                            // Distance from the base edge, against how far the triangle reaches at
                            // this height.
                            let reach = w * (1 - abs(py - h / 2) / (h / 2))
                            let fromBase = pointsRight ? px : w - px
                            if fromBase <= reach { inside += 1 }
                        }
                    }
                    cover(x, y, Double(inside) / 16)
                }
            }
        } else {
            let half = Double(light) / 2
            let tip = (pointsRight ? w : 0, h / 2)
            let base = pointsRight ? 0.0 : w
            for (x0, y0) in [(base, 0.0), (base, h)] {
                let dx = tip.0 - x0
                let dy = tip.1 - y0
                let length = (dx * dx + dy * dy).squareRoot()
                for y in 0..<height {
                    for x in 0..<width {
                        let px = Double(x) + 0.5
                        let py = Double(y) + 0.5
                        // Only alongside the segment, not beyond its ends.
                        let along = ((px - x0) * dx + (py - y0) * dy) / (length * length)
                        guard along >= -0.05, along <= 1.05 else { continue }
                        let distance = abs(dy * px - dx * py + tip.0 * y0 - tip.1 * x0) / length
                        cover(x, y, half + 0.5 - distance)
                    }
                }
            }
        }
    }
}
