import CoreGraphics
import Foundation
import Metal
import SurfaceCore
import VTCore

/// The GPU every terminal view shares: one device, one command queue, the compiled shaders.
@MainActor
public final class RenderContext {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    public let pipelines: RenderPipelines
    private var extendedAttempted = false
    private var extended: RenderPipelines?
    public var extendedPipelines: RenderPipelines? {
        if !extendedAttempted {
            extendedAttempted = true
            extended = try? RenderPipelines(device: device, pixelFormat: .rgba16Float)
        }
        return extended
    }

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.resources("a command queue") }
        self.device = device
        self.queue = queue
        pipelines = try RenderPipelines(device: device)
    }

    /// The shared context, made on first use; nil without a GPU or if the shaders failed,
    /// with the reason in `failure`.
    public static var shared: RenderContext? {
        if let made { return made }
        guard failure == nil else { return nil }
        do {
            made = try RenderContext()
        } catch {
            failure = error
        }
        return made
    }

    private static var made: RenderContext?
    public private(set) static var failure: (any Error)?
}

/// The image of a block cursor: the cursor color, with the character under it drawn in the
/// cursor's text color. Core Animation shows it above the Metal layer, so blinking it never
/// redraws the terminal.
public enum CursorImage {
    public static func make(
        glyph: RasterizedGlyph?, cell: CellMetrics, cells: Int, cursor: RGB, text: RGB
    ) -> CGImage? {
        let width = cell.width * max(cells, 1)
        let height = cell.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = cursor.blue
            pixels[index + 1] = cursor.green
            pixels[index + 2] = cursor.red
            pixels[index + 3] = 255
        }
        if let glyph, !glyph.isEmpty {
            for gy in 0..<glyph.height {
                let y = glyph.offsetY + gy
                guard y >= 0, y < height else { continue }
                for gx in 0..<glyph.width {
                    let x = glyph.offsetX + gx
                    guard x >= 0, x < width else { continue }
                    let target = (y * width + x) * 4
                    if glyph.atlas == .color {
                        // Premultiplied BGRA over the cursor color.
                        let source = (gy * glyph.width + gx) * 4
                        let alpha = Int(glyph.pixels[source + 3])
                        for channel in 0..<3 {
                            let under = Int(pixels[target + channel])
                            pixels[target + channel] = UInt8(
                                clamping: Int(glyph.pixels[source + channel]) + under * (255 - alpha) / 255)
                        }
                    } else {
                        let coverage = Int(glyph.pixels[gy * glyph.width + gx])
                        let blend = { (over: UInt8, under: UInt8) -> UInt8 in
                            UInt8((Int(over) * coverage + Int(under) * (255 - coverage)) / 255)
                        }
                        pixels[target] = blend(text.blue, pixels[target])
                        pixels[target + 1] = blend(text.green, pixels[target + 1])
                        pixels[target + 2] = blend(text.red, pixels[target + 2])
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
