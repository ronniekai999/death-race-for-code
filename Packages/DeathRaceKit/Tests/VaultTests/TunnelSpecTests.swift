import Testing

@testable import Vault

@Suite("Tunnel specs")
struct TunnelSpecTests {
    @Test func aLocalForwardFromTheForm() throws {
        let spec = try TunnelSpec.parse(kind: .local, listen: "5432", forwardTo: "db:5432")
        #expect(spec == TunnelSpec(kind: .local, listenPort: 5432, target: .init(host: "db", port: 5432)))
        #expect(spec.flag == "-L")
        #expect(spec.argument == "5432:db:5432")
        #expect(spec.problems.isEmpty)
        #expect(spec.summary(host: "prod-api") == "5432 → db:5432 · Local · through prod-api")
    }

    @Test func aForwardToTheHostItselfSaysOn() throws {
        let spec = try TunnelSpec.parse(kind: .local, listen: "8080", forwardTo: "localhost:3000")
        #expect(spec.summary(host: "nas-999") == "8080 → localhost:3000 · Local · on nas-999")
    }

    @Test func aDynamicForwardIsASocksProxy() throws {
        let spec = try TunnelSpec.parse(kind: .dynamic, listen: "1080", forwardTo: "ignored:1")
        #expect(spec.target == nil)
        #expect(spec.flag == "-D")
        #expect(spec.argument == "1080")
        #expect(spec.summary(host: "bastion") == "SOCKS 1080 · Dynamic · through bastion")
    }

    @Test func aRemoteForward() throws {
        let spec = try TunnelSpec.parse(kind: .remote, listen: "9000", forwardTo: "localhost:3000")
        #expect(spec.flag == "-R")
        #expect(spec.argument == "9000:localhost:3000")
        #expect(spec.summary(host: "prod-api") == "9000 on prod-api → localhost:3000 · Remote")
    }

    @Test func bindAddressesAndIPv6() throws {
        let spec = try TunnelSpec.parse(kind: .local, listen: "127.0.0.1:5432", forwardTo: "[fd00::5]:5432")
        #expect(spec.bindAddress == "127.0.0.1")
        #expect(spec.target == .init(host: "fd00::5", port: 5432))
        #expect(spec.argument == "127.0.0.1:5432:[fd00::5]:5432")
        #expect(spec.listenText == "127.0.0.1:5432")
        #expect(spec.targetText == "[fd00::5]:5432")
        let v6 = try TunnelSpec.parse(kind: .dynamic, listen: "[::1]:1080")
        #expect(v6.argument == "[::1]:1080")
    }

    @Test func badPortsAreRefused() {
        for listen in ["", "0", "65536", "80a", "-1", "1e3", " ", "123456"] {
            #expect(throws: TunnelSpec.Problem.self, "\(listen)") {
                try TunnelSpec.parse(kind: .dynamic, listen: listen)
            }
        }
        #expect(throws: TunnelSpec.Problem.port("0")) {
            try TunnelSpec.parse(kind: .local, listen: "5432", forwardTo: "db:0")
        }
    }

    @Test func aMissingOrUnbracketedTargetIsRefused() {
        for target in ["", "db", ":5432", "::1:80"] {
            #expect(throws: TunnelSpec.Problem.missingTarget, "\(target)") {
                try TunnelSpec.parse(kind: .local, listen: "5432", forwardTo: target)
            }
        }
    }

    @Test func hostsThatWouldReadAsMoreAreRefused() {
        for host in ["-oProxyCommand=evil", "a b", "x;y", "db'", "db\"", "$(id)", "db\n", "a/b"] {
            #expect(throws: TunnelSpec.Problem.self, "\(host)") {
                try TunnelSpec.parse(kind: .local, listen: "5432", forwardTo: "\(host):5432")
            }
        }
    }

    @Test func problemsCheckASpecMadeInCode() {
        #expect(TunnelSpec(kind: .local, listenPort: 0, target: .init(host: "db", port: 1)).problems == [.port("0")])
        #expect(TunnelSpec(kind: .remote, listenPort: 9000).problems == [.missingTarget])
        #expect(
            TunnelSpec(kind: .local, listenPort: 80, target: .init(host: "-x", port: 1)).problems == [.host("-x")])
        #expect(TunnelSpec(kind: .dynamic, listenPort: 1080).problems.isEmpty)
    }
}
