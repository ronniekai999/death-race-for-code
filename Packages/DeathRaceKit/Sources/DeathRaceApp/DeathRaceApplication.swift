import AppKit
import LegendsUI
import PTYKit
import SwiftUI

/// Death Race for Code.
///
/// Phase 0 shows a first-lap window that proves the pieces are wired: the Legends Never Die
/// look, and a login shell running on our own pseudo-terminal. The terminal surface replaces
/// it in Phase 2.
public struct DeathRaceApplication: App {
    public nonisolated static let version = "0.1.0"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        WindowGroup("Death Race for Code") {
            FirstLapView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 880, height: 560)
    }
}

/// A SwiftPM executable is not a `.app` bundle, so `swift run` launches it with the accessory
/// activation policy: the window draws but never becomes key and drops every keystroke.
/// Promoting the process fixes `swift run`; inside the bundled app these calls are no-ops.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct FirstLapView: View {
    private enum ShellCheck: Equatable {
        case checking
        case ready(String)
        case failed(String)
    }

    @State private var shellCheck: ShellCheck = .checking

    var body: some View {
        ZStack {
            Legends.ground
            RadialGradient(
                colors: [Legends.plum.opacity(0.6), .clear],
                center: UnitPoint(x: 0.78, y: 0.05),
                startRadius: 0,
                endRadius: 620
            )
            Starfield()

            VStack(spacing: 22) {
                Wordmark999(size: 76)
                VStack(spacing: 6) {
                    Text("Death Race for Code")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Legends.ink)
                    Text("The engine is on the way. This window becomes your terminal in Phase 2.")
                        .font(.system(size: 13))
                        .foregroundStyle(Legends.inkMuted)
                }
                shellCard
                Tagline()
            }
            .padding(40)
        }
        .ignoresSafeArea()
        .frame(minWidth: 640, minHeight: 440)
        .task { await checkShell() }
    }

    private var shellCard: some View {
        HStack(spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text("Login shell on a pseudo-terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Legends.ink)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Legends.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 420)
        .neonBorder(cornerRadius: Legends.Radius.card)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 9, height: 9)
            .shadow(color: dotColor.opacity(0.6), radius: 6)
            .accessibilityHidden(true)
    }

    private var dotColor: Color {
        switch shellCheck {
        case .checking: Legends.inkFaint
        case .ready: Legends.cyan
        case .failed: Legends.danger
        }
    }

    private var statusLine: String {
        switch shellCheck {
        case .checking: "Checking…"
        case .ready(let shell): "Ready: \(shell) answered in its own session"
        case .failed(let reason): "Did not start: \(reason)"
        }
    }

    private func checkShell() async {
        let launch = ShellLaunch.loginShell(appVersion: DeathRaceApplication.version)
        let outcome: Result<String, any Error> = await Task.detached(priority: .userInitiated) {
            Result { try SmokeTest.run(launch) }
        }.value
        switch outcome {
        case .success: shellCheck = .ready(launch.executable)
        case .failure(let error):
            shellCheck = .failed(
                String(describing: error).split(separator: "\n").first.map(String.init) ?? "unknown error")
        }
    }
}

/// `DeathRace --smoke-test`: the headless end-to-end check macOS CI runs against the bundled
/// app. Uses `zsh -f` so no rc file can change the outcome.
public enum DeathRaceSmokeTest {
    public static func run() -> Int32 {
        let launch = ShellLaunch(
            executable: "/bin/zsh",
            arguments: ["zsh", "-f"],
            environment: ShellLaunch.terminalEnvironment(
                inheriting: ShellLaunch.processEnvironment(),
                appVersion: DeathRaceApplication.version
            )
        )
        do {
            try SmokeTest.run(launch)
            print("Death Race \(DeathRaceApplication.version): smoke test passed")
            return 0
        } catch {
            print("Death Race \(DeathRaceApplication.version): smoke test failed\n\(error)")
            return 1
        }
    }
}
