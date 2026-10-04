import VTCore

/// How far a pane that is not the active one fades toward the window's ground. The shaders
/// apply it to every layer they draw, so it costs one frame when it changes and nothing after.
public struct Dimming: Equatable, Sendable {
    public var color: RGB
    /// 0 leaves the pane as it is; 1 would leave only `color`.
    public var amount: Double

    public init(color: RGB, amount: Double) {
        self.color = color
        self.amount = amount
    }

    /// As the shaders' `Uniforms.dim` holds it: the color, with the amount in the alpha byte.
    public var packed: PackedColor {
        let alpha = UInt32((min(max(amount, 0), 1) * 255).rounded())
        return UInt32(color.red) | UInt32(color.green) << 8 | UInt32(color.blue) << 16 | alpha << 24
    }

    /// What the shaders make of `color`, for what they do not draw (the cursor).
    public func apply(to other: RGB) -> RGB {
        other.mixed(with: color, amount: Double(packed >> 24) / 255)
    }
}
