import Foundation
import IPCKit
import PTYKit
import Testing

@testable import SSHKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private let target = AskpassPrompt.Hop(user: "ubuntu", host: "10.0.4.21")
private let jump = AskpassPrompt.Hop(user: "ops", host: "bastion.lan")
private let targetRef = SecretRef(.hostPassword, "h-prod")
private let jumpRef = SecretRef(.hostPassword, "h-bastion")
private let keyFile = "/home/r/.ssh/id_ed25519"
private let keyRef = SecretRef(.keyPassphrase, keyFile)
private let me = UInt32(getuid())

/// The master is 100. Its askpass is 101; 102 is a ProxyJump hop, 103 that hop's askpass, and
/// 104–106 go deeper still. 200 is someone else's.
private let tree = FakePeers(parents: [101: 100, 102: 100, 103: 102, 104: 103, 105: 104, 106: 105, 200: 1])

private let hostKeyPrompt = """
    The authenticity of host 'prod-api (10.0.4.21)' can't be established.
    ED25519 key fingerprint is SHA256:Fx8rQ2Jq0e1Kc9yQh7M3w5S2pVJcQe0P1aB2cD3eF4g.
    This key is not known by any other names.
    Are you sure you want to continue connecting (yes/no/[fingerprint])?
    """

/// A broker with one registration for prod-api (through bastion), started by process 100.
private struct Rig {
    let broker: AskpassBroker
    let secrets: MemorySecretStore
    let presence: ScriptedPresence
    let presenter: ScriptedPresenter
    let cancels: Counter
    let token: String

    init(
        saved: [SecretRef: String] = [:], touchID: Bool = true, answers: [PromptAnswer] = [], mayAsk: Bool = true,
        attached: Bool = true
    ) {
        secrets = MemorySecretStore(saved)
        presence = ScriptedPresence(allows: touchID)
        presenter = ScriptedPresenter(answers)
        broker = AskpassBroker(
            socketPath: "/nonexistent/a.sock", secrets: secrets, presence: presence, presenter: presenter, peers: tree,
            startupWaitMilliseconds: 100)
        let cancels = Counter()
        self.cancels = cancels
        let context = AskpassContext(
            hostName: "prod-api", passwords: [target: targetRef, jump: jumpRef], passphrases: [keyFile: keyRef],
            hostNames: [jumpRef: "bastion"], mayAsk: mayAsk)
        token = broker.register(context, onCancel: { cancels.add() })
        if attached { broker.attach(token: token, rootPID: 100) }
    }

    func ask(
        _ prompt: String, hint: String? = nil, from pid: Int32 = 101, uid: UInt32 = me, token: String? = nil
    ) async -> AskpassWire.Reply {
        await broker.decide(
            AskpassWire.Request(token: token ?? self.token, prompt: prompt, hint: hint), peerPID: pid, peerUID: uid)
    }
}

@Suite("The askpass broker")
struct AskpassBrokerTests {
    @Test func aSavedPasswordGoesToItsOwnHopAfterTouchID() async {
        let rig = Rig(saved: [targetRef: "target-secret", jumpRef: "jump-secret"])
        #expect(await rig.ask("ubuntu@10.0.4.21's password: ") == .answer("target-secret"))
        #expect(await rig.ask("ops@bastion.lan's password: ", from: 103) == .answer("jump-secret"))
        #expect(rig.presence.reasons == ["use the saved password for prod-api", "use the saved password for bastion"])
        #expect(rig.presenter.questions.isEmpty)
    }

    @Test func aPromptForAnotherUserOrHostNeverGetsASavedPassword() async {
        let rig = Rig(saved: [targetRef: "target-secret"], answers: [.cancel, .cancel])
        #expect(await rig.ask("root@10.0.4.21's password: ") == .cancel)
        #expect(await rig.ask("ubuntu@10.0.4.22's password: ") == .cancel)
        #expect(rig.presence.reasons.isEmpty)
        #expect(rig.presenter.questions.map(\.canRemember) == [false, false])
    }

    @Test func aKeyboardInteractivePasswordQuestionUsesTheSavedPassword() async {
        let rig = Rig(saved: [targetRef: "target-secret"])
        #expect(await rig.ask("(ubuntu@10.0.4.21) Password: ") == .answer("target-secret"))
    }

    @Test func aOneTimeCodeIsAlwaysAskedAndNeverSaved() async throws {
        let rig = Rig(saved: [targetRef: "target-secret"], answers: [.text("123456", remember: true)])
        #expect(await rig.ask("(ubuntu@10.0.4.21) Verification code: ") == .answer("123456"))
        #expect(rig.presence.reasons.isEmpty)
        #expect(rig.presenter.questions.first?.canRemember == false)
        rig.broker.connected(token: rig.token)
        #expect(try await rig.secrets.read(targetRef) == "target-secret")
    }

    @Test func askingAgainMeansTheSavedPasswordWasWrong() async throws {
        let rig = Rig(saved: [targetRef: "old"], answers: [.text("new", remember: true)])
        #expect(await rig.ask("ubuntu@10.0.4.21's password: ") == .answer("old"))
        #expect(await rig.ask("ubuntu@10.0.4.21's password: ") == .answer("new"))
        #expect(rig.presence.reasons.count == 1)
        let question = try #require(rig.presenter.questions.first)
        #expect(question.savedSecretFailed)
        #expect(question.canRemember)
        // Replaced only once the login works.
        #expect(try await rig.secrets.read(targetRef) == "old")
        rig.broker.connected(token: rig.token)
        #expect(try await rig.secrets.read(targetRef) == "new")
        #expect(rig.secrets.label(of: targetRef) == "Password for prod-api")
    }

    @Test func aJumpHostsPasswordIsSavedUnderItsOwnName() async throws {
        let rig = Rig(answers: [.text("jump-typed", remember: true)])
        #expect(await rig.ask("ops@bastion.lan's password: ", from: 103) == .answer("jump-typed"))
        rig.broker.connected(token: rig.token)
        #expect(try await rig.secrets.read(jumpRef) == "jump-typed")
        #expect(rig.secrets.label(of: jumpRef) == "Password for bastion")
    }

    @Test func aTypedPasswordIsSavedOnlyWhenAskedAndOnlyAfterTheLogin() async throws {
        let failed = Rig(answers: [.text("typed", remember: true)])
        #expect(await failed.ask("ubuntu@10.0.4.21's password: ") == .answer("typed"))
        #expect(!failed.secrets.contains(targetRef))
        failed.broker.unregister(token: failed.token)
        failed.broker.connected(token: failed.token)
        #expect(!failed.secrets.contains(targetRef))

        let unasked = Rig(answers: [.text("typed", remember: false)])
        _ = await unasked.ask("ubuntu@10.0.4.21's password: ")
        unasked.broker.connected(token: unasked.token)
        #expect(!unasked.secrets.contains(targetRef))

        let saved = Rig(answers: [.text("typed", remember: true)])
        _ = await saved.ask("ubuntu@10.0.4.21's password: ")
        saved.broker.connected(token: saved.token)
        #expect(try await saved.secrets.read(targetRef) == "typed")
    }

    @Test func decliningTouchIDEndsTheAttempt() async {
        let rig = Rig(saved: [targetRef: "target-secret"], touchID: false)
        #expect(await rig.ask("ubuntu@10.0.4.21's password: ") == .cancel)
        #expect(rig.cancels.count == 1)
        #expect(rig.presenter.questions.isEmpty)
    }

    @Test func cancellingTheSheetEndsTheAttempt() async {
        let rig = Rig(answers: [.cancel])
        #expect(await rig.ask("ubuntu@10.0.4.21's password: ") == .cancel)
        #expect(rig.cancels.count == 1)
    }

    @Test func aNewHostKeyIsPutToYouAndTrustAnswersYes() async throws {
        let rig = Rig(answers: [.yes])
        #expect(await rig.ask(hostKeyPrompt) == .answer("yes"))
        let question = try #require(rig.presenter.questions.first)
        guard case .newHostKey(let host, _, let fingerprint) = question.prompt.kind else {
            Issue.record("Not a host key question: \(question.prompt.kind)")
            return
        }
        #expect(host == "prod-api")
        #expect(fingerprint == "SHA256:Fx8rQ2Jq0e1Kc9yQh7M3w5S2pVJcQe0P1aB2cD3eF4g")
        #expect(!question.canRemember)
    }

    @Test func aNoticeIsShownAndNeedsNoAnswer() async {
        let rig = Rig()
        #expect(await rig.ask("Confirm user presence for key ECDSA-SK SHA256:x", hint: "none") == .done)
        #expect(rig.presenter.notices.count == 1)
        #expect(rig.presenter.questions.isEmpty)
        #expect(rig.cancels.count == 0)
    }

    @Test func aSavedPassphraseGoesToItsKeyFileOnly() async {
        let rig = Rig(saved: [keyRef: "phrase"], answers: [.cancel])
        #expect(await rig.ask("Enter passphrase for key '\(keyFile)': ") == .answer("phrase"))
        #expect(rig.presence.reasons == ["use the saved passphrase for id_ed25519"])
        #expect(await rig.ask("Enter passphrase for key '/home/r/.ssh/other': ") == .cancel)
        #expect(rig.presenter.questions.count == 1)
    }

    @Test func backgroundWorkNeverShowsAnything() async {
        let rig = Rig(saved: [targetRef: "target-secret"], mayAsk: false)
        #expect(await rig.ask("ubuntu@10.0.4.21's password: ") == .cancel)
        #expect(rig.presence.reasons.isEmpty)
        #expect(rig.presenter.questions.isEmpty)
        #expect(rig.cancels.count == 1)
        #expect(await rig.ask("Confirm user presence for key ECDSA-SK SHA256:x", hint: "none") == .cancel)
        #expect(rig.presenter.notices.isEmpty)
    }

    @Test func strangersGetNothingAndCantEndTheConnection() async {
        let rig = Rig(saved: [targetRef: "target-secret"])
        let password = "ubuntu@10.0.4.21's password: "
        #expect(await rig.ask(password, token: AskpassWire.makeToken()) == .cancel)
        #expect(await rig.ask(password, uid: me &+ 1) == .cancel)
        #expect(await rig.ask(password, from: 200) == .cancel)
        #expect(await rig.ask(password, from: 1) == .cancel)
        #expect(await rig.ask(password, from: 0) == .cancel)
        #expect(rig.presence.reasons.isEmpty)
        #expect(rig.cancels.count == 0)
    }

    @Test func aPeerMayBeAtMostFourLevelsBelow() async {
        let rig = Rig(answers: [.text("x", remember: false)])
        #expect(await rig.ask("ubuntu@10.0.4.21's password: ", from: 106) == .cancel)
        #expect(rig.presenter.questions.isEmpty)
        #expect(await rig.ask("ubuntu@10.0.4.21's password: ", from: 105) == .answer("x"))
    }

    @Test func oneQuestionAtATimePerToken() async {
        let presenter = GatedPresenter()
        let broker = AskpassBroker(
            socketPath: "/nonexistent/a.sock", secrets: MemorySecretStore(), presence: ScriptedPresence(),
            presenter: presenter, peers: tree)
        let cancels = Counter()
        let token = broker.register(AskpassContext(hostName: "prod-api"), onCancel: { cancels.add() })
        broker.attach(token: token, rootPID: 100)
        let request = AskpassWire.Request(token: token, prompt: "ubuntu@10.0.4.21's password: ", hint: nil)

        let first = Task { await broker.decide(request, peerPID: 101, peerUID: me) }
        #expect(await eventually { presenter.isShowing })
        #expect(await broker.decide(request, peerPID: 101, peerUID: me) == .cancel)
        #expect(cancels.count == 0)
        presenter.answer(with: .text("typed", remember: false))
        #expect(await first.value == .answer("typed"))

        let next = Task { await broker.decide(request, peerPID: 101, peerUID: me) }
        #expect(await eventually { presenter.isShowing })
        presenter.answer(with: .text("again", remember: false))
        #expect(await next.value == .answer("again"))
    }

    @Test func unregisteringTakesDownTheSheetAndAnswersNo() async {
        let presenter = GatedPresenter()
        let broker = AskpassBroker(
            socketPath: "/nonexistent/a.sock", secrets: MemorySecretStore(), presence: ScriptedPresence(),
            presenter: presenter, peers: tree)
        let token = broker.register(AskpassContext(hostName: "prod-api"), onCancel: {})
        broker.attach(token: token, rootPID: 100)
        let request = AskpassWire.Request(token: token, prompt: "ubuntu@10.0.4.21's password: ", hint: nil)
        let asked = Task { await broker.decide(request, peerPID: 101, peerUID: me) }
        #expect(await eventually { presenter.isShowing })
        broker.unregister(token: token)
        #expect(await asked.value == .cancel)
        #expect(!presenter.isShowing)
    }

    @Test func aQuestionAskedBeforeTheAppKnowsThePidWaitsForIt() async {
        let rig = Rig(answers: [.text("typed", remember: false)], attached: false)
        let asked = Task { await rig.ask("ubuntu@10.0.4.21's password: ") }
        try? await Task.sleep(for: .milliseconds(30))
        rig.broker.attach(token: rig.token, rootPID: 100)
        #expect(await asked.value == .answer("typed"))
    }

    @Test func aTokenNeverAttachedOrUnregisteredGetsNothing() async {
        let never = Rig(answers: [.text("typed", remember: false)], attached: false)
        #expect(await never.ask("ubuntu@10.0.4.21's password: ") == .cancel)
        #expect(never.presenter.questions.isEmpty)

        let gone = Rig(answers: [.text("typed", remember: false)])
        gone.broker.unregister(token: gone.token)
        #expect(await gone.ask("ubuntu@10.0.4.21's password: ") == .cancel)
        #expect(gone.presenter.questions.isEmpty)
    }
}

/// `deathrace-askpass` as `swift build` left it, next to the test bundle.
enum BuiltHelper {
    static let path: String? = candidates.first { access($0, X_OK) == 0 }

    /// Where it may be, most likely first.
    static var candidates: [String] {
        var folders: [String] = []
        #if os(macOS)
            // The folder holding the test bundle, found from a class inside it: swift-testing
            // doesn't load the bundle in a way that puts it in `Bundle.allBundles`.
            folders.append(Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().path)
        #else
            folders.append(Bundle.main.bundleURL.path)
        #endif
        // swift build's own folder, beside this package.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        folders.append(package.appendingPathComponent(".build/debug").path)
        return folders.map { $0 + "/deathrace-askpass" }
    }

    static var missing: Comment { "deathrace-askpass wasn't built; looked at \(candidates)" }
}

#if os(macOS)
    private final class TestBundleMarker: NSObject {}
#endif

/// A new private folder with a short path: socket paths must fit in 104 bytes on macOS.
func shortTemporaryFolder() throws -> String {
    let folder = NSTemporaryDirectory() + "wr-" + String(UInt32.random(in: .min ... .max), radix: 16)
    try FileManager.default.createDirectory(
        atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder
}

@Suite("deathrace-askpass and the broker")
struct AskpassHelperTests {
    let folder: String
    let socket: String

    init() throws {
        folder = try shortTemporaryFolder()
        socket = folder + "/run/askpass.sock"
    }

    func helper(_ prompt: String, environment: [String: String]) async throws -> ChildResult {
        let helper = try #require(BuiltHelper.path, BuiltHelper.missing)
        return try await SystemProcessRunner().run(
            Command([helper, prompt], environment: environment, timeoutMilliseconds: patience(10_000)))
    }

    func broker(saved: [SecretRef: String] = [:], presenter: ScriptedPresenter = ScriptedPresenter())
        throws -> AskpassBroker
    {
        let broker = AskpassBroker(
            socketPath: socket, secrets: MemorySecretStore(saved), presence: ScriptedPresence(), presenter: presenter)
        try broker.start()
        return broker
    }

    @Test func theHelperPrintsTheAnswer() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let broker = try broker(saved: [targetRef: "s3cret"])
        defer { broker.stop() }
        let token = broker.register(AskpassContext(hostName: "prod-api", passwords: [target: targetRef]), onCancel: {})
        // The helper is this process's child, as it is ssh's in the app.
        broker.attach(token: token, rootPID: getpid())
        let result = try await helper(
            "ubuntu@10.0.4.21's password: ",
            environment: ["DEATHRACE_ASKPASS_SOCKET": socket, "DEATHRACE_ASKPASS_TOKEN": token])
        #expect(result.outputText == "s3cret\n")
        #expect(result.status == .exited(code: 0))
    }

    @Test func theClientOnlyTrustsABrokerRunAsThisUser() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let broker = try broker(saved: [targetRef: "s3cret"])
        defer { broker.stop() }
        let token = broker.register(AskpassContext(hostName: "prod-api", passwords: [target: targetRef]), onCancel: {})
        broker.attach(token: token, rootPID: getpid())
        let prompt = "ubuntu@10.0.4.21's password: "

        // Our own uid: the client goes ahead and the broker answers.
        let ours = FakePeers(parents: [:], peer: (pid: 100, uid: me))
        #expect(
            AskpassClient.ask(socket: socket, token: token, prompt: prompt, hint: nil, peers: ours) == .answer("s3cret")
        )

        // A broker that looks like another user's: the token is never sent, nothing comes back.
        let stranger = FakePeers(parents: [:], peer: (pid: 100, uid: me &+ 1))
        #expect(AskpassClient.ask(socket: socket, token: token, prompt: prompt, hint: nil, peers: stranger) == nil)
    }

    @Test func aNoticeExitsAtOnceWithNothingPrinted() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let presenter = ScriptedPresenter()
        let broker = try broker(presenter: presenter)
        defer { broker.stop() }
        let token = broker.register(AskpassContext(hostName: "prod-api"), onCancel: {})
        broker.attach(token: token, rootPID: getpid())
        let result = try await helper(
            "Confirm user presence for key ECDSA-SK SHA256:x",
            environment: [
                "DEATHRACE_ASKPASS_SOCKET": socket, "DEATHRACE_ASKPASS_TOKEN": token, "SSH_ASKPASS_PROMPT": "none",
            ])
        #expect(result.output.isEmpty)
        #expect(result.status == .exited(code: 0))
        #expect(presenter.notices.count == 1)
    }

    @Test func aProcessOutsideTheTreeOrWithTheWrongTokenGetsNothing() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let presenter = ScriptedPresenter([.text("typed", remember: false)])
        let broker = try broker(saved: [targetRef: "s3cret"], presenter: presenter)
        defer { broker.stop() }
        let cancels = Counter()
        let token = broker.register(
            AskpassContext(hostName: "prod-api", passwords: [target: targetRef]), onCancel: { cancels.add() })
        // Registered to a sibling of the helper: the helper doesn't descend from it.
        let sibling = try ChildProcess.spawn(
            executable: "/bin/sleep", arguments: ["sleep", "10"], environment: ["PATH": "/usr/bin:/bin"])
        defer {
            sibling.signal(SIGKILL)
            _ = sibling.waitForExit(timeoutMilliseconds: 2_000)
        }
        broker.attach(token: token, rootPID: sibling.pid)

        let outside = try await helper(
            "ubuntu@10.0.4.21's password: ",
            environment: ["DEATHRACE_ASKPASS_SOCKET": socket, "DEATHRACE_ASKPASS_TOKEN": token])
        #expect(outside.output.isEmpty)
        #expect(outside.status == .exited(code: 1))

        let wrongToken = try await helper(
            "ubuntu@10.0.4.21's password: ",
            environment: ["DEATHRACE_ASKPASS_SOCKET": socket, "DEATHRACE_ASKPASS_TOKEN": AskpassWire.makeToken()])
        #expect(wrongToken.output.isEmpty)
        #expect(wrongToken.status == .exited(code: 1))
        #expect(presenter.questions.isEmpty)
        #expect(cancels.count == 0)
    }

    @Test func withoutTheAppNothingIsAnswered() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let unreachable = try await helper(
            "ubuntu@10.0.4.21's password: ",
            environment: ["DEATHRACE_ASKPASS_SOCKET": socket, "DEATHRACE_ASKPASS_TOKEN": AskpassWire.makeToken()])
        #expect(unreachable.status == .exited(code: 1))
        #expect(unreachable.output.isEmpty)
        #expect(unreachable.errorText.contains("didn't answer"))

        let unset = try await helper("ubuntu@10.0.4.21's password: ", environment: [:])
        #expect(unset.status == .exited(code: 1))
        #expect(unset.output.isEmpty)
    }

    @Test func theSocketAndItsFolderAreYoursAlone() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let broker = try broker()
        defer { broker.stop() }
        let socketMode = try #require(FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? Int)
        let folderMode = try #require(
            FileManager.default.attributesOfItem(atPath: folder + "/run")[.posixPermissions] as? Int)
        #expect(socketMode & 0o777 == 0o600)
        #expect(folderMode & 0o777 == 0o700)
    }

    // A symlink where the socket folder should be is refused (O_NOFOLLOW): someone could
    // otherwise redirect the socket to a folder they control and receive the prompts and the
    // token. A plain folder this user owns is tightened to 0700 instead (above), not refused.
    @Test func aSymlinkedFolderIsRefused() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let elsewhere = folder + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder + "/run", withDestinationPath: elsewhere)
        let broker = AskpassBroker(
            socketPath: socket, secrets: MemorySecretStore(), presence: ScriptedPresence(),
            presenter: ScriptedPresenter())
        #expect(throws: (any Error).self) { try broker.start() }
    }

    @Test func stoppingRemovesTheSocket() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let broker = try broker()
        #expect(UnixSocket.accepts(socket))
        broker.stop()
        #expect(!FileManager.default.fileExists(atPath: socket))
    }
}
