# MenuGlance handshake

The notch belongs to both apps: MenuGlance's island lives there, and Lucid Dreams — Death
Race's quick terminal — springs down from the same spot. So Death Race tells MenuGlance when
the panel opens and closes, and MenuGlance hides its island while the panel is up.

Death Race posts two notifications on the system-wide `DistributedNotificationCenter` (from
`Packages/DeathRaceKit/Sources/DeathRaceApp/LucidDreams/LucidDreamsNotifications.swift`):

| Name | When |
| --- | --- |
| `local.deathraceforcode.lucidDreams.opened` | the panel is summoned |
| `local.deathraceforcode.lucidDreams.closed` | the panel is hidden |

Neither carries a payload. Both go out with `deliverImmediately: true`, so MenuGlance hears
them whether or not it is frontmost.

## The MenuGlance side (paste this in)

Add an observer to MenuGlance's source on your Mac. It needs no entitlement and reads no
payload — just the two names. One place for it is the island controller's setup:

```swift
import Foundation

final class LucidDreamsWatcher {
    private let center = DistributedNotificationCenter.default()
    private var tokens: [NSObjectProtocol] = []

    /// `setIslandHidden(true)` hides the island; `false` brings it back.
    init(setIslandHidden: @escaping (Bool) -> Void) {
        let opened = Notification.Name("local.deathraceforcode.lucidDreams.opened")
        let closed = Notification.Name("local.deathraceforcode.lucidDreams.closed")
        tokens.append(center.addObserver(forName: opened, object: nil, queue: .main) { _ in
            setIslandHidden(true)
        })
        tokens.append(center.addObserver(forName: closed, object: nil, queue: .main) { _ in
            setIslandHidden(false)
        })
    }

    deinit { tokens.forEach { center.removeObserver($0) } }
}
```

Keep the `LucidDreamsWatcher` alive for as long as the island lives (store it in a property;
if it is deallocated the observers go with it).

## Why it is safe, and what happens without it

- **Same signer, trusted channel.** Both apps are signed with your Apple Development identity.
  `DistributedNotificationCenter` is a system-wide bus, so Death Race only ever *posts* on it —
  it never acts on anything it receives — and the two names are specific to these apps.
- **Best-effort.** If MenuGlance isn't updated, nothing breaks: Lucid Dreams still opens and
  closes, and the island just overlaps the panel for the moment it is up. There is no reply,
  no timeout and no shared state to drift — each notification is a plain "it's open now" or
  "it's closed now".
