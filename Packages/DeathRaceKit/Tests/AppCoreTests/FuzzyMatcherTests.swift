import Testing

@testable import AppCore

@Suite struct FuzzyMatcherTests {
    func score(_ query: String, _ candidate: String) -> Int? {
        FuzzyMatcher.match(query, in: candidate)?.score
    }

    @Test func charactersMustAppearInOrder() {
        #expect(FuzzyMatcher.match("splr", in: "Split pane right") != nil)
        #expect(FuzzyMatcher.match("rlps", in: "Split pane right") == nil)
        #expect(FuzzyMatcher.match("xyz", in: "Split pane right") == nil)
        #expect(FuzzyMatcher.match("splitpanerightnow", in: "Split pane right") == nil)
    }

    @Test func caseAccentsAndSpacesInTheQueryDontMatter() {
        #expect(FuzzyMatcher.match("CAFE", in: "Café") != nil)
        #expect(FuzzyMatcher.match("café", in: "CAFE") != nil)
        #expect(FuzzyMatcher.match("split right", in: "Split pane right") != nil)
    }

    @Test func anEmptyQueryMatchesEverything() {
        #expect(FuzzyMatcher.match("", in: "anything") == FuzzyMatch(score: 0, ranges: []))
        #expect(FuzzyMatcher.match("  ", in: "anything") == FuzzyMatch(score: 0, ranges: []))
    }

    @Test func wordStartsWinOverTheMiddleOfWords() {
        // "p" could be the one in "Split"; the one starting "pane" is better.
        #expect(FuzzyMatcher.match("pr", in: "Split pane right")?.ranges == [6..<7, 11..<12])
        #expect(score("nt", "New tab")! > score("nt", "Contents")!)
        #expect(score("fs", "Log Frame Stats")! > score("fs", "Halfsize")!)
    }

    @Test func runsWinOverScatteredLetters() {
        #expect(score("tab", "New tab")! > score("tab", "Toggle all borders")!)
        #expect(FuzzyMatcher.match("tab", in: "New tab")?.ranges == [4..<7])
    }

    @Test func theStartIsBest() {
        #expect(score("lu", "Lucid Dreams")! > score("lu", "Death Race for Love, lucid")!)
        #expect(FuzzyMatcher.match("ld", in: "Lucid Dreams")?.ranges == [0..<1, 6..<7])
    }

    @Test func rangesCoverTheMatchedCharacters() throws {
        let match = try #require(FuzzyMatcher.match("splr", in: "Split pane right"))
        #expect(match.ranges == [0..<3, 11..<12])
    }
}
