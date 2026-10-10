import AppKit
import Metal
import QuartzCore
import RenderKit
import SurfaceCore

extension TerminalSurfaceView {
    func applyXDR(_ conditions: FrameRatePolicy.Conditions) {
        guard let layer = metalLayer, let context = RenderContext.shared else { return }
        let desired = XDRPolicy.headroom(
            requested: xdrNeon && isFocused,
            displayHeadroom: Double(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
            conditions: conditions)
        let extended = desired > 0 && context.extendedPipelines != nil
        let format: MTLPixelFormat = extended ? .rgba16Float : .bgra8Unorm
        let headroom: Float = extended ? desired : 0
        if layer.pixelFormat != format {
            layer.pixelFormat = format
            layer.colorspace = CGColorSpace(name: extended ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)
            layer.wantsExtendedDynamicRangeContent = extended
            renderer = nil
        }
        if allowedXDRHeadroom != headroom {
            allowedXDRHeadroom = headroom
            redraw()
        }
    }
}
