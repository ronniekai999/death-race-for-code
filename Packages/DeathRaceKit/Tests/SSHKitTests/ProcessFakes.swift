import Foundation
import PTYKit

@testable import SSHKit

/// Programs that answer from a script: each command line, minus the program, maps to what it
/// prints. Anything unscripted fails, saying so. Every command run is kept.
final class ScriptedRunner: ProcessRunner {
    private let script: [[String]: ChildResult]
    private let ran = Locked<[Command]>([])

    init(_ script: [[String]: ChildResult]) {
        self.script = script
    }

    func run(_ command: Command) async throws -> ChildResult {
        ran.withLock { $0.append(command) }
        return script[Array(command.arguments.dropFirst())]
            ?? ChildResult(
                status: .exited(code: 255), output: [],
                errors: Array("unscripted: \(command.arguments.joined(separator: " "))\n".utf8), timedOut: false)
    }

    var commands: [Command] { ran.withLock { $0 } }
}

extension ChildResult {
    static func printing(_ output: String) -> ChildResult {
        ChildResult(status: .exited(code: 0), output: Array(output.utf8), errors: [], timedOut: false)
    }

    static func failing(_ errors: String) -> ChildResult {
        ChildResult(status: .exited(code: 255), output: [], errors: Array(errors.utf8), timedOut: false)
    }
}
