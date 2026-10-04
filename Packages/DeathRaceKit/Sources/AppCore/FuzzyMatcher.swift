import Foundation

/// How well a query matched, and where, for highlighting.
public struct FuzzyMatch: Equatable, Sendable {
    public var score: Int
    /// The matched characters of the candidate, as ranges of character offsets.
    public var ranges: [Range<Int>]
}

/// Hear Me Calling's matching: the query's characters must appear in the candidate in
/// order, ignoring case and accents ("splr" finds "Split pane right"). Among the ways they
/// can line up, the best scoring one wins: word starts and the very start count for a
/// match, and so do runs of matched characters, each keeping the bonus of the character
/// that began it, as in fzf; skipped characters count against it.
public enum FuzzyMatcher {
    static let matchScore = 16
    static let runBonus = 12
    static let wordStartBonus = 30
    static let startBonus = 20
    static let gapPenalty = 3
    static let leadingPenalty = 1
    static let leadingPenaltyLimit = 15

    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = query.filter { !$0.isWhitespace }.map(fold)
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, ranges: []) }
        let characters = Array(candidate)
        let hay = characters.map(fold)
        let (n, m) = (needle.count, hay.count)
        guard n <= m else { return nil }

        let bonus = (0..<m).map { wordStartBonus(at: $0, in: characters) }
        let unmatched = Int.min / 4
        // best[i][j]: the best score with needle[...i] matched and needle[i] at hay[j].
        // reach[i][j]: the best of best[i][...j], less a gap penalty for each step to j,
        // and where that best ended.
        var best = [[Int]](repeating: [Int](repeating: unmatched, count: m), count: n)
        var cameFromRun = [[Bool]](repeating: [Bool](repeating: false, count: m), count: n)
        // The bonus of the character that began the run ending at [i][j].
        var runStart = [[Int]](repeating: [Int](repeating: 0, count: m), count: n)
        var reach = [[(score: Int, at: Int)]](repeating: [(unmatched, -1)], count: n)
        for i in 0..<n {
            var row = [(score: Int, at: Int)](repeating: (unmatched, -1), count: m)
            for j in 0..<m {
                if hay[j] == needle[i] {
                    runStart[i][j] = bonus[j]
                    if i == 0 {
                        best[i][j] = matchScore + bonus[j] - min(j * leadingPenalty, leadingPenaltyLimit)
                    } else if j > 0 {
                        let run =
                            best[i - 1][j - 1] > unmatched
                            ? best[i - 1][j - 1] + matchScore + max(bonus[j], runStart[i - 1][j - 1], runBonus)
                            : unmatched
                        let jump =
                            j > 1 && reach[i - 1][j - 2].score > unmatched
                            ? reach[i - 1][j - 2].score - gapPenalty + matchScore + bonus[j] : unmatched
                        if run >= jump && run > unmatched {
                            best[i][j] = run
                            cameFromRun[i][j] = true
                            runStart[i][j] = runStart[i - 1][j - 1]
                        } else if jump > unmatched {
                            best[i][j] = jump
                        }
                    }
                }
                let carried =
                    j > 0 && row[j - 1].score > unmatched
                    ? (row[j - 1].score - gapPenalty, row[j - 1].at) : (unmatched, -1)
                row[j] = best[i][j] >= carried.0 && best[i][j] > unmatched ? (best[i][j], j) : carried
            }
            reach[i] = row
        }

        guard let last = (0..<m).max(by: { best[n - 1][$0] < best[n - 1][$1] }), best[n - 1][last] > unmatched else {
            return nil
        }
        // Walk back to find where each character matched.
        var positions = [Int](repeating: 0, count: n)
        var j = last
        for i in stride(from: n - 1, through: 0, by: -1) {
            positions[i] = j
            guard i > 0 else { break }
            j = cameFromRun[i][j] ? j - 1 : reach[i - 1][j - 2].at
        }
        var ranges: [Range<Int>] = []
        for position in positions {
            if let previous = ranges.last, previous.upperBound == position {
                ranges[ranges.count - 1] = previous.lowerBound..<(position + 1)
            } else {
                ranges.append(position..<(position + 1))
            }
        }
        return FuzzyMatch(score: best[n - 1][last], ranges: ranges)
    }

    /// The character compared: lowercase, without accents.
    static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The bonus for a match at `index`: the start of the candidate, of a word, or of a
    /// capitalized part ("FrameStats").
    static func wordStartBonus(at index: Int, in characters: [Character]) -> Int {
        guard index > 0 else { return wordStartBonus + startBonus }
        let previous = characters[index - 1]
        let current = characters[index]
        if previous.isWhitespace || "-_/.:·\\>".contains(previous) { return wordStartBonus }
        if previous.isLowercase && current.isUppercase { return wordStartBonus }
        if !previous.isNumber && current.isNumber { return wordStartBonus / 2 }
        return 0
    }
}
