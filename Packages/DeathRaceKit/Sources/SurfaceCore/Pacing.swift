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

/// What Debug › Log Frame Stats reports for a terminal view: how often it drew, how long a
/// frame took on the main thread, and how long a key press took to reach the screen.
public struct FrameStats: Sendable {
    public private(set) var framesDrawn = 0
    /// Times the display link started again after pausing.
    public private(set) var linkResumes = 0
    /// Milliseconds of main-thread work per frame drawn.
    public private(set) var frameTime = LatencyStats()
    /// Milliseconds from a key press to the next frame on screen.
    public private(set) var keyToScreen = LatencyStats()

    public init() {}

    public mutating func frameDrawn(milliseconds: Double) {
        framesDrawn += 1
        frameTime.add(milliseconds)
    }

    public mutating func linkResumed() {
        linkResumes += 1
    }

    public mutating func keyReachedScreen(milliseconds: Double) {
        keyToScreen.add(milliseconds)
    }

    /// Three lines for the log.
    public var summary: String {
        func line(_ name: String, _ stats: LatencyStats) -> String {
            guard let p50 = stats.percentile(0.5), let p95 = stats.percentile(0.95) else {
                return "\(name): no samples"
            }
            let kept = min(stats.count, stats.capacity)
            return "\(name): p50 \(Self.format(p50)) ms, p95 \(Self.format(p95)) ms (latest \(kept))"
        }
        return """
            frames drawn: \(framesDrawn), display link starts: \(linkResumes)
            \(line("frame time", frameTime))
            \(line("key to screen", keyToScreen))
            """
    }

    /// Two decimals, without Foundation.
    static func format(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        let fraction = hundredths % 100
        return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}

/// How fast a terminal view may draw, as a display link's preferred frame rate range.
///
/// Typing and scrolling get the display's full rate, so the next frame is never late.
/// Output alone needs far less: a busy build at 60 frames a second looks the same and costs
/// half as much (`output-frame-rate-cap`). Low Power Mode lowers both, and a hot Mac gets 30.
public struct FrameRatePolicy: Sendable, Equatable {
    /// The display's highest rate: 120 on ProMotion, usually 60 elsewhere.
    public var displayMaximum: Double
    public var followsLowPowerMode: Bool
    public var capsOutput: Bool

    public init(displayMaximum: Double = 120, followsLowPowerMode: Bool = true, capsOutput: Bool = true) {
        self.displayMaximum = displayMaximum
        self.followsLowPowerMode = followsLowPowerMode
        self.capsOutput = capsOutput
    }

    /// ProcessInfo's thermal states, hottest last.
    public enum Thermal: Int, Sendable, Comparable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Conditions: Sendable, Equatable {
        /// A key press, a scroll or a selection drag in the last second.
        public var recentInput: Bool
        public var lowPowerMode: Bool
        public var thermal: Thermal

        public init(recentInput: Bool, lowPowerMode: Bool = false, thermal: Thermal = .nominal) {
            self.recentInput = recentInput
            self.lowPowerMode = lowPowerMode
            self.thermal = thermal
        }
    }

    /// What CAFrameRateRange takes: frames a second.
    public struct Range: Sendable, Equatable {
        public var minimum: Double
        public var maximum: Double
        public var preferred: Double
    }

    /// How long input counts as recent, in seconds.
    public static let inputWindow = 1.0

    public func range(for conditions: Conditions) -> Range {
        let display = max(displayMaximum, 1)
        var maximum = conditions.recentInput || !capsOutput ? display : min(60, display)
        if followsLowPowerMode && conditions.lowPowerMode {
            maximum = min(maximum, conditions.recentInput ? 60 : 30)
        }
        if conditions.thermal >= .serious { maximum = min(maximum, 30) }
        return Range(minimum: (maximum / 2).rounded(.down), maximum: maximum, preferred: maximum)
    }
}

/// Whether the extra light Phase 9 draws may be drawn at all, from the same conditions the frame
/// rate is clamped by — so the two policies agree about what "spend less" and "hot" mean.
///
/// It reuses `FrameRatePolicy.Conditions` rather than declaring a second condition type, and
/// deliberately does **not** read `recentInput`: the conditions are rebuilt on every key press,
/// so a glow keyed off recent input would blink on and off as you type.
public struct EffectsPolicy: Sendable, Equatable {
    /// The same setting the frame rate follows (`follow-low-power-mode`): Low Power Mode is the
    /// explicit "spend less" signal, and it is the only power signal this app reads.
    public var followsLowPowerMode: Bool

    public init(followsLowPowerMode: Bool = true) {
        self.followsLowPowerMode = followsLowPowerMode
    }

    /// Thermal pressure at or above this turns the effects off. The same threshold
    /// `FrameRatePolicy` clamps to 30 frames a second at.
    public static let tooHot = FrameRatePolicy.Thermal.serious

    /// False when the Mac is asking to be left alone. Whether the effect is wanted at all is the
    /// setting's business and the theme's; this only says whether it may be afforded.
    public func allowsGlow(_ conditions: FrameRatePolicy.Conditions) -> Bool {
        if followsLowPowerMode && conditions.lowPowerMode { return false }
        if conditions.thermal >= Self.tooHot { return false }
        return true
    }
}
