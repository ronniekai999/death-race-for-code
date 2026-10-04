import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// App icon B, "Triple": three chevrons in the neon on MenuGlance's plum squircle, drawn to
/// Apple's macOS icon grid. The canvas is 1024 px; the squircle is 824 px with continuous
/// corners; nothing is drawn outside it, not even a shadow, since macOS 26 adds the shadow
/// itself and puts a plate behind icons that spill past their shape.
///
/// `DeathRace --write-icon DIR` writes `DIR/AppIcon.iconset`; `scripts/bundle.sh` turns it
/// into the .icns with `iconutil`.
public enum AppIcon {
    /// What an .iconset holds: each file's name and its size in pixels.
    static let iconset: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// The squircle within the 1024 px canvas, and its corner radius.
    static let shapeInset: CGFloat = 100
    static let shapeSize: CGFloat = 824
    static let cornerRadius: CGFloat = 185.4

    /// The chevrons in the board's 100-unit square, which spans the squircle.
    static let chevrons: [(points: [CGPoint], color: UInt32)] = [
        ([CGPoint(x: 17, y: 31), CGPoint(x: 33, y: 50), CGPoint(x: 17, y: 69)], 0xEC48C4),
        ([CGPoint(x: 41, y: 31), CGPoint(x: 57, y: 50), CGPoint(x: 41, y: 69)], 0x9870FC),
        ([CGPoint(x: 65, y: 31), CGPoint(x: 81, y: 50), CGPoint(x: 65, y: 69)], 0x5CC8FC),
    ]

    /// Faint stars, as on MenuGlance's icon: where, how wide (in units) and how bright.
    static let stars: [(x: CGFloat, y: CGFloat, diameter: CGFloat, opacity: CGFloat)] = [
        (20, 16, 1, 0.7), (70, 80, 1, 0.5), (86, 26, 0.5, 0.6), (12, 74, 0.5, 0.5),
    ]

    /// Strokes thicken as the icon shrinks, so the chevrons still read at 16 px.
    static func strokeWidth(pixels: Int) -> CGFloat {
        switch pixels {
        case ...16: 14
        case ...32: 12
        case ...64: 10
        default: 9
        }
    }

    /// The icon at `pixels` square, with a transparent outside.
    static func image(pixels: Int) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = CGFloat(pixels) / 1024
        // The board's units, y down, on the squircle: unit (0, 0) is its top left.
        let unit = shapeSize * scale / 100
        let origin = shapeInset * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin + x * unit, y: CGFloat(pixels) - (origin + y * unit))
        }
        let shapeRect = CGRect(x: origin, y: origin, width: shapeSize * scale, height: shapeSize * scale)
        let shape = continuousRoundedRect(shapeRect, radius: cornerRadius * scale)

        context.saveGState()
        context.addPath(shape)
        context.clip()
        // The plum glow, toward the top right: CSS's radial gradient at 66% 30%, out to
        // the farthest corner.
        let colors = [0x7D2A80, 0x4E1B6C, 0x26114B, 0x170A31].map { rgb($0) } as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.32, 0.66, 1]) {
            let center = point(66, 30)
            let radius = shapeSize * scale * (0.66 * 0.66 + 0.70 * 0.70).squareRoot()
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                options: [.drawsAfterEndLocation])
        }
        if pixels >= 128 {
            for star in stars {
                let diameter = max(star.diameter * unit, 1)
                let center = point(star.x, star.y)
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: star.opacity))
                context.fillEllipse(
                    in: CGRect(
                        x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
            }
        }
        // The rim: a stroke twice as wide as wanted, of which the clip keeps the inner half.
        let rim = max(shapeSize * scale * 0.01, 1)
        context.addPath(shape)
        context.setStrokeColor(rgb(0x9870FC, alpha: 0.7))
        context.setLineWidth(rim * 2)
        context.strokePath()

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(strokeWidth(pixels: pixels) * unit)
        for chevron in chevrons {
            context.beginPath()
            context.addLines(between: chevron.points.map { point($0.x, $0.y) })
            context.setStrokeColor(rgb(chevron.color))
            context.strokePath()
        }
        context.restoreGState()
        return context.makeImage()
    }

    /// Writes `directory/AppIcon.iconset` with every size.
    public static func writeIconset(to directory: URL) throws {
        let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for (name, pixels) in Self.iconset {
            let url = iconset.appendingPathComponent("\(name).png")
            guard let image = image(pixels: pixels),
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A rounded rectangle with continuous corners, the curvature easing into the straight
    /// edges as in Apple's icon shape (the iOS 7 corner, as PaintCode measured it).
    static func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2 / 1.528_665)
        let path = CGMutablePath()
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        // One corner's curves, from the edge before it to the edge after it, in a frame where
        // `along` runs down the first edge and `across` toward the second.
        func corner(_ corner: CGPoint, along: CGPoint, across: CGPoint) {
            func at(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
                CGPoint(
                    x: corner.x - along.x * a * r + across.x * b * r, y: corner.y - along.y * a * r + across.y * b * r)
            }
            path.addLine(to: at(1.528_665, 0))
            path.addCurve(to: at(0.631_494, 0.074_911), control1: at(1.088_493, 0), control2: at(0.868_407, 0))
            path.addCurve(
                to: at(0.074_911, 0.631_494), control1: at(0.372_824, 0.169_060), control2: at(0.169_060, 0.372_824))
            path.addCurve(to: at(0, 1.528_665), control1: at(0, 0.868_407), control2: at(0, 1.088_493))
        }
        path.move(to: CGPoint(x: minX + 1.528_665 * r, y: minY))
        corner(CGPoint(x: maxX, y: minY), along: CGPoint(x: 1, y: 0), across: CGPoint(x: 0, y: 1))
        corner(CGPoint(x: maxX, y: maxY), along: CGPoint(x: 0, y: 1), across: CGPoint(x: -1, y: 0))
        corner(CGPoint(x: minX, y: maxY), along: CGPoint(x: -1, y: 0), across: CGPoint(x: 0, y: -1))
        corner(CGPoint(x: minX, y: minY), along: CGPoint(x: 0, y: -1), across: CGPoint(x: 1, y: 0))
        path.closeSubpath()
        return path
    }
}
