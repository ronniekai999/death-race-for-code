import Foundation
import PTYKit

/// A program to run to the end.
public struct Command: Equatable, Sendable {
    /// `argv`; `arguments[0]` is the program's full path.
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var input: [UInt8]
    public var timeoutMilliseconds: Int

    public init(
        _ arguments: [String], environment: [String: String], workingDirectory: String? = nil, input: [UInt8] = [],
        timeoutMilliseconds: Int = 10_000
    ) {
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.input = input
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

/// Running programs to the end: `ssh -G`, `ssh -O`, `sc_auth`, `ssh-keygen`. The real one
/// runs them; tests and previews use a fake with answers prepared.
public protocol ProcessRunner: Sendable {
    func run(_ command: Command) async throws -> ChildResult
}

/// Runs each program on a thread of its own (`ChildProcess.run` blocks), so neither the main
/// thread nor Swift's shared pool waits on a program.
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ command: Command) async throws -> ChildResult {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    let result = try ChildProcess.run(
                        executable: command.arguments.first ?? "", arguments: command.arguments,
                        environment: command.environment, workingDirectory: command.workingDirectory,
                        input: command.input, timeoutMilliseconds: command.timeoutMilliseconds)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "Death Race: \((command.arguments.first ?? "").split(separator: "/").last ?? "")"
            thread.start()
        }
    }
}
