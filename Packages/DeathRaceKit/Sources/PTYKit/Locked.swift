#if canImport(Darwin)
    import Synchronization
#elseif canImport(Glibc)
    import Glibc
#endif

/// A value behind a lock, for state threads share: a session's mailbox, the askpass
/// broker's registrations, the masters ssh runs for the app.
///
/// On Apple platforms this is Synchronization's `Mutex`, an `os_unfair_lock`: a main thread
/// waiting on it lends its priority to a utility-QoS session thread holding it.
///
/// On Linux it is a pthread mutex, on purpose. `Mutex` hands a contended lock over there
/// through a priority-inheritance futex inside the Synchronization library, where the Thread
/// Sanitizer cannot see it, so CI would report every contended hand-off as a race. pthread
/// mutexes are what the sanitizer understands. Linux runs only tests and tools, so nothing is
/// lost.
public final class Locked<Value>: @unchecked Sendable {
    #if canImport(Darwin)
        private let mutex: Mutex<Value>

        public init(_ value: sending Value) {
            mutex = Mutex(value)
        }

        /// The same shape as `Mutex.withLock`, which it forwards to.
        public func withLock<Result: ~Copyable, E: Error>(
            _ body: (inout sending Value) throws(E) -> sending Result
        ) throws(E) -> sending Result {
            try mutex.withLock(body)
        }
    #else
        // Heap-allocated: a pthread mutex must not move once initialized.
        private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        private var value: Value

        public init(_ value: Value) {
            self.value = value
            pthread_mutex_init(mutex, nil)
        }

        deinit {
            pthread_mutex_destroy(mutex)
            mutex.deallocate()
        }

        public func withLock<Result, E: Error>(_ body: (inout Value) throws(E) -> Result) throws(E) -> Result {
            pthread_mutex_lock(mutex)
            defer { pthread_mutex_unlock(mutex) }
            return try body(&value)
        }
    #endif
}
