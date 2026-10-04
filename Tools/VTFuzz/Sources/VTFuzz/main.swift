// SwiftPM gives every executable its own `main`, so libFuzzer's never runs. libFuzzer's
// driver is called instead, the way it supports programs that have their own main.

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@_silgen_name("LLVMFuzzerRunDriver")
func runFuzzerDriver(
    _ argc: UnsafeMutablePointer<CInt>,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>>,
    _ callback: @convention(c) (UnsafePointer<UInt8>?, Int) -> CInt
) -> CInt

var argc = CommandLine.argc
var argv = CommandLine.unsafeArgv
let status = runFuzzerDriver(&argc, &argv) { data, size in
    guard let data else { return 0 }
    return fuzz(data, size)
}
exit(status)
