/// Whether some work finishes at all, watched from outside. A dropped reply or a queue with
/// no writer leaves its request waiting for good, and a test that waits for good takes the
/// whole run with it: swift-testing's time limit cannot interrupt a continuation nobody will
/// resume, so the run never completes. This gives up instead, leaving the stuck task
/// suspended — which costs a thread of nothing and lets the test report a failure.
///
/// A copy of SFTPKitTests' own, which is the same lesson learnt in the same way: a process
/// boundary is where replies go missing, and a test suite is where that becomes a hang.
actor Finished {
    private var value = false
    func mark() { value = true }
    var isSet: Bool { value }

    static func within(_ seconds: Double, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        let flag = Finished()
        let task = Task {
            try await work()
            await flag.mark()
        }
        for _ in 0..<Int(seconds * 20) {
            if await flag.isSet { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        return await flag.isSet
    }
}
