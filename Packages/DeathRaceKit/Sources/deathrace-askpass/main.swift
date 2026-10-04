// deathrace-askpass: the SSH_ASKPASS of every ssh Death Race starts.
//
// ssh runs it with its prompt as the only argument and SSH_ASKPASS_PROMPT as a hint
// ("confirm", "none", or unset), and reads the answer from its output; exiting 1 means no
// answer, which ssh treats as cancelled. The question goes to the app's broker over the
// socket in DEATHRACE_ASKPASS_SOCKET, with the token from DEATHRACE_ASKPASS_TOKEN. There is no
// terminal to fall back to: ssh masters have none, so without the app nothing is answered.

import SSHKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

func variable(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    let text = String(cString: value)
    return text.isEmpty ? nil : text
}

/// Writes all of `text` to descriptor `fd`: 1 for the answer, 2 for ssh's log.
func say(_ text: String, to fd: Int32) {
    var bytes = Array(text.utf8)[...]
    while !bytes.isEmpty {
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return }
        bytes = bytes.dropFirst(written)
    }
}

guard let socket = variable("DEATHRACE_ASKPASS_SOCKET"), let token = variable("DEATHRACE_ASKPASS_TOKEN") else {
    say("deathrace-askpass: run by Death Race only.\n", to: 2)
    exit(1)
}
let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

switch AskpassClient.ask(socket: socket, token: token, prompt: prompt, hint: variable("SSH_ASKPASS_PROMPT")) {
case .answer(let text):
    say(text + "\n", to: 1)
    exit(0)
case .done:
    exit(0)
case .cancel:
    exit(1)
case nil:
    say("deathrace-askpass: Death Race didn't answer.\n", to: 2)
    exit(1)
}
