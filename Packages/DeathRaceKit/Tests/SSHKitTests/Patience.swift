#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Whether the Thread Sanitizer's runtime is in this binary, asked by looking for a symbol
/// only it defines. Inside a function, so no pointer becomes a global of its own.
private func threadSanitizerIsLoaded() -> Bool {
    #if canImport(Darwin)
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
    #else
        return dlsym(nil, "__tsan_init") != nil
    #endif
}

/// Whether this run is under the Thread Sanitizer.
///
/// Swift has no compile-time flag for it, and the sanitizer makes everything several times
/// slower — so a test that asserts "this finished quickly" fails there for the cost of the
/// instrumentation rather than for anything being wrong. CI runs the whole suite under it, so
/// a budget that is merely tight without it is a red build now and then with it.
let underThreadSanitizer: Bool = threadSanitizerIsLoaded()

/// `milliseconds`, given room when the Thread Sanitizer is watching.
///
/// Ten times, not the four SessionIPC's copy gives its daemon's timings: under the sanitizer
/// the whole suite starts at once, so these tests' clocks also count their turn on a few cores.
/// A green CI run had the askpass and master tests at 31 seconds against 40, and a slower runner
/// took them to 46 and failed. Every use here is a guard against a hang, so room costs nothing.
func patience(_ milliseconds: Int) -> Int {
    underThreadSanitizer ? milliseconds * 10 : milliseconds
}
