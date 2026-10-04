import ConfigKit
import VTCore

/// Quoting file paths dropped on the terminal, so the shell reads each as one word.
public enum ShellQuoting {
    /// Characters that never need quoting.
    private static let safe: Set<UInt8> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_".utf8)

    /// `path` as one shell word: as it is when nothing in it is special, with backslashes
    /// before the special characters otherwise (as Terminal does), and in single quotes when
    /// it holds control characters, which a backslash cannot carry.
    public static func quote(_ path: String) -> String {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty else { return "''" }
        if bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) {
            return "'" + path.replacingAll("'", with: "'\\''") + "'"
        }
        var out = ""
        for (index, character) in path.unicodeScalars.enumerated() {
            let isSafe = character.value < 0x80 && safe.contains(UInt8(character.value))
            // A leading ~ would be expanded to a home directory.
            if !isSafe && character.value < 0x80 || (index == 0 && character == "~") {
                out.unicodeScalars.append("\\")
            }
            out.unicodeScalars.append(character)
        }
        return out
    }

    /// Several dropped paths: quoted, separated by spaces, with a space after the last so
    /// typing can go on.
    public static func quote(paths: [String]) -> String {
        paths.map(quote).joined(separator: " ") + " "
    }
}

extension String {
    /// Every `target` replaced with `replacement`, without Foundation.
    func replacingAll(_ target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        var out = ""
        var rest = Substring(self)
        while let range = rest.range(of: target) {
            out += rest[..<range.lowerBound]
            out += replacement
            rest = rest[range.upperBound...]
        }
        return out + rest
    }
}

extension Substring {
    /// The first occurrence of `target`, compared by Unicode scalars.
    fileprivate func range(of target: String) -> Range<Index>? {
        let needle = Array(target.unicodeScalars)
        let scalars = unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex {
            var i = start
            var j = 0
            while j < needle.count, i < scalars.endIndex, scalars[i] == needle[j] {
                i = scalars.index(after: i)
                j += 1
            }
            if j == needle.count { return start..<i }
            start = scalars.index(after: start)
        }
        return nil
    }
}

/// The directory a shell reports with OSC 7, if it is on this machine.
public enum WorkingDirectoryURL {
    /// The path a `file://host/path` (or kitty's `kitty-shell-cwd://host/path`) report
    /// names, percent-decoded, or nil when it names another machine or is not such a URL.
    /// `localHostNames` are this machine's names; "localhost" and an empty host always
    /// count.
    public static func path(from report: String, localHostNames: Set<String>) -> String? {
        let decode: Bool
        let rest: Substring
        if report.hasPrefix("file://") {
            decode = true
            rest = report.dropFirst("file://".count)
        } else if report.hasPrefix("kitty-shell-cwd://") {
            decode = false
            rest = report.dropFirst("kitty-shell-cwd://".count)
        } else {
            return nil
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = rest[..<slash].lowercased()
        let names = Set(localHostNames.map { $0.lowercased() })
        let shortNames = Set(names.map { $0.hasSuffix(".local") ? String($0.dropLast(".local".count)) : $0 })
        let hostIsLocal =
            host.isEmpty || host == "localhost" || names.contains(host)
            || shortNames.contains(host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host)
        guard hostIsLocal else { return nil }
        let path = String(rest[slash...])
        return decode ? percentDecoded(path) : path
    }

    static func percentDecoded(_ text: String) -> String? {
        var bytes: [UInt8] = []
        var utf8 = text.utf8.makeIterator()
        while let byte = utf8.next() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard let high = utf8.next().flatMap(hexValue), let low = utf8.next().flatMap(hexValue) else {
                return nil
            }
            bytes.append(high << 4 | low)
        }
        guard !bytes.contains(0) else { return nil }
        let decoded = String(decoding: bytes, as: UTF8.self)
        // Invalid UTF-8 would have become U+FFFD: refuse it rather than invent a path.
        return Array(decoded.utf8) == bytes ? decoded : nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// What the view asks before a paste that could run commands nobody saw: text with line
/// breaks or control characters, going to a program that did not ask for pastes to be
/// marked as such (bracketed paste, mode 2004). Without the marks, a shell runs each line
/// as it arrives.
public struct PasteWarning: Sendable, Equatable {
    public var title: String
    public var message: String
    /// The start of the text, with control characters shown as symbols (␛ for Escape).
    public var preview: String

    /// Nil when `text` can be pasted without asking.
    public init?(text: String, modes: TerminalModes, previewLimit: Int = 2_000) {
        guard InputEncoder.pasteNeedsConfirmation(text, modes: modes) else { return nil }
        var lines = 1
        var endsWithBreak = false
        for character in text {
            endsWithBreak = character == "\n" || character == "\r" || character == "\r\n"
            if endsWithBreak { lines += 1 }
        }
        if endsWithBreak { lines -= 1 }
        if text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            title = lines > 1 ? "Paste \(lines) lines?" : "Paste and run this line?"
            message =
                lines > 1
                ? "Each line runs as a command as soon as it arrives, as if you typed it and pressed Return."
                : "It runs as a command as soon as it arrives, as if you typed it and pressed Return."
        } else {
            title = "Paste text with control characters?"
            message = "They reach the program as if you typed them, and can act as keys such as Escape or Control-C."
        }
        preview = Self.visible(text, limit: previewLimit)
    }

    /// `text` up to `limit` characters, line breaks kept and other control characters
    /// replaced by their Control Pictures symbols.
    static func visible(_ text: String, limit: Int) -> String {
        var out = ""
        var count = 0
        for character in text {
            guard count < limit else {
                out += "…"
                break
            }
            count += 1
            if character == "\r\n" || character == "\r" || character == "\n" || character == "\t" {
                out.append(character == "\t" ? "\t" : "\n")
                continue
            }
            for scalar in character.unicodeScalars {
                switch scalar.value {
                case 0x00..<0x20: out.unicodeScalars.append(Unicode.Scalar(0x2400 + scalar.value)!)
                case 0x7F: out.unicodeScalars.append("\u{2421}")
                default: out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

/// When Secure Keyboard Entry should be on, and keeping macOS's calls balanced.
///
/// It is system-wide while on: other apps stop seeing keystrokes (which is the point, and
/// also why it is never left on in the background).
public struct SecureInput: Sendable {
    public var mode: SecureKeyboardEntry
    /// The Edit menu item is checked.
    public var menuChecked = false
    public var appIsActive = false
    /// The focused tab's program is reading a password.
    public var focusedTabReadsPassword = false
    /// Whether it is on now, as far as macOS knows.
    public private(set) var isEnabled = false

    public init(mode: SecureKeyboardEntry) {
        self.mode = mode
    }

    /// What the settings and state call for.
    public var desired: Bool {
        guard appIsActive else { return false }
        switch mode {
        case .always: return true
        case .manual: return menuChecked
        case .auto: return menuChecked || focusedTabReadsPassword
        }
    }

    /// Brings macOS in line with `desired`, calling `enable` or `disable` only on a change.
    /// A call that fails leaves the recorded state alone, so the calls stay balanced.
    public mutating func apply(enable: () -> Bool, disable: () -> Bool) {
        let wanted = desired
        guard wanted != isEnabled else { return }
        if wanted ? enable() : disable() { isEnabled = wanted }
    }
}

/// Where an input method's composing text goes on the grid: at the cursor, moved left if it
/// would run past the right edge, and cut off if it is wider than the whole row.
public struct PreeditLayout: Sendable, Equatable {
    public struct Cell: Sendable, Equatable {
        public var column: Int
        public var scalars: [UInt32]
        public var isWide: Bool
    }

    public var row: Int
    public var cells: [Cell]
    /// The column the input method's caret is in, for the candidate window.
    public var caretColumn: Int

    /// `text` at the cursor; `caret` is the input method's caret, in characters from the
    /// start of `text` (nil puts it at the end).
    public init(text: String, cursorColumn: Int, cursorRow: Int, columns: Int, caret: Int? = nil) {
        row = cursorRow
        var characters: [(scalars: [UInt32], width: Int)] = []
        for character in text {
            let scalars = character.unicodeScalars.map(\.value)
            let width = scalars.map(CharacterWidth.of).max().map { max($0, 1) } ?? 1
            characters.append((scalars, min(width, 2)))
        }
        let total = characters.reduce(0) { $0 + $1.width }
        var column = min(max(cursorColumn, 0), max(columns - 1, 0))
        if column + total > columns { column = max(0, columns - total) }
        var cells: [Cell] = []
        var caretColumn = column
        for (index, character) in characters.enumerated() {
            if index == caret { caretColumn = column }
            guard column + character.width <= columns else { break }
            cells.append(Cell(column: column, scalars: character.scalars, isWide: character.width == 2))
            column += character.width
        }
        if caret == nil || caret! >= characters.count { caretColumn = min(column, max(columns - 1, 0)) }
        self.cells = cells
        self.caretColumn = caretColumn
    }
}
