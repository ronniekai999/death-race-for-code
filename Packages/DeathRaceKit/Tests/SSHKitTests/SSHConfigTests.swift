import Testing

@testable import SSHKit

/// Files for discovery tests, without touching the disk.
private func fileSystem(_ files: [String: String]) -> SSHConfigDiscovery.FileSystem {
    SSHConfigDiscovery.FileSystem(
        contents: { files[$0] },
        glob: { pattern in
            // `*` only, enough for the tests.
            guard pattern.contains("*") else { return files[pattern] == nil ? [] : [pattern] }
            let parts = pattern.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return files.keys.filter { $0.hasPrefix(parts[0]) && $0.hasSuffix(parts[1]) }.sorted()
        })
}

@Suite("Reading ~/.ssh/config")
struct SSHConfigDiscoveryTests {
    @Test func linesSplitTheWaySshSplitsThem() {
        typealias D = SSHConfigDiscovery
        #expect(D.tokenize("HostName 10.0.0.1") == ["HostName", "10.0.0.1"])
        #expect(D.tokenize("HostName=10.0.0.1") == ["HostName", "10.0.0.1"])
        #expect(D.tokenize("  HostName = 10.0.0.1  ") == ["HostName", "10.0.0.1"])
        #expect(D.tokenize("\tUser\troot") == ["User", "root"])
        #expect(D.tokenize("LocalCommand echo a=b") == ["LocalCommand", "echo", "a=b"])
        #expect(D.tokenize(#"IdentityFile "~/My Keys/id""#) == ["IdentityFile", "~/My Keys/id"])
        #expect(D.tokenize("IdentityFile '~/My Keys/id'") == ["IdentityFile", "~/My Keys/id"])
        #expect(D.tokenize(#"IdentityFile ~/My\ Keys/id"#) == ["IdentityFile", "~/My Keys/id"])
        #expect(D.tokenize(#"ProxyCommand nc %h\x"#) == ["ProxyCommand", "nc", #"%h\x"#])
        #expect(D.tokenize("Host a b # comment") == ["Host", "a", "b"])
        #expect(D.tokenize("# all comment") == [])
        #expect(D.tokenize("User a#b") == ["User", "a#b"])
        #expect(D.tokenize("") == [])
    }

    @Test func onlyConcreteNamesAreHosts() {
        let files = [
            "/h/.ssh/config": """
            Host *
                ServerAliveInterval 30
            Host prod-api prod-db *.internal !bad
                User deploy
            Host ?ingle
            Match host nas-999
                User nobody
            Host nas-999
                HostName 192.168.1.5
                Port 2222
                ProxyJump bastion
            """
        ]
        let aliases = SSHConfigDiscovery.aliases(inFileAt: "/h/.ssh/config", home: "/h", fileSystem: fileSystem(files))
        #expect(aliases.map(\.name) == ["prod-api", "prod-db", "nas-999"])
        #expect(aliases[0].user == "deploy" && aliases[1].user == "deploy")
        #expect(
            aliases[2]
                == .init(
                    name: "nas-999", hostName: "192.168.1.5", port: 2222, proxyJump: "bastion", file: "/h/.ssh/config",
                    line: 8))
    }

    @Test func aFileWithWindowsLineEndsReadsTheSame() {
        let files = [
            "/h/.ssh/config": "Host nas-999\r\n    HostName 192.168.1.5\r\n\r\nHost prod-api\r\n    User deploy\r\n"
        ]
        let aliases = SSHConfigDiscovery.aliases(inFileAt: "/h/.ssh/config", home: "/h", fileSystem: fileSystem(files))
        #expect(aliases.map(\.name) == ["nas-999", "prod-api"])
        #expect(aliases[0].hostName == "192.168.1.5")
        #expect(aliases[1].user == "deploy")
        #expect(aliases[1].line == 4)
    }

    @Test func theFirstValueWins() {
        let files = [
            "/h/.ssh/config": """
            Host web
                User first
            Host web
                User second
                HostName web.example
            """
        ]
        let aliases = SSHConfigDiscovery.aliases(inFileAt: "/h/.ssh/config", home: "/h", fileSystem: fileSystem(files))
        #expect(aliases.count == 1)
        #expect(aliases[0].user == "first")
        #expect(aliases[0].hostName == "web.example")
    }

    @Test func includesAreFollowedLikeSshFollowsThem() {
        let files = [
            "/h/.ssh/config": """
            Include config.d/*.conf
            Include ~/work/ssh.conf
            Include /etc/absolute.conf
            Host home
            """,
            "/h/.ssh/config.d/b.conf": "Host b-host",
            "/h/.ssh/config.d/a.conf": "Host a-host\n  User a",
            "/h/work/ssh.conf": "Host work-host",
            "/etc/absolute.conf": "Host abs-host",
        ]
        let aliases = SSHConfigDiscovery.aliases(inFileAt: "/h/.ssh/config", home: "/h", fileSystem: fileSystem(files))
        #expect(aliases.map(\.name) == ["a-host", "b-host", "work-host", "abs-host", "home"])
        #expect(aliases[0].file == "/h/.ssh/config.d/a.conf")
    }

    @Test func anIncludeLoopStops() {
        let files = ["/h/.ssh/config": "Host loop\nInclude config"]
        let aliases = SSHConfigDiscovery.aliases(inFileAt: "/h/.ssh/config", home: "/h", fileSystem: fileSystem(files))
        #expect(aliases.map(\.name) == ["loop"])
    }

    @Test func aMissingFileHasNoHosts() {
        #expect(SSHConfigDiscovery.aliases(inFileAt: "/nope", home: "/h", fileSystem: fileSystem([:])).isEmpty)
    }
}

@Suite("What ssh -G says")
struct EffectiveConfigTests {
    static let output = """
        user ubuntu
        hostname 10.0.4.21
        port 2222
        controlmaster false
        identityfile /tmp/a b/se-1
        identityfile ~/.ssh/id_ed25519
        controlpersist no
        proxyjump deathrace-bastion
        controlpath /tmp/cm/3f2a9c41d07be5aa
        hostkeyalias none
        """

    @Test func valuesKeepTheirSpacesAndRepeats() {
        let config = EffectiveConfig(parsing: Self.output)
        #expect(config.user == "ubuntu")
        #expect(config.hostName == "10.0.4.21")
        #expect(config.port == 2222)
        #expect(config.identityFiles == ["/tmp/a b/se-1", "~/.ssh/id_ed25519"])
        #expect(config.controlMaster == "false")
        #expect(config.controlPersist == "no")
        #expect(config.proxyJump == "deathrace-bastion")
        #expect(config.controlPath == "/tmp/cm/3f2a9c41d07be5aa")
        #expect(config.hostKeyAlias == nil)
        #expect(config.promptHost == "10.0.4.21")
        #expect(config["HostName"] == "10.0.4.21")
        #expect(config["nothing"] == nil)
    }

    @Test func aHostKeyAliasIsWhatPromptsName() {
        let config = EffectiveConfig(parsing: "hostname 10.0.4.21\r\nhostkeyalias prod\r\ncontrolpath none\n")
        #expect(config.promptHost == "prod")
        #expect(config.controlPath == nil)
    }
}

@Suite("WRLD's paths")
struct WRLDPathsTests {
    @Test func everythingIsUnderOneShortFolder() {
        let paths = WRLDPaths.standard(home: "/Users/r/")
        #expect(paths.root == "/Users/r/.deathrace")
        #expect(paths.generatedConfig == "/Users/r/.deathrace/ssh_config")
        #expect(paths.controlFolder == "/Users/r/.deathrace/cm")
        #expect(paths.keysFolder == "/Users/r/.deathrace/keys")
        #expect(paths.state == "/Users/r/.deathrace/state.json")
        #expect(paths.brokerSocket(pid: 4242) == "/Users/r/.deathrace/run/askpass-4242.sock")
    }

    @Test func controlSocketsHaveFixedNamesThatFit() {
        let paths = WRLDPaths.standard(home: "/Users/r")
        let path = paths.controlPath(for: "h3f2a9c41")
        #expect(path == paths.controlPath(for: "h3f2a9c41"))
        #expect(path != paths.controlPath(for: "h3f2a9c42"))
        #expect(path.split(separator: "/").last?.count == 16)
        #expect(WRLDPaths.fitsControlSocket(path))
    }

    @Test func aLongHomeFolderMovesTheSocketsToTheTemporaryFolder() {
        let home = "/Users/" + String(repeating: "x", count: 60)
        let paths = WRLDPaths.standard(home: home, temporaryDirectory: "/var/folders/ab/cd/T/")
        #expect(paths.controlFolder == "/var/folders/ab/cd/T/deathrace-cm")
        #expect(WRLDPaths.fitsControlSocket(paths.controlPath(for: "h1")))
        #expect(paths.generatedConfig.hasPrefix(home))
    }

    @Test func theHashIsStable() {
        // FNV-1a's published value for the empty string and "a".
        #expect(WRLDPaths.stableHex("") == "cbf29ce484222325")
        #expect(WRLDPaths.stableHex("a") == "af63dc4c8601ec8c")
    }
}
