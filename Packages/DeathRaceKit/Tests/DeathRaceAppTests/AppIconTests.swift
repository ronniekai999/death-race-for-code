import CoreGraphics
import Testing

@testable import DeathRaceApp

@Suite struct AppIconTests {
    /// The pixel at `x`, `y` (from the top left) as RGBA bytes.
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }

    /// macOS 26 puts a plate behind an icon with anything outside its shape.
    @Test func nothingIsDrawnOutsideTheSquircle() throws {
        for size in [16, 32, 128, 1024] {
            let image = try #require(AppIcon.image(pixels: size))
            #expect(image.width == size && image.height == size)
            let inset = Int(CGFloat(size) * 100 / 1024)
            for (x, y) in [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1), (inset, inset)] {
                #expect(pixel(image, x, y).alpha == 0, "size \(size) at \(x), \(y)")
            }
            #expect(pixel(image, size / 2, size / 2).alpha == 255, "size \(size): the middle is opaque")
        }
    }

    @Test func theChevronsAreInTheNeon() throws {
        let image = try #require(AppIcon.image(pixels: 1024))
        // The board's units span the squircle: 8.24 px each, from 100 px in.
        func at(_ x: Double, _ y: Double) -> (red: Int, green: Int, blue: Int, alpha: Int) {
            pixel(image, Int(100 + x * 8.24), Int(100 + y * 8.24))
        }
        let pink = at(31, 50)
        let violet = at(55, 50)
        let cyan = at(79, 50)
        #expect(abs(pink.red - 0xEC) < 6 && abs(pink.green - 0x48) < 6 && abs(pink.blue - 0xC4) < 6)
        #expect(abs(violet.red - 0x98) < 6 && abs(violet.green - 0x70) < 6 && abs(violet.blue - 0xFC) < 6)
        #expect(abs(cyan.red - 0x5C) < 6 && abs(cyan.green - 0xC8) < 6 && abs(cyan.blue - 0xFC) < 6)
    }

    @Test func theSmallestSizeStillHasItsChevrons() throws {
        let image = try #require(AppIcon.image(pixels: 16))
        // The middle chevron's point is at unit 57, 50, about pixel 8.9, 8.0; its lower arm
        // runs through pixel 8, 8.
        let middle = pixel(image, 8, 8)
        #expect(middle.blue > 170, "\(middle)")
    }

    @Test func theIconsetHasEverySize() {
        #expect(AppIcon.iconset.count == 10)
        #expect(Set(AppIcon.iconset.map { $0.pixels }) == [16, 32, 64, 128, 256, 512, 1024])
    }
}
