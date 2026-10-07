import AppCore
import AppKit
import UserNotifications

/// Ring Ring's delivery: the one part of it that only macOS can do.
///
/// The decision about whether to say anything is `RingRing.notice(for:thresholdSeconds:)`, in
/// portable code with a table of tests behind it. This is the call into the system, and the
/// `Notifier` seam is there so that nothing here has to run for the rest to be covered.
///
/// Two facts worth knowing before trying it, both of which look like bugs and are not:
///
/// - **Authorization is per-signature.** An ad-hoc build is a different app to the system every
///   time it is built, so it asks again on every rebuild. `bundle.sh` signs with an Apple
///   Development identity, which is stable, so a signed build asks once.
/// - **A bare `swift run` cannot ask at all.** There is no bundle, so `UNUserNotificationCenter`
///   has no identity to ask for, and `current()` traps rather than returning nil. That is why
///   `isAvailable` is checked before anything is touched, and why the fallback is silence rather
///   than a crash on launch.
@MainActor
final class RingRingNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    /// Where a tap goes: the pane the command ran in.
    private let focus: @MainActor (UInt64) -> Void
    private var asked = false
    /// Whether the system granted it. Until it answers, notices are delivered anyway and the
    /// system drops them, which is the same outcome as checking and cheaper than queueing.
    private var allowed = true

    /// The key a notification carries so a tap can find its pane again.
    private static let paneKey = "pane"

    init(focus: @escaping @MainActor (UInt64) -> Void) {
        self.focus = focus
        super.init()
    }

    /// Whether this process is one the notification centre will talk to at all.
    ///
    /// `Bundle.main.bundleIdentifier` is nil for a loose executable, and asking
    /// `UNUserNotificationCenter.current()` in that case is fatal rather than empty — so this is
    /// checked first and never second-guessed.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard Self.isAvailable, !asked else { return }
        asked = true
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("death-race: notifications were refused: \(error)") }
            Task { @MainActor [weak self] in self?.allowed = granted }
        }
    }

    func deliver(_ notice: RingRing.Notice, paneID: UInt64) {
        guard Self.isAvailable, allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.userInfo = [Self.paneKey: paneID]
        // No trigger: it is about something that has already happened, so it is delivered now.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("death-race: a notification was not delivered: \(error)") }
        }
    }

    // MARK: - A tap

    /// Brings the pane the command ran in forward, which is the only thing a tap could mean.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let pane = response.notification.request.content.userInfo[Self.paneKey] as? UInt64
        Task { @MainActor [weak self] in
            if let pane { self?.focus(pane) }
            completionHandler()
        }
    }

    /// Shown even while Death Race is frontmost, because "frontmost" is not "watching this
    /// pane": the decision already refused every command you could see finish, so one that got
    /// this far is about a pane in another tab or another window.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
