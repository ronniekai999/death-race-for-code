#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A NULL-terminated array of C strings that outlives a `withCString` scope.
struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[count] = nil
    }

    func deallocate() {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}
