/// Opt-in headroom for saturated terminal colours. White text keeps SDR brightness.
public enum XDRPolicy {
    public static func headroom(requested: Bool, displayHeadroom: Double, conditions: FrameRatePolicy.Conditions)
        -> Float
    {
        guard requested, displayHeadroom.isFinite, displayHeadroom > 1,
            !conditions.lowPowerMode, conditions.thermal < .serious
        else { return 0 }
        return Float(min(displayHeadroom, 2))
    }
}
