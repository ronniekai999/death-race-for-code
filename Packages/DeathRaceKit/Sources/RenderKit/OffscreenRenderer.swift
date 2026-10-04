import CoreGraphics
import Foundation
import ImageIO
import Metal
import SurfaceCore
import UniformTypeIdentifiers

/// A rendered frame read back from the GPU: BGRA bytes, top row first.
public struct RenderedImage: Sendable {
    public let width: Int
    public let height: Int
    public let bgra: [UInt8]

    /// The color at a pixel.
    public func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let index = (y * width + x) * 4
        return (bgra[index + 2], bgra[index + 1], bgra[index], bgra[index + 3])
    }

    /// The image as PNG bytes.
    public func pngData() -> Data? {
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Renders frames into a texture and reads them back, for the smoke test and render tests:
/// the same renderer and shaders the windows use, without a window.
public final class OffscreenRenderer {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let renderer: SurfaceRenderer

    /// Throws `RenderError.noDevice` without a Metal device (CI virtual machines may have
    /// none), and `.shaders` when the shaders do not compile.
    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.resources("a command queue") }
        self.device = device
        self.queue = queue
        renderer = SurfaceRenderer(device: device, pipelines: try RenderPipelines(device: device))
    }

    /// Draws `frame` with its grid at `layout` in a target of `layout`'s size, and waits for it.
    public func render(_ frame: Frame, cell: CellMetrics, layout: PixelLayout, glyphs: GlyphCache) throws
        -> RenderedImage
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: layout.width, height: layout.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let rowBytes = layout.width * 4
        guard let target = device.makeTexture(descriptor: descriptor),
            let readback = device.makeBuffer(length: rowBytes * layout.height, options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer()
        else { throw RenderError.resources("an offscreen target") }

        glyphs.beginFrame()
        guard
            renderer.encode(
                frame, cell: cell, layout: layout, glyphs: glyphs, target: target, commandBuffer: commandBuffer)
        else { throw RenderError.resources("a frame") }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw RenderError.resources("a blit") }
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: layout.width, height: layout.height, depth: 1), to: readback,
            destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * layout.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw RenderError.resources("the frame: \(error)") }

        let bytes = UnsafeRawBufferPointer(start: readback.contents(), count: rowBytes * layout.height)
        return RenderedImage(width: layout.width, height: layout.height, bgra: Array(bytes))
    }
}
