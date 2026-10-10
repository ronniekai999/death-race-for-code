import Dispatch
import Metal
import ScreenProtocol
import SurfaceCore
import VTCore

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shaders(String)
    case resources(String)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .shaders(let reason): "the shaders did not compile: \(reason)"
        case .resources(let what): "Metal could not make \(what)"
        }
    }
}

/// The compiled shaders: four pipelines for one device and one pixel format.
public final class RenderPipelines: @unchecked Sendable {
    // Pipeline states are immutable and thread-safe, as Metal documents; Sendable by hand
    // because the protocols are not marked.
    let backgrounds: any MTLRenderPipelineState
    let glows: any MTLRenderPipelineState
    let glyphs: any MTLRenderPipelineState
    let decorations: any MTLRenderPipelineState
    let images: any MTLRenderPipelineState
    public let pixelFormat: MTLPixelFormat

    /// How a draw reaches the target.
    enum Blending {
        /// Straight over what is there: the backgrounds, which cover every pixel.
        case replacing
        /// Premultiplied source over destination: the shaders multiply color by coverage.
        case over
        /// Added to what is there, leaving the target's alpha alone — light, not ink.
        case adding
    }

    /// Compiles `Shaders.source`: a few tens of milliseconds, so done once per device and
    /// off the main thread where it can be.
    public init(device: any MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RenderError.shaders(String(describing: error))
        }
        func pipeline(
            _ vertex: String, _ fragment: String, _ blending: Blending
        ) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = vertex
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
                throw RenderError.shaders("\(vertex) or \(fragment) is missing")
            }
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            switch blending {
            case .replacing:
                break
            case .over:
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .adding:
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                // Light added to the frame must not touch its alpha, which the glyph draw after
                // it blends against. The write mask says so, and the alpha factors say it again
                // in case the mask is ever widened: keep what is there, add nothing.
                attachment.alphaBlendOperation = .add
                attachment.sourceAlphaBlendFactor = .zero
                attachment.destinationAlphaBlendFactor = .one
                attachment.writeMask = [.red, .green, .blue]
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw RenderError.shaders("\(vertex): \(error)")
            }
        }
        backgrounds = try pipeline("backgroundVertex", "backgroundFragment", .replacing)
        glows = try pipeline("glowVertex", "glowFragment", .adding)
        glyphs = try pipeline("glyphVertex", "glyphFragment", .over)
        decorations = try pipeline("decorationVertex", "decorationFragment", .over)
        images = try pipeline("imageVertex", "imageFragment", .over)
        self.pixelFormat = pixelFormat
    }
}

/// Where the grid sits in the target, in pixels.
public struct PixelLayout: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var originX: Int
    public var originY: Int

    public init(width: Int, height: Int, originX: Int, originY: Int) {
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
    }
}

/// The values every shader reads, laid out as the shaders' `Uniforms`: 48 bytes.
struct Uniforms {
    var viewportSize: SIMD2<Float>
    var gridOrigin: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var columns: UInt32
    var rows: UInt32
    var clearColor: UInt32
    /// Packed sRGB: what an inactive pane fades toward; its alpha is how far (0, not at all).
    var dim: UInt32 = 0
    /// `Glow.packed`: how strong a bright colour's light is, in the alpha byte. 0 draws none,
    /// and the glow draw is skipped outright.
    var glow: UInt32 = 0
    /// Padding with a name, and XDR Neon's second word when it needs one.
    ///
    /// Not tidy-up-able: without it `size` is 44 while `stride` is 48 — `SIMD2<Float>` aligns to
    /// 8 — and the encoder sends the *stride*, so the shader would read four bytes this side
    /// never wrote. `UniformsLayoutTests` fails loudly if it goes.
    var reserved: UInt32 = 0
}

/// Encodes frames for one surface: the atlas textures, and per-frame buffers for up to three
/// frames in flight.
///
/// The main thread never waits for the GPU: when all three slots are still drawing, `encode`
/// declines and the frame is drawn on the next tick.
public final class SurfaceRenderer {
    public let device: any MTLDevice
    public let pipelines: RenderPipelines
    private let imageTextures: InlineImageTextures
    private var maskTexture: (any MTLTexture)?
    private var colorTexture: (any MTLTexture)?
    private var maskGeneration = -1
    private var colorGeneration = -1
    private var slots: [Slot]
    private var nextSlot = 0
    private let available = DispatchSemaphore(value: SurfaceRenderer.framesInFlight)
    public static let framesInFlight = 3

    private struct Slot {
        var backgrounds: (any MTLBuffer)?
        var glyphs: (any MTLBuffer)?
        var decorations: (any MTLBuffer)?
    }

    public init(device: any MTLDevice, pipelines: RenderPipelines) {
        self.device = device
        imageTextures = InlineImageTextures(device: device)
        self.pipelines = pipelines
        slots = Array(repeating: Slot(), count: Self.framesInFlight)
    }

    func prepareImagesForReadback(_ mirror: MirrorGrid) { imageTextures.prepareForReadback(mirror.images) }

    /// Encodes `frame` into `commandBuffer`, drawing into `target`, faded toward `dim` by its
    /// alpha (an inactive pane) and with bright colours throwing light as strongly as `glow`'s
    /// alpha says (`Glow.packed`; 0 draws none at all). False when every slot is still in flight
    /// (draw again on the next tick) or a buffer could not be made.
    @discardableResult
    public func encode(
        _ frame: Frame, cell: CellMetrics, layout: PixelLayout, glyphs: GlyphCache, target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer, dim: PackedColor = 0, glow: PackedColor = 0,
        mirror: MirrorGrid? = nil, xdrHeadroom: Float = 0, onImagesReady: @escaping @Sendable () -> Void = {}
    ) -> Bool {
        guard available.wait(timeout: .now()) == .success else { return false }
        var encoded = false
        defer {
            // The slot comes back when the GPU is done with it, or now if nothing was encoded.
            if encoded {
                let semaphore = available
                commandBuffer.addCompletedHandler { _ in semaphore.signal() }
            } else {
                available.signal()
            }
        }

        uploadAtlases(glyphs)
        let index = nextSlot
        nextSlot = (nextSlot + 1) % Self.framesInFlight
        guard let backgrounds = fill(&slots[index].backgrounds, with: frame.backgrounds),
            let maskTexture, let colorTexture
        else { return false }
        let glyphBuffer = frame.glyphs.isEmpty ? nil : fill(&slots[index].glyphs, with: frame.glyphs)
        let decorationBuffer =
            frame.decorations.isEmpty ? nil : fill(&slots[index].decorations, with: frame.decorations)

        var uniforms = Uniforms(
            viewportSize: SIMD2(Float(layout.width), Float(layout.height)),
            gridOrigin: SIMD2(Float(layout.originX), Float(layout.originY)),
            cellSize: SIMD2(Float(cell.width), Float(cell.height)),
            columns: UInt32(frame.columns), rows: UInt32(frame.rows), clearColor: frame.clearColor, dim: dim,
            glow: glow, reserved: xdrHeadroom.bitPattern)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "Death Race frame"

        encoder.setRenderPipelineState(pipelines.backgrounds)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBuffer(backgrounds, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if let mirror { imageTextures.prepare(mirror.images, onReady: onImagesReady) }
        if let mirror {
            drawImages(mirror, negative: true, encoder: encoder, uniforms: &uniforms, layout: layout, cell: cell)
        }

        // The glow and the glyphs are the same instances from the same buffer, so they bind it
        // once: two blocks would be four redundant encoder calls a frame and, worse, two places
        // that have to agree about the instance count.
        if let glyphBuffer {
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(maskTexture, index: 0)
            // Light first and the crisp glyphs over it, so a fully covered pixel is exactly what
            // it would be without this draw. Skipped outright when there is no strength, which
            // is what makes a frame with the parameter left out bit-identical to today's — and
            // it tests the alpha byte, not the whole word, because that is all the shader reads:
            // a tint with no strength (which `Uniforms.glow` reserves for XDR) would otherwise
            // dispatch an instance per glyph for the vertex stage to cull.
            if glow >> 24 != 0 {
                encoder.setRenderPipelineState(pipelines.glows)
                encoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: frame.glyphs.count)
            }
            encoder.setRenderPipelineState(pipelines.glyphs)
            encoder.setFragmentTexture(colorTexture, index: 1)
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: frame.glyphs.count)
        }
        if let decorationBuffer {
            encoder.setRenderPipelineState(pipelines.decorations)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setVertexBuffer(decorationBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: frame.decorations.count)
        }
        if let mirror {
            drawImages(mirror, negative: false, encoder: encoder, uniforms: &uniforms, layout: layout, cell: cell)
        }
        encoder.endEncoding()
        encoded = true
        return true
    }

    private func drawImages(
        _ mirror: MirrorGrid, negative: Bool, encoder: any MTLRenderCommandEncoder,
        uniforms: inout Uniforms, layout: PixelLayout, cell: CellMetrics
    ) {
        guard layout.originX >= 0, layout.originY >= 0 else { return }
        let width = min(layout.width - layout.originX, mirror.columns * cell.width)
        let height = min(layout.height - layout.originY, mirror.rows * cell.height)
        guard width > 0, height > 0 else { return }
        encoder.setScissorRect(MTLScissorRect(x: layout.originX, y: layout.originY, width: width, height: height))
        for p in mirror.placements.sorted(by: { ($0.zIndex, $0.key) < ($1.zIndex, $1.key) })
        where p.alternate == mirror.isAlternateScreen && (p.zIndex < 0) == negative {
            let y: Int
            if p.line >= mirror.viewportTopLine {
                let difference = p.line - mirror.viewportTopLine
                guard difference < UInt64(mirror.rows) else { continue }
                y = Int(difference)
            } else {
                let difference = mirror.viewportTopLine - p.line
                guard difference < UInt64(p.rows) else { continue }
                y = -Int(difference)
            }
            guard let texture = imageTextures.texture(for: p.imageID) else { continue }
            var rect = SIMD4<Float>(
                Float(layout.originX + p.column * cell.width), Float(layout.originY + y * cell.height),
                Float(p.columns * cell.width), Float(p.rows * cell.height))
            encoder.setRenderPipelineState(pipelines.images)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setFragmentTexture(texture, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: layout.width, height: layout.height))
    }

    /// Copies `values` into `buffer`, making a larger one when it does not fit.
    private func fill<T>(_ buffer: inout (any MTLBuffer)?, with values: [T]) -> (any MTLBuffer)? {
        let length = max(MemoryLayout<T>.stride * values.count, 16)
        if buffer == nil || buffer!.length < length {
            // Room to grow, so a slightly bigger frame does not allocate again.
            buffer = device.makeBuffer(length: length + length / 2, options: .storageModeShared)
        }
        guard let buffer else { return nil }
        values.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { buffer.contents().copyMemory(from: base, byteCount: bytes.count) }
        }
        return buffer
    }

    /// Brings the atlas textures up to date: made again after an atlas grew, otherwise the
    /// rows written since the last frame.
    ///
    /// Writing while earlier frames are still drawing is safe: new glyphs go where nothing
    /// was, and a shelf is reused only after three frames have not drawn from it.
    private func uploadAtlases(_ glyphs: GlyphCache) {
        upload(glyphs.mask, to: &maskTexture, generation: &maskGeneration, format: .r8Unorm)
        upload(glyphs.color, to: &colorTexture, generation: &colorGeneration, format: .bgra8Unorm)
    }

    private func upload(
        _ atlas: AtlasPixels, to texture: inout (any MTLTexture)?, generation: inout Int, format: MTLPixelFormat
    ) {
        let size = atlas.size
        let rowBytes = size * atlas.bytesPerPixel
        var rows = atlas.takeDirtyRows()
        if texture == nil || generation != atlas.sizeGeneration {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: size, height: size, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            texture = device.makeTexture(descriptor: descriptor)
            texture?.label = format == .r8Unorm ? "Glyph coverage" : "Color glyphs"
            generation = atlas.sizeGeneration
            rows = 0..<size
        }
        guard let texture, let rows, !rows.isEmpty else { return }
        atlas.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, rows.lowerBound, size, rows.count), mipmapLevel: 0,
                withBytes: base + rows.lowerBound * rowBytes, bytesPerRow: rowBytes)
        }
    }
}
