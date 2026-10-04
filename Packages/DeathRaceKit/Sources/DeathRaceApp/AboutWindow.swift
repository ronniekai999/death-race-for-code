import AppKit
import LegendsUI
import SwiftUI

/// About Death Race for Code: the 999, the name and the version over the Legends Never Die
/// night sky. One window, reused.
@MainActor
final class AboutWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: true)
            window.title = "About Death Race for Code"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: AboutView())
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    var body: some View {
        ZStack {
            Legends.ground
            RadialGradient(
                colors: [Legends.plum.opacity(0.6), .clear],
                center: UnitPoint(x: 0.78, y: 0.05),
                startRadius: 0,
                endRadius: 420
            )
            Starfield()
            VStack(spacing: 10) {
                Wordmark999(size: 64)
                Text("Death Race for Code")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Legends.ink)
                Text("Version \(DeathRaceApplication.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(Legends.inkMuted)
                Text("A native terminal for macOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(Legends.inkFaint)
                Tagline()
                    .padding(.top, 14)
            }
            .padding(32)
        }
        .ignoresSafeArea()
        .frame(width: 420, height: 300)
    }
}
