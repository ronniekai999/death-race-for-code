/// The words on a command's badge: how long it took, whether it beat your best, and how it
/// ended.
///
/// Plain numbers rather than a `CommandRecord`, because AppCore does not depend on VTCore or
/// ScreenProtocol and should not start: the words are the app's, the record is the engine's.
/// `StatusLine` and `TabLabel` are the same shape.
///
/// The forms are the ones `docs/NAMING.md` commits to, and the rules with them: sentence case, a
/// middle dot between clauses, and a unit on every number.
public enum FastLabel {

    /// Nil when there is nothing worth saying — which is most commands. A badge appears when one
    /// took longer than `thresholdMilliseconds`, or when it failed, however fast it was: an
    /// `ls` that took eight milliseconds does not need the word "Fast" over it, and twenty of
    /// them do not need twenty badges.
    public static func words(
        milliseconds: UInt32?, exitCode: Int32?, bestMilliseconds: UInt32? = nil,
        thresholdMilliseconds: UInt32 = 1_000
    ) -> String? {
        let failed = exitCode.map { $0 != 0 } ?? false
        if !failed, (milliseconds ?? 0) < thresholdMilliseconds { return nil }

        var clauses: [String] = []
        if let milliseconds { clauses.append("Fast \(duration(milliseconds))") }
        // Only a win is worth a clause: "4.0s slower than your best" is a thing nobody asked to
        // be told, and the gradient flash is what the comparison is really for.
        if !failed, let milliseconds, let best = bestMilliseconds, milliseconds < best {
            clauses.append("\(duration(best - milliseconds)) faster than your best")
        }
        if let exitCode, exitCode != 0 {
            clauses.append(clauses.isEmpty ? "Exited with status \(exitCode)" : "exited with status \(exitCode)")
        }
        guard !clauses.isEmpty else { return nil }
        // The glyph the colour has to come with: `docs/DESIGN.md` says success is cyan and danger
        // is pink-red, and that both always arrive with a word or a ✓ / ✗.
        return clauses.joined(separator: " · ") + (failed ? " ✗" : " ✓")
    }

    /// Whether a run beat the best there was, which is what the 999 gradient is for. A failure
    /// never does, however quick it was.
    public static func isPersonalBest(milliseconds: UInt32?, exitCode: Int32?, bestMilliseconds: UInt32?) -> Bool {
        guard let milliseconds, exitCode == 0, let best = bestMilliseconds else { return false }
        return milliseconds < best
    }

    /// A length of time with its unit, as short as it can be without losing what matters: whole
    /// milliseconds under a second, a tenth of a second under a minute, and whole seconds after
    /// that, because nobody reads the tenths on a four-minute build.
    public static func duration(_ milliseconds: UInt32) -> String {
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 {
            let tenths = (milliseconds + 50) / 100
            return "\(tenths / 10).\(tenths % 10)s"
        }
        let seconds = (milliseconds + 500) / 1_000
        if seconds < 3_600 { return "\(seconds / 60)m \(pad(seconds % 60))s" }
        return "\(seconds / 3_600)h \(pad((seconds % 3_600) / 60))m"
    }

    private static func pad(_ value: UInt32) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
