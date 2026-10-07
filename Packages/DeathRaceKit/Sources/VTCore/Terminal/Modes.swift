public enum MouseTracking: UInt8, Sendable {
    case none
    /// 9: presses only.
    case x10
    /// 1000: presses and releases.
    case normal
    /// 1002: plus motion while a button is down.
    case buttonEvent
    /// 1003: plus all motion.
    case anyEvent
}

public enum MouseEncoding: UInt8, Sendable {
    case x10
    /// 1005
    case utf8
    /// 1006
    case sgr
    /// 1015
    case urxvt
    /// 1016: SGR with pixel coordinates.
    case sgrPixels
}

/// The modes programs toggle with SM/RM and DECSET/DECRST.
public struct TerminalModes: Sendable, Equatable {
    // ANSI modes
    /// IRM (4): printing inserts instead of overwriting.
    public var insert = false
    /// LNM (20): LF also returns the carriage.
    public var newline = false

    // DEC private modes
    /// DECCKM (1): cursor keys send SS3 sequences.
    public var applicationCursorKeys = false
    /// DECSCNM (5): the whole screen in reverse video.
    public var reverseVideo = false
    /// DECOM (6): cursor addressing is relative to the scroll region.
    public var origin = false
    /// DECAWM (7)
    public var autowrap = true
    /// DECARM (8): reported, never acted on (key repeat belongs to macOS).
    public var autorepeat = true
    /// 12: the cursor blinks.
    public var cursorBlink = false
    /// DECTCEM (25)
    public var cursorVisible = true
    /// 45: backspace at the left margin moves to the end of the previous line, if that line
    /// wrapped onto this one (xterm 383 and later).
    public var reverseWraparound = false
    /// 1045: backspace at the left margin moves to the end of the previous line whatever
    /// it is, and from the top margin to the bottom one (xterm's original mode 45).
    public var reverseWraparoundExtended = false
    /// DECNKM (66), also set by DECKPAM.
    public var applicationKeypad = false
    /// DECBKM (67): the Backspace key sends BS instead of DEL.
    public var backarrowSendsBackspace = false
    /// DECLRMM (69): the left and right margins bound printing, scrolling and the cursor.
    /// `Terminal.setPrivateMode` is what sets it, because turning it off also puts the
    /// margins back, which this struct cannot reach.
    public var leftRightMargins = false
    public var mouseTracking = MouseTracking.none
    public var mouseEncoding = MouseEncoding.x10
    /// 1004
    public var focusEvents = false
    /// 1007: the wheel scrolls by sending arrow keys on the alternate screen.
    public var alternateScroll = false
    /// 1036: Option sends ESC before the character.
    public var metaSendsEscape = true
    /// 2004
    public var bracketedPaste = false
    /// 2026: hold rendering until the program finishes a frame.
    public var synchronizedOutput = false
    /// 2027: graphemes, not code points, decide width (ZWJ emoji are one character).
    public var graphemeClustering = true
    /// 2031: tell the program when the system switches between light and dark.
    public var colorSchemeUpdates = false

    public init() {}

    /// DEC private modes handled by `TerminalModes` itself. Screen switches (47, 1047, 1048,
    /// 1049) and column mode (3) are handled by the terminal.
    mutating func setDEC(_ mode: UInt16, _ on: Bool) -> Bool {
        switch mode {
        case 1: applicationCursorKeys = on
        case 5: reverseVideo = on
        case 6: origin = on
        case 7: autowrap = on
        case 8: autorepeat = on
        case 9: setMouse(.x10, on)
        case 12: cursorBlink = on
        case 25: cursorVisible = on
        case 45: reverseWraparound = on
        case 1045: reverseWraparoundExtended = on
        case 66: applicationKeypad = on
        case 67: backarrowSendsBackspace = on
        case 1000: setMouse(.normal, on)
        case 1002: setMouse(.buttonEvent, on)
        case 1003: setMouse(.anyEvent, on)
        case 1004: focusEvents = on
        case 1005: setEncoding(.utf8, on)
        case 1006: setEncoding(.sgr, on)
        case 1007: alternateScroll = on
        case 1015: setEncoding(.urxvt, on)
        case 1016: setEncoding(.sgrPixels, on)
        case 1036: metaSendsEscape = on
        case 2004: bracketedPaste = on
        case 2026: synchronizedOutput = on
        case 2027: graphemeClustering = on
        case 2031: colorSchemeUpdates = on
        default: return false
        }
        return true
    }

    func dec(_ mode: UInt16) -> Bool? {
        switch mode {
        case 1: applicationCursorKeys
        case 5: reverseVideo
        case 6: origin
        case 7: autowrap
        case 8: autorepeat
        case 9: mouseTracking == .x10
        case 12: cursorBlink
        case 25: cursorVisible
        case 45: reverseWraparound
        case 1045: reverseWraparoundExtended
        case 66: applicationKeypad
        case 67: backarrowSendsBackspace
        case 69: leftRightMargins
        case 1000: mouseTracking == .normal
        case 1002: mouseTracking == .buttonEvent
        case 1003: mouseTracking == .anyEvent
        case 1004: focusEvents
        case 1005: mouseEncoding == .utf8
        case 1006: mouseEncoding == .sgr
        case 1007: alternateScroll
        case 1015: mouseEncoding == .urxvt
        case 1016: mouseEncoding == .sgrPixels
        case 1036: metaSendsEscape
        case 2004: bracketedPaste
        case 2026: synchronizedOutput
        case 2027: graphemeClustering
        case 2031: colorSchemeUpdates
        default: nil
        }
    }

    mutating func setANSI(_ mode: UInt16, _ on: Bool) -> Bool {
        switch mode {
        case 4: insert = on
        case 20: newline = on
        default: return false
        }
        return true
    }

    func ansi(_ mode: UInt16) -> Bool? {
        switch mode {
        case 4: insert
        case 20: newline
        default: nil
        }
    }

    private mutating func setMouse(_ tracking: MouseTracking, _ on: Bool) {
        if on {
            mouseTracking = tracking
        } else if mouseTracking == tracking {
            mouseTracking = .none
        }
    }

    private mutating func setEncoding(_ encoding: MouseEncoding, _ on: Bool) {
        if on {
            mouseEncoding = encoding
        } else if mouseEncoding == encoding {
            mouseEncoding = .x10
        }
    }
}

/// The cursor's shape, from DECSCUSR.
public enum CursorShape: UInt8, Sendable {
    case block, underline, bar
}
