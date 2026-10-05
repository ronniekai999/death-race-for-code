import Foundation
import IPCKit
import PTYKit

@testable import SSHKit

/// Saved secrets in memory, as the Keychain would keep them.
final class MemorySecretStore: SecretStore {
    private let items: Locked<[SecretRef: (secret: String, label: String)]>

    init(_ secrets: [SecretRef: String] = [:]) {
        items = Locked(secrets.mapValues { ($0, "") })
    }

    func contains(_ ref: SecretRef) -> Bool { items.withLock { $0[ref] != nil } }
    func read(_ ref: SecretRef) async throws -> String? { items.withLock { $0[ref]?.secret } }
    func write(_ secret: String, for ref: SecretRef, label: String) throws {
        items.withLock { $0[ref] = (secret, label) }
    }
    func delete(_ ref: SecretRef) throws { _ = items.withLock { $0.removeValue(forKey: ref) } }

    func label(of ref: SecretRef) -> String? { items.withLock { $0[ref]?.label } }
}

/// Touch ID that always answers the same, and remembers why it was asked.
final class ScriptedPresence: UserPresence {
    let allows: Bool
    private let asked = Locked<[String]>([])

    init(allows: Bool = true) { self.allows = allows }

    func confirm(reason: String) async -> Bool {
        asked.withLock { $0.append(reason) }
        return allows
    }

    var reasons: [String] { asked.withLock { $0 } }
}

/// Sheets answered from a script, in order (cancel once it runs out). Every question and
/// notice is kept.
final class ScriptedPresenter: PromptPresenter {
    private let state: Locked<(answers: [PromptAnswer], questions: [AskpassQuestion], notices: [AskpassPrompt])>

    init(_ answers: [PromptAnswer] = []) {
        state = Locked((answers, [], []))
    }

    func answer(_ question: AskpassQuestion) async -> PromptAnswer {
        state.withLock { state in
            state.questions.append(question)
            return state.answers.isEmpty ? .cancel : state.answers.removeFirst()
        }
    }

    func notice(_ prompt: AskpassPrompt, for context: AskpassContext) async {
        state.withLock { $0.notices.append(prompt) }
    }

    var questions: [AskpassQuestion] { state.withLock { $0.questions } }
    var notices: [AskpassPrompt] { state.withLock { $0.notices } }
}

/// A sheet that stays up until the test answers it, or its question is cancelled.
final class GatedPresenter: PromptPresenter {
    private let waiting = Locked<CheckedContinuation<PromptAnswer, Never>?>(nil)

    func answer(_ question: AskpassQuestion) async -> PromptAnswer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting.withLock { $0 = continuation }
                // Cancelled before the sheet went up.
                if Task.isCancelled { answer(with: .cancel) }
            }
        } onCancel: {
            answer(with: .cancel)
        }
    }

    func notice(_ prompt: AskpassPrompt, for context: AskpassContext) async {}

    var isShowing: Bool { waiting.withLock { $0 != nil } }

    func answer(with answer: PromptAnswer) {
        let continuation = waiting.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(returning: answer)
    }
}

/// A process tree of the test's making. `peer` is what `credentials(of:)` reports for any
/// socket — nil unless a test sets it, which lets the askpass client's peer-uid check be
/// driven without a second account.
struct FakePeers: PeerInspector {
    var parents: [Int32: Int32]
    var peer: (pid: Int32, uid: UInt32)?

    init(parents: [Int32: Int32], peer: (pid: Int32, uid: UInt32)? = nil) {
        self.parents = parents
        self.peer = peer
    }

    func credentials(of fd: Int32) -> (pid: Int32, uid: UInt32)? { peer }
    func parent(of pid: Int32) -> Int32? { parents[pid] }
}

/// Counts calls from any thread.
final class Counter: Sendable {
    private let value = Locked(0)

    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

/// Waits, a few milliseconds at a time, until `condition` holds; false if it never does.
func eventually(within milliseconds: Int = 5_000, _ condition: () -> Bool) async -> Bool {
    var waited = 0
    while !condition() {
        guard waited < milliseconds else { return false }
        try? await Task.sleep(for: .milliseconds(5))
        waited += 5
    }
    return true
}
