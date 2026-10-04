/// Turns scroll-wheel and trackpad movement into whole lines.
///
/// Trackpads report distance in points, continuously and with momentum: the distance adds
/// up, and each time it covers a line the view moves a line, keeping the remainder for the
/// next event. Mouse wheels report lines per notch, multiplied by `mouse-scroll-multiplier`.
public struct ScrollAccumulator: Sendable {
    private var remainder = 0.0

    public init() {}

    /// Lines to scroll: positive moves back into history (the content moves down).
    public mutating func lines(forDelta delta: Double, precise: Bool, cellHeight: Double, multiplier: Double) -> Int {
        guard delta != 0, delta.isFinite else { return 0 }
        guard precise else {
            remainder = 0
            let lines = (delta * multiplier).rounded(.towardZero)
            return lines == 0 ? (delta > 0 ? 1 : -1) : Int(lines)
        }
        // A change of direction starts afresh rather than first paying back the remainder.
        if remainder != 0, (remainder > 0) != (delta > 0) { remainder = 0 }
        remainder += delta / max(cellHeight, 1)
        let lines = remainder.rounded(.towardZero)
        remainder -= lines
        return Int(lines)
    }

    /// Forgets partial lines, as when the gesture ends.
    public mutating func reset() {
        remainder = 0
    }
}

/// When the display link runs: from the first change until a few ticks pass with nothing to
/// draw. An idle terminal draws no frames and wakes for nothing.
public struct FramePacer: Sendable {
    public private(set) var isRunning = false
    private var idleTicks = 0
    /// Ticks with nothing to draw before the link pauses.
    public static let idleTicksBeforePause = 3

    public init() {}

    /// Something will need drawing: output, input, a resize. True when the link has to be
    /// started.
    public mutating func wake() -> Bool {
        idleTicks = 0
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// The display link ticked; `drew` says whether there was anything to draw. False when
    /// the link should pause now.
    public mutating func tick(drew: Bool) -> Bool {
        guard isRunning else { return false }
        idleTicks = drew ? 0 : idleTicks + 1
        guard idleTicks >= Self.idleTicksBeforePause else { return true }
        isRunning = false
        idleTicks = 0
        return false
    }
}

/// The latest `capacity` durations, for percentiles in the frame-stats log.
public struct LatencyStats: Sendable {
    private var samples: [Double] = []
    private var next = 0
    public let capacity: Int
    /// How many samples were ever added.
    public private(set) var count = 0

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    public mutating func add(_ sample: Double) {
        if samples.count < capacity {
            samples.append(sample)
        } else {
            samples[next] = sample
        }
        next = (next + 1) % capacity
        count += 1
    }

    /// The `fraction` percentile (0.95 for p95) of the kept samples; nil without samples.
    public func percentile(_ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((fraction * Double(sorted.count - 1)).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
