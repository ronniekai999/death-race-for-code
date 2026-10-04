import Testing

@testable import VTCore

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

private func key(
    _ k: Key, _ mods: KeyModifiers = [], _ action: KeyEvent.Action = .press, text: String? = nil,
    base: Unicode.Scalar? = nil, modes: TerminalModes = TerminalModes(), kitty flags: UInt8 = 0
) -> String {
    let event = KeyEvent(k, modifiers: mods, action: action, text: text, baseLayoutKey: base)
    return String(decoding: KeyEncoder.encode(event, modes: modes, kittyFlags: flags), as: UTF8.self)
}

@Suite struct LegacyKeyTests {
    @Test func textKeys() {
        #expect(key(.character("a")) == "a")
        #expect(key(.character("a"), .shift, text: "A") == "A")
        #expect(key(.character("e"), text: "é") == "é")
        #expect(key(.character("a"), text: "") == "")
    }

    @Test func controlChords() {
        #expect(key(.character("a"), .control) == "\u{1}")
        #expect(key(.character("z"), [.control, .shift], text: "Z") == "\u{1A}")
        #expect(key(.character(" "), .control) == "\u{0}")
        #expect(key(.character("["), .control) == "\u{1B}")
        #expect(key(.character("\\"), .control) == "\u{1C}")
        #expect(key(.character("]"), .control) == "\u{1D}")
        #expect(key(.character("/"), .control) == "\u{1F}")
        #expect(key(.character("8"), .control) == "\u{7F}")
        // No control code: the character itself.
        #expect(key(.character("1"), .control) == "1")
    }

    @Test func altPrefixesEscape() {
        #expect(key(.character("b"), .alt) == "\u{1B}b")
        #expect(key(.character("b"), [.alt, .control]) == "\u{1B}\u{2}")
        #expect(key(.backspace, .alt) == "\u{1B}\u{7F}")
        #expect(key(.enter, .alt) == "\u{1B}\r")
    }

    @Test func editingKeys() {
        #expect(key(.enter) == "\r")
        var lnm = TerminalModes()
        lnm.newline = true
        #expect(key(.enter, modes: lnm) == "\r\n")
        #expect(key(.tab) == "\t")
        #expect(key(.tab, .shift) == "\u{1B}[Z")
        #expect(key(.tab, [.shift, .alt]) == "\u{1B}\u{1B}[Z")
        #expect(key(.backspace) == "\u{7F}")
        #expect(key(.backspace, .control) == "\u{8}")
        var bkm = TerminalModes()
        bkm.backarrowSendsBackspace = true
        #expect(key(.backspace, modes: bkm) == "\u{8}")
        #expect(key(.backspace, .control, modes: bkm) == "\u{7F}")
        #expect(key(.escape) == "\u{1B}")
    }

    @Test func cursorKeysFollowDECCKM() {
        #expect(key(.up) == "\u{1B}[A")
        #expect(key(.left) == "\u{1B}[D")
        #expect(key(.home) == "\u{1B}[H")
        #expect(key(.end) == "\u{1B}[F")
        var app = TerminalModes()
        app.applicationCursorKeys = true
        #expect(key(.up, modes: app) == "\u{1B}OA")
        #expect(key(.end, modes: app) == "\u{1B}OF")
        // Modifiers always use the CSI form.
        #expect(key(.up, .control, modes: app) == "\u{1B}[1;5A")
        #expect(key(.right, [.shift, .alt]) == "\u{1B}[1;4C")
    }

    @Test func functionAndNavigationKeys() {
        #expect(key(.function(1)) == "\u{1B}OP")
        #expect(key(.function(4)) == "\u{1B}OS")
        #expect(key(.function(1), .shift) == "\u{1B}[1;2P")
        #expect(key(.function(5)) == "\u{1B}[15~")
        #expect(key(.function(12)) == "\u{1B}[24~")
        #expect(key(.function(12), .control) == "\u{1B}[24;5~")
        #expect(key(.function(20)) == "\u{1B}[34~")
        #expect(key(.function(21)) == "")
        #expect(key(.delete) == "\u{1B}[3~")
        #expect(key(.pageUp, .shift) == "\u{1B}[5;2~")
        #expect(key(.insert) == "\u{1B}[2~")
    }

    @Test func keypad() {
        #expect(key(.keypad(.digit(7))) == "7")
        #expect(key(.keypad(.enter)) == "\r")
        var app = TerminalModes()
        app.applicationKeypad = true
        #expect(key(.keypad(.digit(7)), modes: app) == "\u{1B}Ow")
        #expect(key(.keypad(.enter), modes: app) == "\u{1B}OM")
        #expect(key(.keypad(.add), modes: app) == "\u{1B}Ok")
        #expect(key(.keypad(.up)) == "\u{1B}[A")
    }

    @Test func commandHasNoLegacyEncoding() {
        // A ⌘ chord no menu item took must not type its letter, nor pass for a Meta arrow.
        #expect(key(.character("k"), .command, text: "k") == "")
        #expect(key(.left, .command) == "")
        #expect(key(.enter, [.command, .shift]) == "")
        #expect(key(.keypad(.digit(1)), .command) == "")
        // The Kitty protocol reports it, as super.
        #expect(key(.character("k"), .command, text: "k", kitty: 0b1) == "\u{1B}[107;9u")
    }

    @Test func releasesAndModifierKeysSendNothing() {
        #expect(key(.character("a"), [], .release) == "")
        #expect(key(.modifier(.leftShift), .shift) == "")
        #expect(key(.character("a"), [], .repeat) == "a")
    }
}

@Suite struct KittyKeyTests {
    @Test func disambiguateKeepsPlainTextAndEditingKeys() {
        #expect(key(.character("a"), kitty: 1) == "a")
        #expect(key(.character("a"), .shift, text: "A", kitty: 1) == "A")
        #expect(key(.enter, kitty: 1) == "\r")
        #expect(key(.tab, kitty: 1) == "\t")
        #expect(key(.backspace, kitty: 1) == "\u{7F}")
    }

    @Test func disambiguateEncodesWhatLegacyCannotTellApart() {
        #expect(key(.escape, kitty: 1) == "\u{1B}[27u")
        #expect(key(.character("a"), .control, kitty: 1) == "\u{1B}[97;5u")
        #expect(key(.character("a"), .alt, kitty: 1) == "\u{1B}[97;3u")
        #expect(key(.character("i"), [.control, .shift], text: "I", kitty: 1) == "\u{1B}[105;6u")
        #expect(key(.enter, .shift, kitty: 1) == "\u{1B}[13;2u")
        #expect(key(.tab, .shift, kitty: 1) == "\u{1B}[9;2u")
        #expect(key(.backspace, .control, kitty: 1) == "\u{1B}[127;5u")
        // Caps Lock alone does not make plain typing an escape code.
        #expect(key(.character("a"), .capsLock, text: "A", kitty: 1) == "A")
    }

    @Test func functionalKeys() {
        #expect(key(.up, kitty: 1) == "\u{1B}[A")
        var app = TerminalModes()
        app.applicationCursorKeys = true
        #expect(key(.up, modes: app, kitty: 1) == "\u{1B}[A")
        #expect(key(.up, .control, kitty: 1) == "\u{1B}[1;5A")
        #expect(key(.function(1), kitty: 1) == "\u{1B}[P")
        #expect(key(.function(3), kitty: 1) == "\u{1B}[13~")
        #expect(key(.function(1), .control, kitty: 1) == "\u{1B}[1;5P")
        #expect(key(.function(13), kitty: 1) == "\u{1B}[57376u")
        #expect(key(.delete, .shift, kitty: 1) == "\u{1B}[3;2~")
        #expect(key(.keypad(.enter), kitty: 1) == "\u{1B}[57414u")
        #expect(key(.keypad(.digit(1)), kitty: 1) == "1")
    }

    @Test func eventTypes() {
        #expect(key(.character("a"), .control, .release, kitty: 1) == "")
        #expect(key(.character("a"), .control, .repeat, kitty: 3) == "\u{1B}[97;5:2u")
        #expect(key(.character("a"), .control, .release, kitty: 3) == "\u{1B}[97;5:3u")
        #expect(key(.character("a"), [], .release, kitty: 3) == "\u{1B}[97;1:3u")
        #expect(key(.up, [], .release, kitty: 3) == "\u{1B}[1;1:3A")
        // Typing still types, and Enter keeps no release so `reset` works after a crash.
        #expect(key(.character("a"), [], .press, kitty: 3) == "a")
        #expect(key(.enter, [], .release, kitty: 3) == "")
        // Event types alone leave presses in legacy form, but repeats and releases need
        // the escape code to say what they are.
        #expect(key(.character("a"), .control, kitty: 2) == "\u{1}")
        #expect(key(.character("a"), .control, .repeat, kitty: 2) == "\u{1B}[97;5:2u")
        #expect(key(.escape, kitty: 2) == "\u{1B}")
        #expect(key(.escape, [], .release, kitty: 2) == "")
        #expect(key(.up, kitty: 2) == "\u{1B}[A")
    }

    @Test func lockModifiersOnlyStayOutOfText() {
        // Typing with Caps Lock still types; escape codes carry the lock bits, as in kitty.
        #expect(key(.up, .capsLock, kitty: 1) == "\u{1B}[1;65A")
        #expect(key(.character("a"), [.control, .capsLock], kitty: 1) == "\u{1B}[97;69u")
        #expect(key(.enter, .capsLock, kitty: 1) == "\r")
    }

    @Test func alternateKeysAloneOnlyChangeWhatHasAnAlternate() {
        #expect(key(.character("a"), .control, kitty: 4) == "\u{1}")
        #expect(key(.character("a"), [.control, .shift], text: "A", kitty: 4) == "\u{1B}[97:65;6u")
        #expect(key(.up, kitty: 4) == "\u{1B}[A")
        #expect(key(.keypad(.enter), kitty: 4) == "\r")
    }

    @Test func everyKeyAsAnEscapeCode() {
        #expect(key(.character("a"), kitty: 8) == "\u{1B}[97u")
        #expect(key(.character("a"), .shift, text: "A", kitty: 8) == "\u{1B}[97;2u")
        #expect(key(.enter, kitty: 8) == "\u{1B}[13u")
        #expect(key(.modifier(.leftShift), .shift, kitty: 8) == "\u{1B}[57441;2u")
        #expect(key(.character("a"), .capsLock, text: "A", kitty: 8) == "\u{1B}[97;65u")
        #expect(key(.keypad(.digit(1)), kitty: 8) == "\u{1B}[57400u")
    }

    @Test func alternateKeysAndText() {
        #expect(key(.character("a"), .shift, text: "A", kitty: 1 | 4 | 8) == "\u{1B}[97:65;2u")
        #expect(key(.character("1"), .shift, text: "!", kitty: 1 | 4 | 8) == "\u{1B}[49:33;2u")
        #expect(key(.character("ф"), text: "ф", base: "a", kitty: 4 | 8) == "\u{1B}[1092::97u")
        #expect(key(.character("a"), kitty: 8 | 16) == "\u{1B}[97;;97u")
        #expect(key(.character("a"), .shift, text: "A", kitty: 8 | 16) == "\u{1B}[97;2;65u")
        #expect(key(.character("a"), .control, kitty: 8 | 16) == "\u{1B}[97;5u")
    }
}

@Suite struct MouseFocusPasteTests {
    private func modes(_ tracking: MouseTracking, _ encoding: MouseEncoding = .x10) -> TerminalModes {
        var m = TerminalModes()
        m.mouseTracking = tracking
        m.mouseEncoding = encoding
        return m
    }

    private func mouse(_ e: MouseEvent, _ m: TerminalModes) -> [UInt8] { MouseEncoder.encode(e, modes: m) }

    @Test func nothingWithoutTracking() {
        #expect(mouse(MouseEvent(.press, button: .left, column: 0, row: 0), TerminalModes()).isEmpty)
    }

    @Test func x10Encoding() {
        let m = modes(.normal)
        #expect(mouse(MouseEvent(.press, button: .left, column: 0, row: 0), m) == [0x1B, 0x5B, 0x4D, 32, 33, 33])
        #expect(mouse(MouseEvent(.release, button: .left, column: 2, row: 1), m) == [0x1B, 0x5B, 0x4D, 35, 35, 34])
        #expect(
            mouse(MouseEvent(.press, button: .right, column: 0, row: 0, modifiers: .control), m)
                == [0x1B, 0x5B, 0x4D, 32 + 2 + 16, 33, 33])
        #expect(mouse(MouseEvent(.press, button: .wheelUp, column: 0, row: 0), m) == [0x1B, 0x5B, 0x4D, 96, 33, 33])
        // Too far right for one byte.
        #expect(mouse(MouseEvent(.press, button: .left, column: 300, row: 0), m).isEmpty)
    }

    @Test func trackingModesFilterEvents() {
        let motion = MouseEvent(.motion, button: .none, column: 1, row: 1)
        let drag = MouseEvent(.motion, button: .left, column: 1, row: 1)
        let release = MouseEvent(.release, button: .left, column: 1, row: 1)
        #expect(mouse(release, modes(.x10)).isEmpty)
        #expect(mouse(drag, modes(.normal)).isEmpty)
        #expect(mouse(drag, modes(.buttonEvent, .sgr)) == bytes("\u{1B}[<32;2;2M"))
        #expect(mouse(motion, modes(.buttonEvent, .sgr)).isEmpty)
        #expect(mouse(motion, modes(.anyEvent, .sgr)) == bytes("\u{1B}[<35;2;2M"))
    }

    @Test func sgrAndOtherEncodings() {
        let press = MouseEvent(.press, button: .middle, column: 299, row: 9, pixelX: 2400, pixelY: 160)
        let release = MouseEvent(.release, button: .middle, column: 299, row: 9)
        #expect(mouse(press, modes(.normal, .sgr)) == bytes("\u{1B}[<1;300;10M"))
        #expect(mouse(release, modes(.normal, .sgr)) == bytes("\u{1B}[<1;300;10m"))
        #expect(mouse(press, modes(.normal, .sgrPixels)) == bytes("\u{1B}[<1;2400;160M"))
        #expect(mouse(press, modes(.normal, .urxvt)) == bytes("\u{1B}[33;300;10M"))
        #expect(mouse(press, modes(.normal, .utf8)) == [0x1B, 0x5B, 0x4D, 33] + bytes("\u{14C}") + [42])
        #expect(mouse(MouseEvent(.release, button: .wheelUp, column: 0, row: 0), modes(.normal, .sgr)).isEmpty)
    }

    @Test func focusReports() {
        #expect(InputEncoder.focus(true, modes: TerminalModes()).isEmpty)
        var m = TerminalModes()
        m.focusEvents = true
        #expect(InputEncoder.focus(true, modes: m) == bytes("\u{1B}[I"))
        #expect(InputEncoder.focus(false, modes: m) == bytes("\u{1B}[O"))
    }

    @Test func pasting() {
        var m = TerminalModes()
        #expect(InputEncoder.paste("ls\r\nrm -rf x\n", modes: m) == bytes("ls\rrm -rf x\r"))
        #expect(InputEncoder.pasteNeedsConfirmation("one line", modes: m) == false)
        #expect(InputEncoder.pasteNeedsConfirmation("two\nlines", modes: m))
        m.bracketedPaste = true
        #expect(InputEncoder.paste("a\nb", modes: m) == bytes("\u{1B}[200~a\nb\u{1B}[201~"))
        // A paste cannot close the bracket early.
        #expect(
            InputEncoder.paste("x\u{1B}[201~rm -rf ~\n", modes: m) == bytes("\u{1B}[200~x[201~rm -rf ~\n\u{1B}[201~"))
        #expect(InputEncoder.pasteNeedsConfirmation("two\nlines", modes: m) == false)
    }
}
