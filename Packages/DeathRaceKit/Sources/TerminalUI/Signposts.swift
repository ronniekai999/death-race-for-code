import os

/// Signposts for Instruments, under the subsystem `local.deathraceforcode.DeathRace`:
///
/// - intervals: `Frame` (building and presenting one) and `DeltaApply` (taking what the
///   session sent);
/// - events: `LinkResumed` and `LinkPaused` (the display link starting and stopping),
///   `KeyToScreen` (a key press reaching the screen, in milliseconds) and `Bell`.
///
/// Record with the Points of Interest or os_signpost instrument, next to Metal System Trace
/// and Time Profiler.
@MainActor
enum Signposts {
    static let signposter = OSSignposter(subsystem: "local.deathraceforcode.DeathRace", category: "Terminal")
}
