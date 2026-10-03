// vthost: a headless host for the Death Race terminal engine.
//
// Phase 0 ships `smoke`; `run`, `replay`, `dump`, `bench` and the esctest harness arrive
// with the engine in Phase 1.

import PTYKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

func usage() -> Never {
    print(
        """
        usage: vthost <command>

          smoke    spawn /bin/sh on a pseudo-terminal, run a command, check the output
          version  print the version
        """)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "smoke":
    do {
        let launch = ShellLaunch(
            executable: "/bin/sh",
            arguments: ["sh"],
            environment: ShellLaunch.terminalEnvironment(
                inheriting: ShellLaunch.processEnvironment(), appVersion: "0.1.0")
        )
        let transcript = try SmokeTest.run(launch)
        print("smoke test passed")
        if arguments.contains("--verbose") { print(transcript) }
    } catch {
        print("smoke test failed: \(error)")
        exit(1)
    }
case "version":
    print("vthost 0.1.0")
default:
    usage()
}
