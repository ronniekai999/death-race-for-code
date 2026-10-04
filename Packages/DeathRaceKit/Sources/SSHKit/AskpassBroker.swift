import CPTY
import Foundation
import PTYKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A secret in the Keychain: a host's password, or a key file's passphrase.
public struct SecretRef: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case hostPassword = "password"
        case keyPassphrase = "passphrase"
    }

    public var kind: Kind
    /// A host's id, or a key file's path.
    public var id: String

    public init(_ kind: Kind, _ id: String) {
        self.kind = kind
        self.id = id
    }
}

/// Where saved secrets live: the login Keychain on the Mac, memory in tests.
public protocol SecretStore: Sendable {
    /// Never asks you anything: only whether the item is there.
    func contains(_ ref: SecretRef) -> Bool
    /// May wait on you: macOS asks before an app it doesn't trust reads an item.
    func read(_ ref: SecretRef) async throws -> String?
    func write(_ secret: String, for ref: SecretRef, label: String) throws
    func delete(_ ref: SecretRef) throws
}

/// Touch ID, or the login password when Touch ID can't be used.
public protocol UserPresence: Sendable {
    /// False when you declined, or nobody answered.
    func confirm(reason: String) async -> Bool
}

/// What you answered a question with.
public enum PromptAnswer: Equatable, Sendable {
    /// Typed text; `remember` saves it in the Keychain once the login succeeds.
    case text(String, remember: Bool)
    /// Trust a new host key, or a yes-or-no question.
    case yes
    case cancel
}

/// One question ssh asks, as a sheet shows it.
public struct AskpassQuestion: Sendable {
    public var prompt: AskpassPrompt
    public var context: AskpassContext
    /// Whether a typed answer has a place in the Keychain: the sheet offers "Save in the
    /// Keychain" only then. A one-time code never does.
    public var canRemember: Bool
    /// ssh asked again right after getting the saved secret, so that secret is wrong.
    public var savedSecretFailed: Bool

    public init(prompt: AskpassPrompt, context: AskpassContext, canRemember: Bool, savedSecretFailed: Bool) {
        self.prompt = prompt
        self.context = context
        self.canRemember = canRemember
        self.savedSecretFailed = savedSecretFailed
    }
}

/// Puts ssh's questions to you: sheets on the window on the Mac, scripted in tests.
public protocol PromptPresenter: Sendable {
    func answer(_ question: AskpassQuestion) async -> PromptAnswer
    /// Something ssh shows while it waits (Touch ID for a Secure Enclave key); no answer.
    func notice(_ prompt: AskpassPrompt, for context: AskpassContext) async
}

/// Who is at the other end of the broker's socket.
public protocol PeerInspector: Sendable {
    func credentials(of fd: Int32) -> (pid: Int32, uid: UInt32)?
    func parent(of pid: Int32) -> Int32?
}

public struct SystemPeerInspector: PeerInspector {
    public init() {}

    public func credentials(of fd: Int32) -> (pid: Int32, uid: UInt32)? {
        var pid: pid_t = 0
        var uid: uid_t = 0
        guard cpty_peer_credentials(fd, &pid, &uid) == 0 else { return nil }
        return (Int32(pid), UInt32(uid))
    }

    public func parent(of pid: Int32) -> Int32? {
        let parent = cpty_parent_pid(pid_t(pid))
        return parent > 0 ? Int32(parent) : nil
    }
}

/// What the broker may do for one ssh process tree the app started.
public struct AskpassContext: Sendable {
    /// The host as WRLD names it, for sheets and Touch ID: "prod-api".
    public var hostName: String
    /// Saved passwords the broker may release, each for the one hop ssh names in its prompt.
    public var passwords: [AskpassPrompt.Hop: SecretRef]
    /// Saved passphrases, by key file.
    public var passphrases: [String: SecretRef]
    /// The WRLD name of the host each password belongs to, when it isn't `hostName`: a jump
    /// host's, so Touch ID and the Keychain name the host the password is really for.
    public var hostNames: [SecretRef: String]
    /// False for work you didn't start: it never shows you anything, not even Touch ID for a
    /// saved secret. Any question ends it.
    public var mayAsk: Bool

    public init(
        hostName: String, passwords: [AskpassPrompt.Hop: SecretRef] = [:], passphrases: [String: SecretRef] = [:],
        hostNames: [SecretRef: String] = [:], mayAsk: Bool = true
    ) {
        self.hostName = hostName
        self.passwords = passwords
        self.passphrases = passphrases
        self.hostNames = hostNames
        self.mayAsk = mayAsk
    }

    /// The host `ref` is a password for.
    public func name(for ref: SecretRef) -> String { hostNames[ref] ?? hostName }
}

/// The app's end of `deathrace-askpass`: every question an ssh the app started asks comes
/// here, over a Unix socket in a folder only you can open.
///
/// Before answering anything it checks that the token is one it handed out, that the
/// process asking is yours and descends from the process given that token (at most four
/// levels up: ssh, a ProxyJump hop, the helper), and that nothing else is in flight for it.
///
/// A saved secret is released only for a prompt ssh wrote itself for the hop it belongs to,
/// only after Touch ID, and only once: a second prompt for the same hop means it was wrong,
/// so you're asked instead. Cancelling, or declining Touch ID, ends the attempt; ssh would
/// otherwise send an empty password and ask again.
public final class AskpassBroker: Sendable {
    public let socketPath: String
    private let secrets: any SecretStore
    private let presence: any UserPresence
    private let presenter: any PromptPresenter
    private let peers: any PeerInspector
    /// How long a question waits for the app to learn the pid of the process it gave the
    /// token to: ssh can ask before spawning has returned to the app.
    private let startupWait: Int
    private let state = Locked(State())

    /// How deep below its registered process a peer may be.
    static let deepestPeer = 4
    /// How long a helper may take to send its request.
    static let requestTimeout = 10_000

    struct Registration: Sendable {
        var context: AskpassContext
        var rootPID: Int32?
        var onCancel: @Sendable () -> Void
        /// Saved secrets already sent once.
        var sentSaved: Set<SecretRef> = []
        /// Typed secrets to save once the login succeeds.
        var pendingSaves: [SecretRef: String] = [:]
        var busy = false
        /// Takes down the sheet or Touch ID showing for this registration.
        var cancelQuestion: (@Sendable () -> Void)?
    }

    struct State: Sendable {
        var registrations: [String: Registration] = [:]
        var listener: Int32 = -1
        var wake: (read: Int32, write: Int32) = (-1, -1)
    }

    public init(
        socketPath: String, secrets: any SecretStore, presence: any UserPresence, presenter: any PromptPresenter,
        peers: any PeerInspector = SystemPeerInspector(), startupWaitMilliseconds: Int = 2_000
    ) {
        self.socketPath = socketPath
        self.secrets = secrets
        self.presence = presence
        self.presenter = presenter
        self.peers = peers
        startupWait = startupWaitMilliseconds
    }

    // MARK: - Registrations

    /// A token for one ssh process tree. `onCancel` ends that tree.
    public func register(_ context: AskpassContext, onCancel: @escaping @Sendable () -> Void) -> String {
        let token = AskpassWire.makeToken()
        state.withLock { $0.registrations[token] = Registration(context: context, onCancel: onCancel) }
        return token
    }

    /// The process that was given `token`, once it has started.
    public func attach(token: String, rootPID: Int32) {
        state.withLock { $0.registrations[token]?.rootPID = rootPID }
    }

    /// The login succeeded: saves what you asked to remember.
    public func connected(token: String) {
        let saves = state.withLock { state -> (AskpassContext, [SecretRef: String])? in
            guard let registration = state.registrations[token] else { return nil }
            state.registrations[token]?.pendingSaves = [:]
            return (registration.context, registration.pendingSaves)
        }
        guard let (context, pending) = saves else { return }
        for (ref, secret) in pending {
            try? secrets.write(secret, for: ref, label: label(for: ref, context: context))
        }
    }

    /// Forgets `token`. A sheet or Touch ID still showing for it goes away: its ssh has ended.
    public func unregister(token: String) {
        let registration = state.withLock { $0.registrations.removeValue(forKey: token) }
        registration?.cancelQuestion?()
    }

    func label(for ref: SecretRef, context: AskpassContext) -> String {
        switch ref.kind {
        case .hostPassword: "Password for \(context.name(for: ref))"
        case .keyPassphrase: "Passphrase for \(ref.id)"
        }
    }

    // MARK: - Deciding

    /// The reply to one request, from a peer the socket identified.
    func decide(_ request: AskpassWire.Request, peerPID: Int32, peerUID: UInt32) async -> AskpassWire.Reply {
        guard peerUID == UInt32(getuid()) else { return .cancel }
        guard let (token, registration) = await claim(request.token, peerPID: peerPID) else { return .cancel }
        defer { state.withLock { $0.registrations[token]?.busy = false } }

        let context = registration.context
        // Releasing a saved secret takes Touch ID, and a notice waits on you: both would
        // surprise you from background work, which stops instead.
        guard context.mayAsk else { return cancel(token) }
        let prompt = AskpassPrompt(text: request.prompt, hint: request.hint)
        if case .notice = prompt.kind {
            await presenter.notice(prompt, for: context)
            return .done
        }

        // A saved secret, if this prompt is ssh asking for one it may have.
        var savedRef: SecretRef?
        if let (_, ref) = context.passwords.first(where: { prompt.asksForPassword(of: $0.key) }) {
            savedRef = ref
        } else if case .passphrase(let file) = prompt.kind, let ref = context.passphrases[file] {
            savedRef = ref
        }
        if let ref = savedRef, !registration.sentSaved.contains(ref), secrets.contains(ref) {
            state.withLock { _ = $0.registrations[token]?.sentSaved.insert(ref) }
            let why = reason(for: ref, context: context)
            guard await cancellable(token, { [presence] in await presence.confirm(reason: why) }) == true else {
                return cancel(token)
            }
            if let secret = try? await secrets.read(ref) { return .answer(secret) }
        }

        let question = AskpassQuestion(
            prompt: prompt, context: context, canRemember: savedRef != nil,
            savedSecretFailed: savedRef.map { registration.sentSaved.contains($0) } ?? false)
        switch await cancellable(token, { [presenter] in await presenter.answer(question) }) ?? .cancel {
        case .text(let text, let remember):
            if remember, let ref = savedRef {
                state.withLock { $0.registrations[token]?.pendingSaves[ref] = text }
            }
            return .answer(text)
        case .yes:
            return .answer("yes")
        case .cancel:
            return cancel(token)
        }
    }

    /// Runs `work` as a task that unregistering `token` cancels; nil when `token` was already
    /// gone. A sheet or Touch ID check should end, answering no, once cancelled.
    private func cancellable<T: Sendable>(_ token: String, _ work: @escaping @Sendable () async -> T) async -> T? {
        let task = Task { await work() }
        let registered = state.withLock { state -> Bool in
            guard state.registrations[token] != nil else { return false }
            state.registrations[token]?.cancelQuestion = { task.cancel() }
            return true
        }
        guard registered else {
            task.cancel()
            return nil
        }
        defer { state.withLock { $0.registrations[token]?.cancelQuestion = nil } }
        return await task.value
    }

    /// The registration `requestToken` names, marked busy, if `peerPID` may use it.
    private func claim(_ requestToken: String, peerPID: Int32) async -> (String, Registration)? {
        var waited = 0
        while true {
            let found = state.withLock { state -> (token: String, root: Int32?, busy: Bool)? in
                // Every token is compared, so the time taken says nothing about which matched.
                var match: (String, Registration)?
                for (token, registration) in state.registrations where AskpassWire.sameToken(token, requestToken) {
                    match = (token, registration)
                }
                return match.map { ($0.0, $0.1.rootPID, $0.1.busy) }
            }
            guard let found, !found.busy else { return nil }
            guard let root = found.root else {
                guard waited < startupWait else { return nil }
                try? await Task.sleep(for: .milliseconds(10))
                waited += 10
                continue
            }
            // Walking the process tree reads the system's tables, so it happens unlocked.
            guard isDescendant(peerPID, of: root) else { return nil }
            return state.withLock { state -> (String, Registration)? in
                guard let registration = state.registrations[found.token], !registration.busy else { return nil }
                state.registrations[found.token]?.busy = true
                return (found.token, registration)
            }
        }
    }

    private func reason(for ref: SecretRef, context: AskpassContext) -> String {
        switch ref.kind {
        case .hostPassword: "use the saved password for \(context.name(for: ref))"
        case .keyPassphrase: "use the saved passphrase for \((ref.id as NSString).lastPathComponent)"
        }
    }

    private func cancel(_ token: String) -> AskpassWire.Reply {
        let onCancel = state.withLock { $0.registrations[token]?.onCancel }
        onCancel?()
        return .cancel
    }

    /// Whether `pid` is `root` or below it, at most `deepestPeer` levels down.
    private func isDescendant(_ pid: Int32, of root: Int32) -> Bool {
        var current: Int32? = pid
        for _ in 0...Self.deepestPeer {
            guard let process = current, process > 1 else { return false }
            if process == root { return true }
            current = peers.parent(of: process)
        }
        return false
    }

    // MARK: - The socket

    /// Listens at `socketPath`, in a folder of mode 0700 that this user owns.
    public func start() throws {
        let folder = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try secureFolder(folder)
        let listener = try UnixSocket.listen(at: socketPath)
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else {
            close(listener)
            throw UnixSocket.Failure.system("pipe", errno: errno)
        }
        let (wakeRead, wakeWrite) = (wake[0], wake[1])
        // The pipe mustn't survive into the ssh processes we spawn.
        _ = fcntl(wakeRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(wakeWrite, F_SETFD, FD_CLOEXEC)
        state.withLock {
            $0.listener = listener
            $0.wake = (wakeRead, wakeWrite)
        }
        let thread = Thread { [self] in acceptLoop(listener: listener, wake: wakeRead) }
        thread.name = "Death Race: askpass broker"
        thread.start()
    }

    /// Opens the socket's folder without following a symlink and checks this user owns it and
    /// nobody else can write it, then tightens it to 0700. A folder someone else controls (a
    /// planted symlink, a shared or misconfigured home) could otherwise let another user put
    /// the socket where they receive the prompts and the token.
    private func secureFolder(_ folder: String) throws {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw UnixSocket.Failure.system("open askpass folder", errno: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw UnixSocket.Failure.system("stat askpass folder", errno: errno) }
        guard info.st_uid == getuid() else {
            throw UnixSocket.Failure.system("askpass folder is owned by another user", errno: EPERM)
        }
        _ = fchmod(fd, 0o700)
        guard fstat(fd, &info) == 0, info.st_mode & 0o077 == 0 else {
            throw UnixSocket.Failure.system("askpass folder is open to other users", errno: EPERM)
        }
    }

    /// Stops listening; questions in flight are cancelled by their helpers' ssh.
    public func stop() {
        let wakeWrite = state.withLock { state -> Int32 in
            let fd = state.wake.write
            state.wake.write = -1
            return fd
        }
        guard wakeWrite >= 0 else { return }
        _ = UnixSocket.writeAll(wakeWrite, [1])
        close(wakeWrite)
        unlink(socketPath)
    }

    private func acceptLoop(listener: Int32, wake: Int32) {
        defer {
            close(listener)
            close(wake)
        }
        while true {
            var descriptors = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if descriptors[1].revents != 0 { return }
            guard descriptors[0].revents != 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let thread = Thread { [self] in serve(client) }
            thread.name = "Death Race: askpass question"
            thread.start()
        }
    }

    /// One helper's question: read it, decide, answer, hang up.
    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let (pid, uid) = peers.credentials(of: client),
            let payload = UnixSocket.readFrame(client, timeoutMilliseconds: Self.requestTimeout),
            let request = AskpassWire.decodeRequest(payload)
        else {
            _ = UnixSocket.writeAll(client, AskpassWire.encode(.cancel))
            return
        }
        let reply = Self.waitFor { await self.decide(request, peerPID: pid, peerUID: uid) }
        _ = UnixSocket.writeAll(client, AskpassWire.encode(reply))
    }

    /// Runs `work` and blocks this thread (one of the broker's own, never the main thread
    /// or Swift's shared pool) until it finishes.
    private static func waitFor(_ work: @escaping @Sendable () async -> AskpassWire.Reply) -> AskpassWire.Reply {
        let box = Locked<AskpassWire.Reply?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let reply = await work()
            box.withLock { $0 = reply }
            done.signal()
        }
        done.wait()
        return box.withLock { $0 } ?? .cancel
    }
}

/// The helper's end: one question, one reply.
public enum AskpassClient {
    /// Asks the broker at `socket`. Nil when it can't be reached or answers nonsense. With
    /// `waitForReply` false the question is sent and left (a notice).
    public static func ask(
        socket: String, token: String, prompt: String, hint: String?, waitForReply: Bool = true,
        peers: any PeerInspector = SystemPeerInspector()
    ) -> AskpassWire.Reply? {
        guard let fd = UnixSocket.connect(to: socket) else { return nil }
        defer { close(fd) }
        // Defence in depth: only the broker verifies the helper today, so also confirm the
        // other end is this user before the token is sent — a socket another account planted
        // under our path gets nothing.
        guard peers.credentials(of: fd)?.uid == UInt32(getuid()) else { return nil }
        let request = AskpassWire.Request(token: token, prompt: prompt, hint: hint)
        guard UnixSocket.writeAll(fd, AskpassWire.encode(request)) else { return nil }
        guard waitForReply else { return .done }
        guard let payload = UnixSocket.readFrame(fd, timeoutMilliseconds: nil) else { return nil }
        return AskpassWire.decodeReply(payload)
    }
}
