import Testing
import Vault

@testable import SSHKit

@Suite("ssh's command lines")
struct SSHCommandTests {
    @Test func theMasterStaysInTheForegroundAndSaysWhenItsReady() {
        #expect(
            SSHCommand.master(alias: "deathrace-prod-api", config: "/r/.deathrace/ssh_config", readyMarker: "a1b2")
                == [
                    "/usr/bin/ssh", "-F", "/r/.deathrace/ssh_config", "-M", "-N",
                    "-o", "ControlPersist=no",
                    "-o", "PermitLocalCommand=yes",
                    "-o", "LocalCommand=echo a1b2",
                    "deathrace-prod-api",
                ])
    }

    @Test func sessionsGoThroughTheMasterOrAroundIt() {
        #expect(SSHCommand.session(alias: "nas-999", config: "/c") == ["/usr/bin/ssh", "-F", "/c", "nas-999"])
        #expect(
            SSHCommand.plainSession(alias: "nas-999", config: "/c")
                == ["/usr/bin/ssh", "-F", "/c", "-o", "ControlPath=none", "nas-999"])
        #expect(SSHCommand.effectiveConfig(alias: "a", config: "/c") == ["/usr/bin/ssh", "-F", "/c", "-G", "a"])
        #expect(
            SSHCommand.remote(alias: "a", config: "/c", command: "cat /etc/os-release")
                == ["/usr/bin/ssh", "-F", "/c", "-T", "-o", "BatchMode=yes", "a", "cat /etc/os-release"])
    }

    @Test func controlRequestsReadNoConfig() throws {
        let local = try TunnelSpec.parse(kind: .local, listen: "5432", forwardTo: "db:5432")
        #expect(
            SSHCommand.control(.forward(local), socket: "/s")
                == ["/usr/bin/ssh", "-F", "none", "-S", "/s", "-O", "forward", "-L", "5432:db:5432", "x"])
        #expect(
            SSHCommand.control(.cancel(TunnelSpec(kind: .dynamic, listenPort: 1080)), socket: "/s")
                == ["/usr/bin/ssh", "-F", "none", "-S", "/s", "-O", "cancel", "-D", "1080", "x"])
        #expect(
            SSHCommand.control(.check, socket: "/s") == ["/usr/bin/ssh", "-F", "none", "-S", "/s", "-O", "check", "x"])
        #expect(
            SSHCommand.control(.exit, socket: "/s") == ["/usr/bin/ssh", "-F", "none", "-S", "/s", "-O", "exit", "x"])
    }
}

@Suite("Askpass prompts")
struct AskpassPromptTests {
    typealias Hop = AskpassPrompt.Hop

    @Test func passwordAuthentication() {
        let prompt = AskpassPrompt(text: "ubuntu@10.0.4.21's password: ")
        #expect(prompt.kind == .password(Hop(user: "ubuntu", host: "10.0.4.21")))
        #expect(prompt.isSecret)
        #expect(prompt.asksForPassword(of: Hop(user: "ubuntu", host: "10.0.4.21")))
        // The jump host's password is never the target's.
        #expect(!prompt.asksForPassword(of: Hop(user: "ops", host: "bastion.lan")))
        #expect(!prompt.asksForPassword(of: Hop(user: "root", host: "10.0.4.21")))
    }

    @Test func aUserNameMayHoldAnAt() {
        let prompt = AskpassPrompt(text: "me@corp.example@10.0.0.1's password: ")
        #expect(prompt.kind == .password(Hop(user: "me@corp.example", host: "10.0.0.1")))
    }

    @Test func keyboardInteractiveQuestions() {
        let password = AskpassPrompt(text: "(ubuntu@10.0.4.21) Password: ")
        #expect(password.kind == .keyboardInteractive(Hop(user: "ubuntu", host: "10.0.4.21"), question: "Password: "))
        #expect(password.asksForPassword(of: Hop(user: "ubuntu", host: "10.0.4.21")))
        // A one-time code is never answered from the Keychain.
        let code = AskpassPrompt(text: "(ubuntu@10.0.4.21) Verification code: ")
        #expect(code.isSecret)
        #expect(!code.asksForPassword(of: Hop(user: "ubuntu", host: "10.0.4.21")))
    }

    @Test func olderSshCutLongNames() {
        let user = String(repeating: "u", count: 40)
        let host = String(repeating: "h", count: 150) + ".example"
        let prompt = AskpassPrompt(text: "\(user.prefix(30))@\(host.prefix(128))'s password: ")
        #expect(prompt.asksForPassword(of: Hop(user: user, host: host)))
        #expect(!prompt.asksForPassword(of: Hop(user: String(user.prefix(30)) + "x", host: "other")))
        // A short name must match exactly.
        #expect(!AskpassPrompt(text: "ub@h's password: ").asksForPassword(of: Hop(user: "ubuntu", host: "h")))
    }

    @Test func passwordChangesArentLogins() {
        for text in ["Enter ubuntu@h's old password: ", "Retype ubuntu@h's new password: "] {
            #expect(!AskpassPrompt(text: text).asksForPassword(of: Hop(user: "ubuntu", host: "h")), "\(text)")
        }
    }

    @Test func passphrasesAndPINs() {
        let passphrase = AskpassPrompt(text: "Enter passphrase for key '/Users/r/.ssh/id_ed25519': ")
        #expect(passphrase.kind == .passphrase(keyFile: "/Users/r/.ssh/id_ed25519"))
        #expect(passphrase.asksForPassphrase(of: "/Users/r/.ssh/id_ed25519"))
        #expect(!passphrase.asksForPassphrase(of: "/Users/r/.ssh/id_rsa"))
        #expect(AskpassPrompt(text: "Enter PIN for authenticator: ").kind == .pin)
        #expect(AskpassPrompt(text: "Enter PIN for ECDSA-SK key /k: ").kind == .pin)
    }

    @Test func aNewHostKey() {
        let text = """
            The authenticity of host 'prod-api (10.0.4.21)' can't be established.
            ED25519 key fingerprint is SHA256:Fx8rQ2Jq0e1Kc9yQh7M3w5S2pVJcQe0P1aB2cD3eF4g.
            This key is not known by any other names.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?
            """
        let prompt = AskpassPrompt(text: text)
        #expect(
            prompt.kind
                == .newHostKey(
                    host: "prod-api", keyType: "ED25519",
                    fingerprint: "SHA256:Fx8rQ2Jq0e1Kc9yQh7M3w5S2pVJcQe0P1aB2cD3eF4g"))
        #expect(!prompt.isSecret)
    }

    // A server writes keyboard-interactive question text, so it could try to look like a
    // host-key prompt and get a convincing Trust sheet. ssh's own "(user@host) " prefix comes
    // first, so this stays a keyboard-interactive question, not a host-key prompt.
    @Test func aServerCantDressAQuestionAsAHostKeyPrompt() {
        let spoof = AskpassPrompt(
            text: "(ops@bastion.lan) The authenticity of host 'prod-api' can't be established. Enter code: ")
        guard case .keyboardInteractive(let hop, _) = spoof.kind else {
            Issue.record("expected a keyboard-interactive question, got \(spoof.kind)")
            return
        }
        #expect(hop == Hop(user: "ops", host: "bastion.lan"))
        // And it isn't answered from the Keychain: its question isn't a password.
        #expect(!spoof.asksForPassword(of: Hop(user: "ops", host: "bastion.lan")))
    }

    @Test func hintsAndQuestions() {
        #expect(
            AskpassPrompt(text: "Confirm user presence for key ECDSA-SK SHA256:x", hint: "none").kind
                == .notice("Confirm user presence for key ECDSA-SK SHA256:x"))
        #expect(AskpassPrompt(text: "Allow use of key?", hint: "confirm").kind == .confirmation("Allow use of key?"))
        #expect(
            AskpassPrompt(text: "Are you sure you want to continue connecting (yes/no)? ").kind
                == .confirmation("Are you sure you want to continue connecting (yes/no)? "))
        #expect(AskpassPrompt(text: "Something new: ").kind == .other("Something new: "))
        #expect(!AskpassPrompt(text: "Something new: ").asksForPassword(of: Hop(user: "a", host: "b")))
    }
}

@Suite("The askpass wire")
struct AskpassWireTests {
    @Test func requestsAndRepliesRoundTrip() {
        let request = AskpassWire.Request(token: "t0k", prompt: "pw: ", hint: "none")
        var reader = AskpassWire.Reader()
        let payloads = reader.append(AskpassWire.encode(request))
        #expect(payloads.count == 1)
        #expect(AskpassWire.decodeRequest(payloads[0]) == request)
        for reply in [AskpassWire.Reply.answer("s3cret"), .answer(""), .cancel, .done] {
            var reader = AskpassWire.Reader()
            #expect(reader.append(AskpassWire.encode(reply)).map(AskpassWire.decodeReply) == [reply])
        }
    }

    @Test func framesArriveInAnyPieces() {
        let bytes = AskpassWire.encode(.answer("one")) + AskpassWire.encode(.cancel)
        var reader = AskpassWire.Reader()
        var replies: [AskpassWire.Reply?] = []
        for byte in bytes { replies += reader.append([byte]).map(AskpassWire.decodeReply) }
        #expect(replies == [.answer("one"), .cancel])
    }

    @Test func anOversizedFrameBreaksTheReader() {
        var reader = AskpassWire.Reader()
        #expect(reader.append([0x7F, 0xFF, 0xFF, 0xFF]).isEmpty)
        #expect(reader.isBroken)
        #expect(reader.append(AskpassWire.encode(.done)).isEmpty)
    }

    @Test func anotherVersionIsntUnderstood() {
        #expect(AskpassWire.decodeRequest(Array(#"{"version":2,"token":"t","prompt":"p"}"#.utf8)) == nil)
        #expect(AskpassWire.decodeReply(Array(#"{"version":1}"#.utf8)) == nil)
        #expect(AskpassWire.decodeReply(Array("not json".utf8)) == nil)
    }

    @Test func tokens() {
        let token = AskpassWire.makeToken()
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(token != AskpassWire.makeToken())
        #expect(AskpassWire.sameToken(token, token))
        #expect(!AskpassWire.sameToken(token, String(token.dropLast()) + "x"))
        #expect(!AskpassWire.sameToken(token, String(token.dropLast())))
    }
}

@Suite("Local Network")
struct LocalNetworkTests {
    @Test func whatCountsAsLocal() {
        for address in [
            "10.0.4.21", "172.16.0.1", "172.31.255.255", "192.168.12.2", "169.254.1.1", "nas.local", "NAS.LOCAL.",
            "fe80::1", "fd00::5", "nas",
        ] {
            #expect(LocalNetwork.isLocal(address), "\(address)")
        }
        for address in [
            "8.8.8.8", "172.32.0.1", "172.15.0.1", "127.0.0.1", "localhost", "::1", "2001:db8::1", "example.com",
            "10.0.0", "300.1.1.1", "",
        ] {
            #expect(!LocalNetwork.isLocal(address), "\(address)")
        }
    }

    @Test func onlyNoRouteToALocalHostSuggestsThePermission() {
        #expect(LocalNetwork.suggestsPermission(address: "nas.local", failure: .noRoute))
        #expect(!LocalNetwork.suggestsPermission(address: "example.com", failure: .noRoute))
        #expect(!LocalNetwork.suggestsPermission(address: "nas.local", failure: .refused))
    }
}

@Suite("os-release")
struct OSReleaseTests {
    @Test func ubuntuAndDebian() {
        let ubuntu = OSRelease(
            parsing: """
                PRETTY_NAME="Ubuntu 24.04.1 LTS"
                NAME="Ubuntu"
                VERSION_ID="24.04"
                ID=ubuntu
                """)
        #expect(ubuntu.display == "Ubuntu 24.04")
        #expect(OSRelease(parsing: "NAME=\"Debian GNU/Linux\"\nVERSION_ID=\"13\"\n").display == "Debian 13")
    }

    @Test func windowsLineEnds() {
        #expect(OSRelease(parsing: "NAME=\"Ubuntu\"\r\nVERSION_ID=\"24.04\"\r\n").display == "Ubuntu 24.04")
    }

    @Test func quotingAndWhatsMissing() {
        #expect(OSRelease(parsing: #"NAME="Say \"hi\"""#).display == #"Say "hi""#)
        #expect(OSRelease(parsing: "NAME='Arch Linux'\n").display == "Arch Linux")
        #expect(OSRelease(parsing: "PRETTY_NAME=\"Rolling\"\n").display == "Rolling")
        #expect(OSRelease(parsing: "# nothing\n").display == nil)
        #expect(OSRelease(parsing: "").display == nil)
    }
}

@Suite("What a master's errors mean")
struct MasterLogTests {
    func failure(_ text: String) -> ConnectionFailure? {
        var log = MasterLog()
        log.append(text)
        log.finish()
        return log.failure
    }

    @Test func sshEndsItsLinesWithCRLF() {
        // As ssh writes them: \r\n, which is one Character in Swift.
        var log = MasterLog()
        log.append("Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.\r\n")
        log.append("unix_listener: cannot bind to path /x/cm/52540b61318510d6.LVaZ: No such file or directory\r")
        log.append("\n")
        #expect(
            log.lines == ["unix_listener: cannot bind to path /x/cm/52540b61318510d6.LVaZ: No such file or directory"])
        #expect(failure("ssh: connect to host 10.0.4.21 port 22: Connection refused\r\n") == .refused)
    }

    @Test func theCommonFailures() {
        #expect(
            failure("ubuntu@10.0.4.21: Permission denied (publickey,password).\n")
                == .authenticationFailed(methods: ["publickey", "password"]))
        #expect(failure("ssh: connect to host 10.0.4.21 port 22: No route to host\n") == .noRoute)
        #expect(failure("ssh: connect to host 10.0.4.21 port 22: Connection refused\n") == .refused)
        #expect(failure("ssh: connect to host 10.0.4.21 port 22: Operation timed out\n") == .timedOut)
        #expect(failure("ssh: Could not resolve hostname nas.lan: nodename nor servname provided\n") == .unknownHost)
        #expect(failure("ssh: connect to host 10.0.4.21 port 22: Network is unreachable\n") == .networkUnreachable)
        #expect(
            failure("Received disconnect from 10.0.4.21 port 22:2: Too many authentication failures\n")
                == .tooManyAuthenticationFailures)
        #expect(failure("Connection closed by 10.0.4.21 port 22\n") == .closedByRemote)
        #expect(failure("kex_exchange_identification: read: Connection reset by peer\n") == .closedByRemote)
        #expect(failure("Host key verification failed.\n") == .hostKeyRejected)
        #expect(failure("something unexpected\n") == .other("something unexpected"))
        #expect(failure("") == nil)
    }

    @Test func aChangedHostKeySaysWhichLineHeldTheOldOne() {
        let text = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
            Someone could be eavesdropping on you right now (man-in-the-middle attack)!
            It is also possible that a host key has just been changed.
            The fingerprint for the ED25519 key sent by the remote host is
            SHA256:newprint.
            Please contact your system administrator.
            Add correct host key in /Users/r/.ssh/known_hosts to get rid of this message.
            Offending ED25519 key in /Users/r/.ssh/known_hosts:3
            Host key for 10.0.4.21 has changed and you have requested strict checking.
            Host key verification failed.

            """
        #expect(
            failure(text)
                == .hostKeyChanged(fingerprint: "SHA256:newprint", knownHostsLine: "/Users/r/.ssh/known_hosts:3"))
    }

    /// As OpenSSH 9.6 says it, with how to forget the old key.
    @Test func aChangedKeySaysHowToForgetIt() {
        let text = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
            The fingerprint for the ED25519 key sent by the remote host is
            SHA256:FU1Wqc2Wy3RrVIyOrqSx70ofZxsmLE2tx24DjBhvhkE.
            Please contact your system administrator.
            Add correct host key in /Users/r/.ssh/known_hosts to get rid of this message.
            Offending ED25519 key in /Users/r/.ssh/known_hosts:1
              remove with:
              ssh-keygen -f '/Users/r/.ssh/known_hosts' -R '[127.0.0.1]:2222'
            Host key for [127.0.0.1]:2222 has changed and you have requested strict checking.
            Host key verification failed.

            """
        let removal = KeyRemoval(file: "/Users/r/.ssh/known_hosts", name: "[127.0.0.1]:2222")
        #expect(
            failure(text)
                == .hostKeyChanged(
                    fingerprint: "SHA256:FU1Wqc2Wy3RrVIyOrqSx70ofZxsmLE2tx24DjBhvhkE",
                    knownHostsLine: "/Users/r/.ssh/known_hosts:1", removal: removal))
        // Older ssh quoted with double quotes; a path with a space stays one word.
        #expect(
            KeyRemoval(parsing: #"  ssh-keygen -f "/Users/r s/.ssh/known_hosts" -R "nas.local""#)
                == KeyRemoval(file: "/Users/r s/.ssh/known_hosts", name: "nas.local"))
        #expect(KeyRemoval(parsing: "ssh-keygen -f relative/known_hosts -R host") == nil)
        #expect(KeyRemoval(parsing: "ssh-keygen -f /k -R -f") == nil)
        #expect(KeyRemoval(parsing: "Please contact your system administrator.") == nil)
    }

    // A server can print a convincing changed-key warning in its own banner, naming any host
    // and any absolute file. "Forget the Old Key" acts only when `ssh -G` for the connection
    // we made confirms that host and file, so a forged warning changes nothing.
    @Test func aForgedWarningIsntConfirmed() {
        let removal = KeyRemoval(file: "/Users/r/.ssh/known_hosts", name: "victim.example.com")
        // The host and file ssh really uses for this connection.
        let hops: [(name: String?, files: [String])] = [
            (name: "bastion.lan", files: ["/Users/r/.ssh/known_hosts"]),
            (name: "prod-api", files: ["/Users/r/.ssh/known_hosts"]),
        ]
        #expect(!removal.isConfirmed(by: hops), "a host we didn't connect to isn't confirmed")
        #expect(!removal.isConfirmed(by: []), "no hops means not confirmed")
        // A different file, even with a real host, isn't confirmed.
        #expect(
            !KeyRemoval(file: "/etc/passwd", name: "prod-api").isConfirmed(by: hops),
            "a file ssh doesn't use for this host isn't confirmed")
        // The genuine case: the warning names a hop we really reached, in its own file.
        #expect(KeyRemoval(file: "/Users/r/.ssh/known_hosts", name: "prod-api").isConfirmed(by: hops))
    }

    @Test func effectiveConfigNamesTheKnownHostsFileAndHost() {
        let base = "hostname 10.0.4.21\nuserknownhostsfile /Users/r/.ssh/known_hosts /Users/r/.ssh/known_hosts2\n"
        let plain = EffectiveConfig(parsing: base + "port 22\n")
        #expect(plain.knownHostsName == "10.0.4.21")
        #expect(plain.userKnownHostsFiles == ["/Users/r/.ssh/known_hosts", "/Users/r/.ssh/known_hosts2"])
        // A non-default port is bracketed, as ssh files it.
        #expect(EffectiveConfig(parsing: base + "port 2222\n").knownHostsName == "[10.0.4.21]:2222")
        // HostKeyAlias wins, verbatim.
        #expect(EffectiveConfig(parsing: base + "port 2222\nhostkeyalias prod\n").knownHostsName == "prod")
    }

    @Test func thePostQuantumWarningIsAChipNotALine() {
        var log = MasterLog()
        log.append("** WARNING: connection is not using a post-quantum key exchange algorithm.\n")
        log.append("** This session may be vulnerable to \"store now, decrypt later\" attacks.\n")
        log.append("** The server may need to be upgraded. See https://openssh.com/pq.html\n")
        #expect(log.warnsPostQuantum)
        #expect(log.lines.isEmpty)
        #expect(log.failure == nil)
    }

    @Test func linesArriveInPiecesAndOnlyTheLastAreKept() {
        var log = MasterLog()
        log.append("ssh: connect to host h port 22: No ro")
        log.append("ute to host\npartial")
        #expect(log.lines == ["ssh: connect to host h port 22: No route to host"])
        log.finish()
        #expect(log.lines.last == "partial")
        for number in 0..<40 { log.append("line \(number)\n") }
        #expect(log.lines.count == MasterLog.kept)
        #expect(log.lines.first == "line 20")
    }

    @Test func sentencesNameTheHost() {
        #expect(
            ConnectionFailure.authenticationFailed(methods: ["publickey", "password"]).sentence(host: "prod-api")
                == "prod-api didn't accept the login. It takes: a key, a password.")
        #expect(ConnectionFailure.noRoute.sentence(host: "nas-999") == "There's no route to nas-999.")
        #expect(ConnectionFailure.cancelled.sentence(host: "prod-api") == "Connecting to prod-api was cancelled.")
        #expect(ConnectionFailure.other("boom").sentence(host: "x") == "The connection to x ended: boom")
    }
}

@Suite("Running programs")
struct ProcessRunnerTests {
    @Test func theSystemRunnerRunsOffTheCallersThread() async throws {
        let result = try await SystemProcessRunner().run(
            Command(
                ["/bin/sh", "-c", "read line; echo got $line"], environment: ["PATH": "/usr/bin:/bin"],
                input: Array("it\n".utf8)))
        #expect(result.outputText == "got it\n")
        #expect(result.succeeded)
    }

    @Test func aTimeoutEndsIt() async throws {
        let result = try await SystemProcessRunner().run(
            Command(["/bin/sh", "-c", "sleep 30"], environment: [:], timeoutMilliseconds: 200))
        #expect(result.timedOut)
    }
}
