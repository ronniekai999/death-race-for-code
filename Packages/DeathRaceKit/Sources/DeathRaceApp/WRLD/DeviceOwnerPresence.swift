import LocalAuthentication
import SSHKit

/// Touch ID before a saved secret leaves the Keychain, or your login password when Touch ID
/// can't be used: a closed lid, or no enrolled finger. macOS words it as "Death Race is
/// trying to <reason>."
public struct DeviceOwnerPresence: UserPresence {
    public init() {}

    /// False when you cancel or fail, and when the question goes away because its ssh ended
    /// (the task is cancelled).
    public func confirm(reason: String) async -> Bool {
        let box = ContextBox()
        return await withTaskCancellationHandler {
            do {
                return try await box.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                return false
            }
        } onCancel: {
            box.context.invalidate()
        }
    }

    /// Whether this Mac can ask at all. Shows nothing.
    public static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}

/// LAContext may be invalidated from any thread, which is all the cancel handler does.
private final class ContextBox: @unchecked Sendable {
    let context = LAContext()
}
