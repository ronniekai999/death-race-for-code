import Foundation

/// The notch is shared with MenuGlance. Death Race posts these on the system-wide
/// `DistributedNotificationCenter` when the Lucid Dreams panel opens and closes; MenuGlance
/// observes them to hide its island while the panel is up (see docs/MENUGLANCE-HANDSHAKE.md).
/// Both apps are signed with the same identity, so the channel is trusted. The handshake is
/// best-effort: if MenuGlance hasn't been updated, the two just briefly share the notch.
enum LucidDreamsHandshake {
    static let opened = Notification.Name("local.deathraceforcode.lucidDreams.opened")
    static let closed = Notification.Name("local.deathraceforcode.lucidDreams.closed")

    static func post(open: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            open ? opened : closed, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
