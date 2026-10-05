import IPCKit
import SessionKit
import Testing

@testable import SessionIPC

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite("Where a session belonged")
struct SessionPlacementTests {
    @Test("it comes back as it went")
    func roundTrip() {
        let places = [
            SessionPlacement(window: 0, tab: 0, slot: 0, title: ""),
            SessionPlacement(window: 2, tab: 5, slot: 3, title: "zsh · ~/code"),
            SessionPlacement(window: 999, tab: 999, slot: 999, title: String(repeating: "x", count: 500)),
        ]
        for place in places {
            let back = SessionPlacement.decode(place.encode())
            #expect(back?.window == place.window)
            #expect(back?.tab == place.tab)
            #expect(back?.slot == place.slot)
            // A title is cut to something a tab could show, so a long one is not round-tripped
            // whole — and that is the only field this is true of.
            #expect(back?.title == String(place.title.prefix(200)))
        }
    }

    /// A daemon an older or newer app left running holds notes this build cannot read. Its
    /// sessions are still perfectly usable; they just start in a new window.
    @Test("bytes it does not understand are nothing, not a crash")
    func strangeBytes() {
        #expect(SessionPlacement.decode([]) == nil)
        #expect(SessionPlacement.decode([9, 9, 9]) == nil)
        #expect(SessionPlacement.decode(Array("pane=0".utf8)) == nil)
        // The right shape with a trailing byte is still not the right shape.
        #expect(SessionPlacement.decode(SessionPlacement(window: 1, tab: 1, slot: 1, title: "x").encode() + [0]) == nil)
    }

    @Test("numbers no window could have are refused")
    func absurdNumbers() {
        var w = ByteWriterProbe()
        #expect(SessionPlacement.decode(w.absurd()) == nil)
    }
}

/// Builds a placement with a window number out of any range, without going through the
/// encoder that would never write one.
private struct ByteWriterProbe {
    mutating func absurd() -> [UInt8] {
        var bytes: [UInt8] = [1]
        for _ in 0..<3 { bytes += [0xFF, 0xFF, 0xFF, 0xFF] }
        bytes += [0, 0, 0, 0]
        return bytes
    }
}

@Suite("Choosing where sessions run")
struct LegendsChoiceTests {
    @Test("turned off is not a failure, and says nothing")
    func turnedOff() {
        let choice = Legends.choose(
            wanted: false, paths: DaemonHost.Paths(socket: "/nowhere/s.sock", lock: "/nowhere/s.lock"),
            launcher: NothingLauncher())
        guard case .inProcess(let because) = choice else {
            Issue.record("it used a daemon it was told not to")
            return
        }
        #expect(because == nil)
    }

    /// A terminal that will not open because a daemon would not start is worse than one whose
    /// sessions do not outlive it. Every way this goes wrong has to end in a working pane.
    @Test("a daemon that cannot be reached falls back and says why")
    func itFallsBack() {
        let choice = Legends.choose(
            wanted: true,
            paths: DaemonHost.Paths(socket: "/nonexistent-legends/s.sock", lock: "/nonexistent-legends/s.lock"),
            launcher: NothingLauncher(), deadlineMilliseconds: 300)
        guard case .inProcess(let because) = choice else {
            Issue.record("it claimed a daemon that is not there")
            return
        }
        #expect(because?.contains("will not outlive") == true, "\(because ?? "nothing")")
    }

    @Test("every reason has a sentence, and none of them is empty")
    func everyReasonSpeaks() {
        let reasons: [SessionHostError] = [
            .unreachable("x"), .incompatible(ours: 1...1, theirs: 2...2, build: "older"),
            .atCapacity(limit: 64), .unknownSession(SessionID(1)), .alreadyAttached(SessionID(1)),
            .refused("it said no"), .start("the shell would not start"),
        ]
        for reason in reasons {
            let sentence = Legends.sentence(for: reason)
            #expect(!sentence.isEmpty, "\(reason)")
            #expect(sentence.hasSuffix("."), "\(sentence)")
        }
    }
}

@Suite("What to say about kept sessions")
struct LegendsWordingTests {
    /// The wording docs/NAMING.md settled on, counted properly.
    @Test("nothing kept says nothing, and one is not plural")
    func counting() {
        #expect(Legends.sentence(kept: 0).isEmpty)
        #expect(Legends.sentence(kept: 1) == "1 session kept running while the app was closed.")
        #expect(Legends.sentence(kept: 3) == "3 sessions kept running while the app was closed.")
    }

    /// With everything about to be kept there is nothing to ask about, which is the point:
    /// quitting a window of local shells should be quiet.
    @Test("quitting asks only about what will not be kept")
    func askingToQuit() {
        #expect(Legends.quitting(keeping: 3, ending: []) == nil)
        #expect(Legends.quitting(keeping: 0, ending: []) == nil)
        #expect(Legends.quitting(keeping: 0, ending: ["vim"]) == "vim is still running. Quit anyway?")
        #expect(
            Legends.quitting(keeping: 0, ending: ["vim", "make"]) == "vim and make are still running. Quit anyway?")
        #expect(
            Legends.quitting(keeping: 2, ending: ["vim"])
                == "vim is still running, and 2 sessions will keep running. Quit anyway?")
        #expect(
            Legends.quitting(keeping: 1, ending: ["vim", "make", "htop"])
                == "vim, make and htop are still running, and 1 session will keep running. Quit anyway?")
    }

    @Test("a list reads as a sentence, not as a comma-separated field")
    func listing() {
        #expect(Legends.list([]).isEmpty)
        #expect(Legends.list(["one"]) == "one")
        #expect(Legends.list(["one", "two"]) == "one and two")
        #expect(Legends.list(["one", "two", "three"]) == "one, two and three")
    }
}

@Suite("Who may speak to the daemon")
struct PeerPolicyTests {
    /// A socket to ourselves is this user by definition, which is what `sameUser` asks.
    @Test("this user is accepted")
    func thisUser() throws {
        let pair = try socketPair()
        defer {
            closeDescriptor(pair.0)
            closeDescriptor(pair.1)
        }
        #expect(PeerPolicy.sameUser.accepts(pair.0))
        #expect(PeerPolicy.sameUser.accepts(pair.1))
    }

    /// Asked for a check it cannot make, a build refuses everyone rather than returning true
    /// and leaving a reader of the code to assume the check happened.
    @Test("a check this machine cannot make refuses rather than passes")
    func noQuietYes() throws {
        let pair = try socketPair()
        defer {
            closeDescriptor(pair.0)
            closeDescriptor(pair.1)
        }
        let pinned = PeerPolicy.code(requirement: "identifier \"nothing\" and anchor apple generic")
        #if os(macOS)
            // A requirement nothing satisfies, so still false — for the right reason.
            #expect(!pinned.accepts(pair.0))
        #else
            #expect(!pinned.accepts(pair.0), "it claimed to have checked a signature")
        #endif
    }

    @Test("a descriptor that is not a socket is nobody")
    func notASocket() {
        #expect(!PeerPolicy.sameUser.accepts(-1))
    }

    /// Where there is no signature to pin, the strongest check is the weakest one — and the
    /// caller is meant to say so, which `legendsd` does.
    @Test("the strongest check is only this user where nothing can be pinned")
    func theStrongest() {
        let policy = PeerPolicy.strongest(for: "local.deathraceforcode.DeathRace")
        #if os(macOS)
            _ = policy  // depends on how this build was signed
        #else
            #expect(policy == .sameUser)
            #expect(policy.isOnlySameUser)
        #endif
    }
}

/// A connected pair, for asking about a peer that is certainly us.
private func socketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    #if canImport(Darwin)
        let kind = SOCK_STREAM
    #else
        let kind = Int32(SOCK_STREAM.rawValue)
    #endif
    #expect(socketpair(AF_UNIX, kind, 0, &fds) == 0)
    return (fds[0], fds[1])
}
