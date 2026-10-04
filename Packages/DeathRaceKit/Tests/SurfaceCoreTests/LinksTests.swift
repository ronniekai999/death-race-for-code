import Testing

@testable import SurfaceCore

@Suite struct LinkPolicyTests {
    let here: Set<String> = ["ronnies-mbp.local"]

    func action(_ uri: String) -> LinkAction {
        LinkPolicy.action(for: uri, localHostNames: here)
    }

    @Test func webAndMailOpen() {
        #expect(action("https://example.com/a?b=c#d") == .open("https://example.com/a?b=c#d"))
        #expect(action("HTTP://Example.com") == .open("HTTP://Example.com"))
        #expect(action("mailto:someone@example.com") == .open("mailto:someone@example.com"))
        #expect(action("https:example.com") == .refuse(.malformed))
        #expect(action("mailto:") == .refuse(.malformed))
    }

    @Test func filesOnThisMacAreRevealedNeverOpened() {
        #expect(action("file:///Users/ronnie/My%20Notes.md") == .reveal(path: "/Users/ronnie/My Notes.md"))
        #expect(action("file://localhost/tmp/x") == .reveal(path: "/tmp/x"))
        #expect(
            action("file://ronnies-mbp/Applications/Calculator.app") == .reveal(path: "/Applications/Calculator.app"))
        #expect(action("file://build-server/var/log/x") == .refuse(.otherComputer(host: "build-server")))
    }

    @Test func otherSchemesAsk() {
        #expect(action("ssh://prod-api") == .confirm(scheme: "ssh"))
        #expect(action("vscode://file/Users/ronnie/code") == .confirm(scheme: "vscode"))
        #expect(action("x-man-page://ls") == .confirm(scheme: "x-man-page"))
    }

    @Test func scriptsAndJunkAreRefused() {
        #expect(action("javascript:alert(1)") == .refuse(.script))
        #expect(action("DATA:text/html,hi") == .refuse(.script))
        #expect(action("https://example.com/a b") == .refuse(.malformed))
        #expect(action("https://example.com/\u{7}") == .refuse(.malformed))
        #expect(action("no scheme here") == .refuse(.malformed))
        #expect(action("1http://x") == .refuse(.malformed))
        #expect(action("https://example.com/" + String(repeating: "a", count: 2100)) == .refuse(.tooLong))
    }

    @Test func linksWhoseTextNamesAnotherSiteMislead() {
        #expect(LinkPolicy.misleads(text: "apple.com", target: "https://evil.example/apple"))
        #expect(LinkPolicy.misleads(text: "https://apple.com/store", target: "https://apple.com.evil.example"))
        #expect(!LinkPolicy.misleads(text: "apple.com", target: "https://www.apple.com/"))
        #expect(!LinkPolicy.misleads(text: " https://apple.com ", target: "https://APPLE.com/mac"))
        #expect(!LinkPolicy.misleads(text: "the release notes", target: "https://evil.example"))
        #expect(!LinkPolicy.misleads(text: "v1.2", target: "https://example.com"))
        #expect(LinkPolicy.misleads(text: "example.com", target: "file:///etc/passwd"))
    }

    /// Text that reads as apple.com to a person reads as apple.com here too.
    @Test func disguisedSiteNamesStillMislead() {
        let evil = "https://evil.example/"
        for text in [
            "apple.com.", "apple\u{200B}.com", "apple\u{2024}com", "apple.com:443", "(apple.com)",
            "\u{FF41}\u{FF50}\u{FF50}\u{FF4C}\u{FF45}.com", "apple\u{3002}com", "https://apple.com.", "user@apple.com",
        ] {
            #expect(LinkPolicy.misleads(text: text, target: evil), "\(text.debugDescription)")
        }
        // The same site, written another way, is not misleading.
        #expect(!LinkPolicy.misleads(text: "apple.com.", target: "https://apple.com/"))
        #expect(!LinkPolicy.misleads(text: "https://apple.com.", target: "https://www.apple.com/mac"))
        #expect(!LinkPolicy.misleads(text: "apple\u{200B}.com", target: "https://apple.com/"))
    }
}

@Suite struct URLDetectorTests {
    func line(_ text: String) -> [Character?] {
        text.map { $0 }
    }

    @Test func findsURLsInText() {
        let found = URLDetector.urls(in: line("see https://example.com/a?b=1 and mailto:me@x.org."))
        #expect(found.map(\.url) == ["https://example.com/a?b=1", "mailto:me@x.org"])
        #expect(found[0].columns == 4..<29)
    }

    @Test func sentencePunctuationAndUnmatchedBracketsAreNotPartOfIt() {
        #expect(URLDetector.urls(in: line("(see https://example.com/x).")).map(\.url) == ["https://example.com/x"])
        #expect(
            URLDetector.urls(in: line("https://en.wikipedia.org/wiki/Swift_(programming_language)")).map(\.url)
                == ["https://en.wikipedia.org/wiki/Swift_(programming_language)"])
        #expect(URLDetector.urls(in: line("\"https://example.com\"")).map(\.url) == ["https://example.com"])
        #expect(URLDetector.urls(in: line("<https://example.com>")).map(\.url) == ["https://example.com"])
    }

    @Test func onlyRealSchemesCount() {
        #expect(URLDetector.urls(in: line("example.com and /usr/bin")).isEmpty)
        #expect(URLDetector.urls(in: line("http:// alone")).isEmpty)
        #expect(URLDetector.urls(in: line("xhttps://example.com")).isEmpty)
        #expect(URLDetector.urls(in: line("mailto:nobody")).isEmpty)
        #expect(URLDetector.urls(in: line("FILE:///tmp/x")).map(\.url) == ["FILE:///tmp/x"])
    }

    @Test func columnsCountWideCharacters() {
        // 你 takes two columns: the URL after it starts at column 3.
        var cells: [Character?] = ["你", nil, " "]
        cells += line("https://例え.jp/パス")
        let found = URLDetector.url(in: cells, at: 5)
        #expect(found?.url == "https://例え.jp/パス")
        #expect(found?.columns.lowerBound == 3)
        #expect(URLDetector.url(in: cells, at: 0) == nil)
    }
}

@Suite struct FrameRatePolicyTests {
    let policy = FrameRatePolicy(displayMaximum: 120)

    func maximum(_ conditions: FrameRatePolicy.Conditions, _ policy: FrameRatePolicy? = nil) -> Double {
        (policy ?? self.policy).range(for: conditions).maximum
    }

    @Test func typingGetsTheWholeDisplayAndOutputSixty() {
        #expect(maximum(.init(recentInput: true)) == 120)
        #expect(maximum(.init(recentInput: false)) == 60)
        #expect(maximum(.init(recentInput: false), FrameRatePolicy(displayMaximum: 120, capsOutput: false)) == 120)
        #expect(maximum(.init(recentInput: false), FrameRatePolicy(displayMaximum: 60)) == 60)
    }

    @Test func lowPowerModeAndHeatSlowItDown() {
        #expect(maximum(.init(recentInput: true, lowPowerMode: true)) == 60)
        #expect(maximum(.init(recentInput: false, lowPowerMode: true)) == 30)
        #expect(
            maximum(.init(recentInput: false, lowPowerMode: true), FrameRatePolicy(followsLowPowerMode: false)) == 60)
        #expect(maximum(.init(recentInput: true, thermal: .fair)) == 120)
        #expect(maximum(.init(recentInput: true, thermal: .serious)) == 30)
        #expect(maximum(.init(recentInput: true, thermal: .critical)) == 30)
    }

    @Test func theRangePrefersItsMaximum() {
        let range = policy.range(for: .init(recentInput: true))
        #expect(range == FrameRatePolicy.Range(minimum: 60, maximum: 120, preferred: 120))
    }
}

@Suite struct LinkShownTests {
    @Test func invisibleAndReorderingCharactersAreSpelledOut() {
        #expect(LinkPolicy.shown("https://example.com/\u{202E}gpj.exe") == "https://example.com/%E2%80%AEgpj.exe")
        #expect(LinkPolicy.shown("https://a.example/a\u{200B}b c") == "https://a.example/a%E2%80%8Bb%20c")
        #expect(LinkPolicy.shown("https://a.example/中文") == "https://a.example/中文")
        #expect(LinkPolicy.shown(String(repeating: "x", count: 10), limit: 4) == "xxxx…")
    }

    @Test func theSiteAlwaysShows() {
        // A long path gives way; the host does not.
        let long = LinkPolicy.shown("https://wrld.example/" + String(repeating: "p", count: 400), limit: 60)
        #expect(long.hasPrefix("https://wrld.example/pp") && long.hasSuffix("…"))
        // A host of many labels keeps its end, which is the site.
        let labels = String(repeating: "a1b2.", count: 40)
        let deep = LinkPolicy.shown("https://apple.com.\(labels)evil.example/x")
        #expect(deep.contains("evil.example/x"))
        #expect(deep.hasPrefix("https://apple.com."))
        // A long user name before the @ shows as "…".
        let user = LinkPolicy.shown("https://" + String(repeating: "apple.com", count: 6) + "@evil.example/")
        #expect(user == "https://…@evil.example/")
        #expect(LinkPolicy.shown("https://me@evil.example/") == "https://me@evil.example/")
    }

    @Test func linkTextShowsWhatHides() {
        #expect(LinkPolicy.visibleText("\u{202E}gpj.exe") == "⟨U+202E⟩gpj.exe")
        #expect(LinkPolicy.visibleText("apple\u{200B}.com") == "apple⟨U+200B⟩.com")
        #expect(LinkPolicy.visibleText("a\u{3000}b c") == "a⟨U+3000⟩b c")
        #expect(LinkPolicy.visibleText("Legends ✦ 999") == "Legends ✦ 999")
        #expect(LinkPolicy.visibleText("abcdef", limit: 3) == "abc…")
    }
}
