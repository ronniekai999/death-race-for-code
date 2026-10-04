#if DEBUG
    import AppKit
    import ServiceManagement

    /// The legendsd spike's Debug menu items (docs/SPIKE.md). Temporary, like the spike: it
    /// goes once the verdict is in docs/ARCHITECTURE.md.
    @MainActor
    enum Spike {
        static let agentPlist = "local.deathraceforcode.legendsd-spike.plist"
        /// The probe started from the menu, kept until it ends.
        private static var probe: Process?

        /// The probe as a child of the app, the way shells run today: the baseline.
        static func runProbe() {
            guard let helper = Bundle.main.url(forAuxiliaryExecutable: "legendsd-spike") else {
                return tell(
                    "The spike is not in this build", "Build the app with SPIKE=1 CONFIG=debug scripts/bundle.sh.")
            }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--probe", "--stay", "0"]
            do {
                try process.run()
                probe = process
                tell(
                    "The probe is running",
                    "Answer the privacy prompts as docs/SPIKE.md says. The results go to ~/Library/Logs/DeathRace.")
            } catch {
                tell("The probe did not start", "\(error)")
            }
        }

        static func registerAgent() {
            let agent = SMAppService.agent(plistName: agentPlist)
            do {
                try agent.register()
                tell(
                    "The spike agent is registered",
                    "Status: \(describe(agent.status)). If macOS asks, approve it in System Settings › General › Login Items & Extensions, then start it with the launchctl command in docs/SPIKE.md."
                )
            } catch {
                tell(
                    "The spike agent was not registered",
                    "\(error.localizedDescription) Status: \(describe(agent.status)).")
            }
        }

        static func unregisterAgent() {
            let agent = SMAppService.agent(plistName: agentPlist)
            do {
                try agent.unregister()
                tell("The spike agent is unregistered", "Status: \(describe(agent.status)).")
            } catch {
                tell("The spike agent was not unregistered", error.localizedDescription)
            }
        }

        private static func describe(_ status: SMAppService.Status) -> String {
            switch status {
            case .notRegistered: "not registered"
            case .enabled: "enabled"
            case .requiresApproval: "waiting for approval in Login Items & Extensions"
            case .notFound: "not found: is the plist in Contents/Library/LaunchAgents?"
            @unknown default: "unknown (\(status.rawValue))"
            }
        }

        private static func tell(_ title: String, _ message: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
        }
    }

    extension AppDelegate {
        @objc func runSpikeProbe(_ sender: Any?) { Spike.runProbe() }
        @objc func registerSpikeAgent(_ sender: Any?) { Spike.registerAgent() }
        @objc func unregisterSpikeAgent(_ sender: Any?) { Spike.unregisterAgent() }
    }
#endif
