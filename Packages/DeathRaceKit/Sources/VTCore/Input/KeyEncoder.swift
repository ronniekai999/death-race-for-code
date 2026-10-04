/// Turns key events into the bytes a program expects: xterm's encoding, or the Kitty keyboard
/// protocol (https://sw.kovidgoyal.net/kitty/keyboard-protocol/) once the program enables it.
///
/// The app encodes keys itself, from modes mirrored in each screen delta, so typing never
/// waits on the session thread.
public enum KeyEncoder {
    public static func encode(_ event: KeyEvent, modes: TerminalModes, kittyFlags: UInt8) -> [UInt8] {
        kittyFlags & KittyFlags.all == 0
            ? legacy(event, modes: modes)
            : kitty(event, modes: modes, flags: KittyFlags(rawValue: kittyFlags))
    }

    struct KittyFlags: OptionSet {
        let rawValue: UInt8
        static let disambiguate = KittyFlags(rawValue: 1)
        static let reportEventTypes = KittyFlags(rawValue: 2)
        static let reportAlternateKeys = KittyFlags(rawValue: 4)
        static let reportAllKeysAsEscapeCodes = KittyFlags(rawValue: 8)
        static let reportAssociatedText = KittyFlags(rawValue: 16)
        static let all: UInt8 = 0x1F
    }

    // MARK: - Legacy (xterm)

    static func legacy(_ event: KeyEvent, modes: TerminalModes) -> [UInt8] {
        // Command (super) has no legacy encoding; only the Kitty protocol carries it. Sent as
        // its plain character, a ⌘K that no menu item took would type a k.
        guard event.action != .release, !event.modifiers.contains(.command) else { return [] }
        let mods = event.modifiers.intersection([.shift, .alt, .control])
        let alt = mods.contains(.alt)
        let escape: [UInt8] = alt ? [0x1B] : []

        switch event.key {
        case .character(let scalar):
            if mods.contains(.control), let code = controlCode(for: scalar) { return escape + [code] }
            return event.text.isEmpty ? [] : escape + Array(event.text.utf8)
        case .enter:
            return escape + (modes.newline ? [0x0D, 0x0A] : [0x0D])
        case .tab:
            return escape + (mods.contains(.shift) ? Array("\u{1B}[Z".utf8) : [0x09])
        case .backspace:
            // DEL by default; DECBKM swaps it with BS, and Control swaps it back.
            return escape + [mods.contains(.control) != modes.backarrowSendsBackspace ? 0x08 : 0x7F]
        case .escape:
            return escape + [0x1B]
        case .keypad(let key):
            return legacyKeypad(key, event: event, modes: modes)
        case .modifier, .capsLock, .scrollLock, .numLock, .printScreen, .pause, .menu:
            return []
        default:
            guard let (number, final) = legacyCode(event.key) else { return [] }
            return legacyFunctional(number: number, final: final, mods: mods, modes: modes)
        }
    }

    /// `CSI 1 ; mods X`, `SS3 X`, `CSI X`, or `CSI n [; mods] ~`.
    private static func legacyFunctional(number: Int, final: Character, mods: KeyModifiers, modes: TerminalModes)
        -> [UInt8]
    {
        let value = Int(mods.rawValue) + 1
        if final == "~" { return csi(value > 1 ? "\(number);\(value)~" : "\(number)~") }
        if value > 1 { return csi("1;\(value)\(final)") }
        // F1-F4 are always SS3; arrows, Home and End only in application cursor mode.
        let ss3 = "PQRS".contains(final) || modes.applicationCursorKeys
        return ss3 ? Array("\u{1B}O\(final)".utf8) : csi(String(final))
    }

    private static func legacyCode(_ key: Key) -> (Int, Character)? {
        switch key {
        case .up: (1, "A")
        case .down: (1, "B")
        case .right: (1, "C")
        case .left: (1, "D")
        case .home: (1, "H")
        case .end: (1, "F")
        case .insert: (2, "~")
        case .delete: (3, "~")
        case .pageUp: (5, "~")
        case .pageDown: (6, "~")
        case .function(let n):
            switch n {
            case 1: (1, "P")
            case 2: (1, "Q")
            case 3: (1, "R")
            case 4: (1, "S")
            case 5...20: ([15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34][n - 5], "~")
            default: nil
            }
        default: nil
        }
    }

    private static func legacyKeypad(_ key: KeypadKey, event: KeyEvent, modes: TerminalModes) -> [UInt8] {
        let mods = event.modifiers.intersection([.shift, .alt, .control])
        if modes.applicationKeypad && mods.isEmpty, let final = applicationKeypadFinal(key) {
            return Array("\u{1B}O\(final)".utf8)
        }
        switch key {
        case .enter:
            return legacy(KeyEvent(.enter, modifiers: event.modifiers, action: event.action), modes: modes)
        case .left, .right, .up, .down, .home, .end, .pageUp, .pageDown, .insert, .delete:
            let main: Key =
                switch key {
                case .left: .left
                case .right: .right
                case .up: .up
                case .down: .down
                case .home: .home
                case .end: .end
                case .pageUp: .pageUp
                case .pageDown: .pageDown
                case .insert: .insert
                default: .delete
                }
            return legacy(KeyEvent(main, modifiers: event.modifiers, action: event.action), modes: modes)
        case .begin:
            return legacyFunctional(number: 1, final: "E", mods: mods, modes: modes)
        default:
            let text = event.text.isEmpty ? key.text ?? "" : event.text
            return (mods.contains(.alt) ? [0x1B] : []) + Array(text.utf8)
        }
    }

    private static func applicationKeypadFinal(_ key: KeypadKey) -> Character? {
        switch key {
        case .digit(let d): Character(Unicode.Scalar(UInt8(0x70) + d % 10))  // p...y
        case .decimal: "n"
        case .divide: "o"
        case .multiply: "j"
        case .subtract: "m"
        case .add: "k"
        case .enter: "M"
        case .equal: "X"
        case .separator: "l"
        default: nil
        }
    }

    /// The C0 control a Control chord sends in xterm, from the key's unshifted character.
    static func controlCode(for scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "a"..."z": UInt8(scalar.value - 0x60)
        case "A"..."Z": UInt8(scalar.value - 0x40)
        case "@", " ", "2", "`": 0x00
        case "[", "3": 0x1B
        case "\\", "4": 0x1C
        case "]", "5": 0x1D
        case "^", "6": 0x1E
        case "_", "-", "/", "7": 0x1F
        case "?", "8": 0x7F
        default: nil
        }
    }

    // MARK: - Kitty keyboard protocol

    /// Follows kitty's own encoder (kitty/key_encoding.c), the protocol's reference, except
    /// that an Escape release never sends a bare ESC.
    static func kitty(_ event: KeyEvent, modes: TerminalModes, flags: KittyFlags) -> [UInt8] {
        let disambiguate = flags.contains(.disambiguate)
        let reportAll = flags.contains(.reportAllKeysAsEscapeCodes)
        if event.action == .release && !flags.contains(.reportEventTypes) { return [] }
        switch event.key {
        case .modifier, .capsLock, .scrollLock, .numLock:
            // Modifier and lock keys on their own are only reported when every key is.
            guard reportAll else { return [] }
        default:
            break
        }

        var event = event
        // Without disambiguation, keypad keys are their ordinary counterparts.
        if !disambiguate && !reportAll, case .keypad(let keypad) = event.key, let ordinary = ordinaryKey(keypad) {
            event.key = ordinary
        }

        // Text typed without a modifier that changes its meaning goes as text, unless every
        // key must be an escape code.
        let hasText = isPrintable(event.text) && event.modifiers.intersection(textBreakingModifiers).isEmpty
        if !reportAll && hasText && event.action != .release { return Array(event.text.utf8) }

        if case .character(let scalar) = event.key {
            return kittyTextKey(event, code: lowercased(scalar), modes: modes, flags: flags)
        }
        return kittyFunctionalKey(event, modes: modes, flags: flags)
    }

    /// Control, Alt, Command, Hyper and Meta make a key mean something other than its text.
    private static let textBreakingModifiers: KeyModifiers = [.alt, .control, .command, .hyper, .meta]

    private static func isPrintable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// `CSI code[:shifted[:base]] [; mods[:event]] [; text] u`, or legacy bytes when the
    /// flags in force do not call for an escape code.
    private static func kittyTextKey(_ event: KeyEvent, code: UInt32, modes: TerminalModes, flags: KittyFlags)
        -> [UInt8]
    {
        let reportAll = flags.contains(.reportAllKeysAsEscapeCodes)
        let showEvent = flags.contains(.reportEventTypes) && event.action != .press

        var shifted: UInt32?
        if event.modifiers.contains(.shift), event.text.unicodeScalars.count == 1,
            let scalar = event.text.unicodeScalars.first, scalar.value != code
        {
            shifted = scalar.value
        }
        let base = event.baseLayoutKey.map(\.value).flatMap { $0 != code ? $0 : nil }
        let alternates = flags.contains(.reportAlternateKeys) && (shifted != nil || base != nil)
        let text = associatedText(event, flags: flags)

        if !showEvent && !alternates && text == nil {
            if event.modifiers.isEmpty && !reportAll {
                guard let scalar = Unicode.Scalar(code) else { return [] }
                return Array(String(Character(scalar)).utf8)
            }
            if !flags.contains(.disambiguate) && !reportAll {
                let bytes = legacy(event, modes: modes)
                if !bytes.isEmpty { return bytes }
            }
        }

        var out = "\u{1B}[\(code)"
        if alternates {
            out += ":" + (shifted.map(String.init) ?? "")
            if let base { out += ":\(base)" }
        }
        out += parameters(event, showEvent: showEvent, text: text)
        return Array((out + "u").utf8)
    }

    /// Everything that is not a text key: `CSI number [; mods[:event]] final`, leaving out a
    /// lone default 1, or legacy bytes where the protocol keeps them.
    private static func kittyFunctionalKey(_ event: KeyEvent, modes: TerminalModes, flags: KittyFlags) -> [UInt8] {
        let disambiguate = flags.contains(.disambiguate)
        let reportAll = flags.contains(.reportAllKeysAsEscapeCodes)
        let reportEvents = flags.contains(.reportEventTypes)
        if !disambiguate && !reportAll && !reportEvents {
            // Only alternate keys or associated text requested: functional keys are unchanged.
            return legacy(event, modes: modes)
        }
        if event.key == .escape && event.modifiers.isEmpty && !disambiguate && !reportAll {
            return event.action == .release ? [] : [0x1B]
        }
        // Enter, Tab and Backspace keep their legacy bytes unless every key is an escape
        // code, so a shell stays usable after a program dies with the protocol on.
        if !reportAll && event.modifiers.subtracting(.locks).isEmpty
            && (event.key == .enter || event.key == .tab || event.key == .backspace)
        {
            return event.action == .release ? [] : legacy(KeyEvent(event.key), modes: modes)
        }

        let (number, final) = kittyCode(event.key)
        let showEvent = reportEvents && event.action != .press
        let text = associatedText(event, flags: flags)
        let parameters = parameters(event, showEvent: showEvent, text: text)
        var out = "\u{1B}["
        if number != 1 || !parameters.isEmpty { out += "\(number)" }
        out += parameters
        out.append(final)
        return Array(out.utf8)
    }

    /// `;mods[:event][;text]`, or nothing when every field has its default.
    private static func parameters(_ event: KeyEvent, showEvent: Bool, text: String?) -> String {
        let value = Int(event.modifiers.rawValue) + 1
        guard value > 1 || showEvent || text != nil else { return "" }
        var out = ";"
        if value > 1 || showEvent { out += "\(value)" }
        if showEvent { out += ":\(event.action.rawValue)" }
        if let text { out += ";\(text)" }
        return out
    }

    /// The text field (flag 16): the key's text as code points, unless a modifier changed
    /// its meaning or the key was released.
    private static func associatedText(_ event: KeyEvent, flags: KittyFlags) -> String? {
        guard flags.contains(.reportAssociatedText), event.action != .release,
            event.modifiers.intersection(textBreakingModifiers).isEmpty, isPrintable(event.text)
        else { return nil }
        return event.text.unicodeScalars.map { String($0.value) }.joined(separator: ":")
    }

    private static func ordinaryKey(_ keypad: KeypadKey) -> Key? {
        switch keypad {
        case .enter: .enter
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .insert: .insert
        case .delete: .delete
        default: keypad.text.flatMap { $0.unicodeScalars.first }.map { .character($0) }
        }
    }

    /// Kitty's number and final byte for a key.
    static func kittyCode(_ key: Key) -> (number: UInt32, final: Character) {
        switch key {
        case .character(let scalar): (lowercased(scalar), "u")
        case .escape: (27, "u")
        case .enter: (13, "u")
        case .tab: (9, "u")
        case .backspace: (127, "u")
        case .insert: (2, "~")
        case .delete: (3, "~")
        case .left: (1, "D")
        case .right: (1, "C")
        case .up: (1, "A")
        case .down: (1, "B")
        case .pageUp: (5, "~")
        case .pageDown: (6, "~")
        case .home: (1, "H")
        case .end: (1, "F")
        case .capsLock: (57358, "u")
        case .scrollLock: (57359, "u")
        case .numLock: (57360, "u")
        case .printScreen: (57361, "u")
        case .pause: (57362, "u")
        case .menu: (57363, "u")
        case .function(let n):
            switch n {
            case 1: (1, "P")
            case 2: (1, "Q")
            case 3: (13, "~")
            case 4: (1, "S")
            case 5...12: ([15, 17, 18, 19, 20, 21, 23, 24][n - 5], "~")
            default: (57376 + UInt32(max(13, min(n, 35)) - 13), "u")
            }
        case .keypad(let key):
            switch key {
            case .digit(let d): (57399 + UInt32(d % 10), "u")
            case .decimal: (57409, "u")
            case .divide: (57410, "u")
            case .multiply: (57411, "u")
            case .subtract: (57412, "u")
            case .add: (57413, "u")
            case .enter: (57414, "u")
            case .equal: (57415, "u")
            case .separator: (57416, "u")
            case .left: (57417, "u")
            case .right: (57418, "u")
            case .up: (57419, "u")
            case .down: (57420, "u")
            case .pageUp: (57421, "u")
            case .pageDown: (57422, "u")
            case .home: (57423, "u")
            case .end: (57424, "u")
            case .insert: (57425, "u")
            case .delete: (57426, "u")
            case .begin: (1, "E")
            }
        case .modifier(let key):
            switch key {
            case .leftShift: (57441, "u")
            case .leftControl: (57442, "u")
            case .leftAlt: (57443, "u")
            case .leftCommand: (57444, "u")
            case .leftHyper: (57445, "u")
            case .leftMeta: (57446, "u")
            case .rightShift: (57447, "u")
            case .rightControl: (57448, "u")
            case .rightAlt: (57449, "u")
            case .rightCommand: (57450, "u")
            case .rightHyper: (57451, "u")
            case .rightMeta: (57452, "u")
            }
        }
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> UInt32 {
        ("A"..."Z").contains(scalar) ? scalar.value + 0x20 : scalar.value
    }

    private static func csi(_ body: String) -> [UInt8] {
        Array("\u{1B}[\(body)".utf8)
    }
}
