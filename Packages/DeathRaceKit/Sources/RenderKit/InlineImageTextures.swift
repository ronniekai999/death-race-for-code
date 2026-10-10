import CoreGraphics
import Foundation
import ImageIO
import Metal
import VTCore

/// One serial decoder, with a replaceable desired set rather than an unbounded work queue.
/// PNG decoding and texture upload never run on the main actor. Stale work is discarded.
final class InlineImageTextures: @unchecked Sendable {
    private struct Cached { let revision: UInt64; let texture: any MTLTexture }
    private struct State {
        var wanted: [UInt32: InlineImage] = [:]
        var cached: [UInt32: Cached] = [:]
        var failed: [UInt32: UInt64] = [:]
        var working = false
        var onReady: @Sendable () -> Void = {}
    }
    private let lock = NSLock()
    private var state = State()
    private let device: any MTLDevice
    private let queue = DispatchQueue(label: "Death Race inline image decoder", qos: .userInitiated)

    init(device: any MTLDevice) { self.device = device }

    func prepare(_ images: [UInt32: InlineImage], onReady: @escaping @Sendable () -> Void) {
        let start = lock.withLock {
            state.onReady = onReady
            // Revision checks are O(number of assets), never a comparison of image bytes.
            // Unchanged frames (including an empty cache) do not schedule decoder work.
            let unchanged =
                state.wanted.count == images.count
                && images.allSatisfy {
                    state.wanted[$0.key]?.revision == $0.value.revision
                }
            if unchanged { return false }
            state.wanted = images
            state.cached = state.cached.filter { images[$0.key]?.revision == $0.value.revision }
            state.failed = state.failed.filter { images[$0.key]?.revision == $0.value }
            if state.working { return false }
            state.working = true
            return true
        }
        if start { queue.async { [self] in decodePending() } }
    }

    func texture(for image: UInt32) -> (any MTLTexture)? { lock.withLock { state.cached[image]?.texture } }

    /// Export/readback already waits for the GPU. Drain the bounded decoder first so the
    /// exported frame includes its images. Interactive frames always use prepare instead.
    func prepareForReadback(_ images: [UInt32: InlineImage]) {
        prepare(images, onReady: {})
        queue.sync {}
    }

    private func decodePending() {
        while true {
            let image: InlineImage? = lock.withLock {
                let next = state.wanted.values.first {
                    state.cached[$0.id]?.revision != $0.revision && state.failed[$0.id] != $0.revision
                }
                if next == nil { state.working = false }
                return next
            }
            guard let image else { return }
            let texture = makeTexture(image)
            let notify: (@Sendable () -> Void)? = lock.withLock {
                guard state.wanted[image.id]?.revision == image.revision else { return nil }
                if let texture {
                    state.cached[image.id] = Cached(revision: image.revision, texture: texture)
                } else {
                    state.failed[image.id] = image.revision
                }
                return state.onReady
            }
            notify?()
        }
    }

    private func makeTexture(_ image: InlineImage) -> (any MTLTexture)? {
        guard image.isValid else { return nil }
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        if image.format == .png {
            guard
                let source = CGImageSourceCreateWithData(
                    Data(image.bytes) as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                decoded.width == image.width, decoded.height == image.height,
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            else { return nil }
            let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                // Bitmap row order matches CGImage's data provider and readback PNGs.
                // Flipping the drawing transform would invert PNGs relative to raw RGB.
                context.draw(decoded, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            if !success { return nil }
        } else {
            let channels = image.format == .rgb ? 3 : 4
            for pixel in 0..<(image.width * image.height) {
                let alpha = channels == 4 ? Int(image.bytes[pixel * channels + 3]) : 255
                for channel in 0..<3 {
                    rgba[pixel * 4 + channel] = UInt8(Int(image.bytes[pixel * channels + channel]) * alpha / 255)
                }
                rgba[pixel * 4 + 3] = UInt8(alpha)
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: image.width, height: image.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: image.width * 4)
        }
        return texture
    }
}
