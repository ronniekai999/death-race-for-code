/// One reading for the Energy page's "Right now": what the process has used so far.
public struct EnergySample: Sendable, Equatable {
    /// Seconds, on a clock that only goes forward.
    public var time: Double
    /// CPU time used, user and system, in nanoseconds.
    public var cpuNanoseconds: UInt64
    /// Times the process woke from idle, as the system counts them.
    public var wakeups: UInt64
    /// Frames drawn, all panes together.
    public var frames: Int

    public init(time: Double, cpuNanoseconds: UInt64, wakeups: UInt64, frames: Int) {
        self.time = time
        self.cpuNanoseconds = cpuNanoseconds
        self.wakeups = wakeups
        self.frames = frames
    }
}

/// What the app spent between two readings.
public struct EnergyRates: Sendable, Equatable {
    /// Of one core.
    public var cpuPercent: Double
    public var wakeupsPerSecond: Double
    public var framesPerSecond: Double

    /// "0.2% CPU", "0.4 wakeups a second", "0 frames a second", as the page shows them.
    public var cpuText: String { "\(Self.format(cpuPercent))% CPU" }
    public var wakeupsText: String { "\(Self.format(wakeupsPerSecond)) wakeups a second" }
    public var framesText: String { "\(Self.format(framesPerSecond)) frames a second" }

    /// One decimal under 10, whole numbers above.
    static func format(_ value: Double) -> String {
        let value = max(value, 0)
        if value >= 10 { return String(Int(value.rounded())) }
        let tenths = Int((value * 10).rounded())
        return tenths % 10 == 0 ? String(tenths / 10) : "\(tenths / 10).\(tenths % 10)"
    }
}

/// The Energy page measures the app while it is open, so it must not be what it measures:
/// it samples every two seconds, and its own wakeup each time is taken off.
public enum EnergyMeter {
    /// Seconds between readings while the page is open.
    public static let interval = 2.0

    /// The rates from `earlier` to `later`, less `ownWakeups` for the page's own timer; nil
    /// when no time passed or a counter went back.
    public static func rates(from earlier: EnergySample, to later: EnergySample, ownWakeups: Double = 1)
        -> EnergyRates?
    {
        let seconds = later.time - earlier.time
        guard seconds > 0, later.cpuNanoseconds >= earlier.cpuNanoseconds, later.wakeups >= earlier.wakeups,
            later.frames >= earlier.frames
        else { return nil }
        let cpu = Double(later.cpuNanoseconds - earlier.cpuNanoseconds) / 1e9 / seconds * 100
        let wakeups = max(Double(later.wakeups - earlier.wakeups) - ownWakeups, 0) / seconds
        let frames = Double(later.frames - earlier.frames) / seconds
        return EnergyRates(cpuPercent: cpu, wakeupsPerSecond: wakeups, framesPerSecond: frames)
    }
}
