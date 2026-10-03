/// A mouse event over the terminal, in cells (and pixels, for SGR-Pixels reporting).
public struct MouseEvent: Sendable, Equatable {
    public enum Kind: Sendable {
        case press, release, motion
    }

    public enum Button: Sendable {
        case left, middle, right
        /// Motion with no button held.
        case none
        case wheelUp, wheelDown, wheelLeft, wheelRight
        case back, forward
    }

    public var kind: Kind
    public var button: Button
    /// 0-based cell coordinates.
    public var column: Int
    public var row: Int
    /// 0-based pixel coordinates inside the terminal, for mode 1016.
    public var pixelX: Int
    public var pixelY: Int
    /// Shift, Alt and Control are reported; the rest are ignored.
    public var modifiers: KeyModifiers

    public init(
        _ kind: Kind, button: Button, column: Int, row: Int, pixelX: Int = 0, pixelY: Int = 0,
        modifiers: KeyModifiers = []
    ) {
        self.kind = kind
        self.button = button
        self.column = column
        self.row = row
        self.pixelX = pixelX
        self.pixelY = pixelY
        self.modifiers = modifiers
    }
}

/// Mouse reports in the tracking mode and encoding the program asked for.
public enum MouseEncoder {
    /// The report for `event`, or nothing when the current tracking mode does not report it
    /// (or the position cannot be encoded).
    public static func encode(_ event: MouseEvent, modes: TerminalModes) -> [UInt8] {
        let isWheel = [.wheelUp, .wheelDown, .wheelLeft, .wheelRight].contains(event.button)
        switch modes.mouseTracking {
        case .none:
            return []
        case .x10:
            guard event.kind == .press, !isWheel else { return [] }
        case .normal:
            guard event.kind != .motion else { return [] }
        case .buttonEvent:
            guard event.kind != .motion || event.button != .none else { return [] }
        case .anyEvent:
            break
        }
        // Wheels have no release.
        if isWheel && event.kind == .release { return [] }

        var code: Int
        switch event.button {
        case .left: code = 0
        case .middle: code = 1
        case .right: code = 2
        case .none: code = 3
        case .wheelUp: code = 64
        case .wheelDown: code = 65
        case .wheelLeft: code = 66
        case .wheelRight: code = 67
        case .back: code = 128
        case .forward: code = 129
        }
        let sgr = modes.mouseEncoding == .sgr || modes.mouseEncoding == .sgrPixels
        // Outside SGR, a release does not say which button.
        if event.kind == .release && !sgr { code = 3 }
        if event.kind == .motion { code += 32 }
        if modes.mouseTracking != .x10 {
            if event.modifiers.contains(.shift) { code += 4 }
            if event.modifiers.contains(.alt) { code += 8 }
            if event.modifiers.contains(.control) { code += 16 }
        }

        let x = event.column + 1
        let y = event.row + 1
        switch modes.mouseEncoding {
        case .x10:
            guard 32 + x <= 255, 32 + y <= 255 else { return [] }
            return [0x1B, 0x5B, 0x4D, UInt8(32 + code), UInt8(32 + x), UInt8(32 + y)]
        case .utf8:
            guard 32 + x <= 2047, 32 + y <= 2047 else { return [] }
            var out: [UInt8] = [0x1B, 0x5B, 0x4D]
            for value in [32 + code, 32 + x, 32 + y] {
                out.append(contentsOf: String(Character(Unicode.Scalar(UInt32(value))!)).utf8)
            }
            return out
        case .sgr:
            return Array("\u{1B}[<\(code);\(x);\(y)\(event.kind == .release ? "m" : "M")".utf8)
        case .sgrPixels:
            return Array("\u{1B}[<\(code);\(event.pixelX);\(event.pixelY)\(event.kind == .release ? "m" : "M")".utf8)
        case .urxvt:
            return Array("\u{1B}[\(32 + code);\(x);\(y)M".utf8)
        }
    }
}

/// Focus reports (mode 1004) and pasting.
public enum InputEncoder {
    /// `CSI I` when the terminal gains focus and `CSI O` when it loses it, if the program
    /// asked for focus events.
    public static func focus(_ focused: Bool, modes: TerminalModes) -> [UInt8] {
        guard modes.focusEvents else { return [] }
        return Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8)
    }

    /// The bytes for pasting `text`. With bracketed paste (2004) the text is wrapped in
    /// `ESC [200~` and `ESC [201~`, and ESC characters inside it are removed, so pasted text
    /// cannot end the bracket early and run the rest as typed commands. Without it, line
    /// breaks become carriage returns, as if the lines were typed.
    public static func paste(_ text: String, modes: TerminalModes) -> [UInt8] {
        if modes.bracketedPaste {
            return Array("\u{1B}[200~".utf8) + text.utf8.filter { $0 != 0x1B } + Array("\u{1B}[201~".utf8)
        }
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                if previous != 0x0D { out.append(0x0D) }
            } else {
                out.append(byte)
            }
            previous = byte
        }
        return out
    }

    /// True when pasting `text` could run commands the user did not see: several lines, or
    /// control characters, without bracketed paste to mark it as a paste. The app asks
    /// before pasting such text.
    public static func pasteNeedsConfirmation(_ text: String, modes: TerminalModes) -> Bool {
        if modes.bracketedPaste { return false }
        return text.utf8.contains { $0 == 0x0A || $0 == 0x0D || ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F }
    }
}
