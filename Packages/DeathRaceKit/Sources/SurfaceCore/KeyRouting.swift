import ConfigKit
import VTCore

/// macOS virtual key codes (Carbon's kVK_ constants) and what they mean to a terminal.
public enum MacKeyCode {
    /// Keys that type no text, by key code.
    public static func key(for code: UInt16) -> Key? {
        switch code {
        case 0x24: return .enter
        case 0x30: return .tab
        case 0x33: return .backspace
        case 0x35: return .escape
        case 0x72: return .insert  // Help, where PC keyboards have Insert
        case 0x75: return .delete
        case 0x73: return .home
        case 0x77: return .end
        case 0x74: return .pageUp
        case 0x79: return .pageDown
        case 0x7B: return .left
        case 0x7C: return .right
        case 0x7D: return .down
        case 0x7E: return .up
        case 0x39: return .capsLock
        case 0x47: return .numLock  // Clear, where PC keypads have Num Lock
        default: break
        }
        if let number = functionKeys[code] { return .function(number) }
        if let key = keypad[code] { return .keypad(key) }
        return modifiers[code]
    }

    static let functionKeys: [UInt16: Int] = [
        0x7A: 1, 0x78: 2, 0x63: 3, 0x76: 4, 0x60: 5, 0x61: 6, 0x62: 7, 0x64: 8, 0x65: 9, 0x6D: 10, 0x67: 11,
        0x6F: 12, 0x69: 13, 0x6B: 14, 0x71: 15, 0x6A: 16, 0x40: 17, 0x4F: 18, 0x50: 19, 0x5A: 20,
    ]

    static let keypad: [UInt16: KeypadKey] = [
        0x52: .digit(0), 0x53: .digit(1), 0x54: .digit(2), 0x55: .digit(3), 0x56: .digit(4), 0x57: .digit(5),
        0x58: .digit(6), 0x59: .digit(7), 0x5B: .digit(8), 0x5C: .digit(9), 0x41: .decimal, 0x43: .multiply,
        0x45: .add, 0x4B: .divide, 0x4C: .enter, 0x4E: .subtract, 0x51: .equal, 0x5F: .separator,
    ]

    static let modifiers: [UInt16: Key] = [
        0x38: .modifier(.leftShift), 0x3C: .modifier(.rightShift), 0x3B: .modifier(.leftControl),
        0x3E: .modifier(.rightControl), 0x3A: .modifier(.leftAlt), 0x3D: .modifier(.rightAlt),
        0x37: .modifier(.leftCommand), 0x36: .modifier(.rightCommand),
    ]

    /// What each letter, digit and punctuation key types on a US keyboard without Shift: the
    /// "base layout key" the Kitty protocol reports for other layouts.
    public static func usLayoutCharacter(for code: UInt16) -> Unicode.Scalar? {
        usLayout[code]
    }

    static let usLayout: [UInt16: Unicode.Scalar] = [
        0x00: "a", 0x0B: "b", 0x08: "c", 0x02: "d", 0x0E: "e", 0x03: "f", 0x05: "g", 0x04: "h", 0x22: "i",
        0x26: "j", 0x28: "k", 0x25: "l", 0x2E: "m", 0x2D: "n", 0x1F: "o", 0x23: "p", 0x0C: "q", 0x0F: "r",
        0x01: "s", 0x11: "t", 0x20: "u", 0x09: "v", 0x0D: "w", 0x07: "x", 0x10: "y", 0x06: "z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8",
        0x19: "9", 0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'", 0x32: "`",
        0x2B: ",", 0x2F: ".", 0x2C: "/", 0x31: " ",
    ]
}

/// NSEvent's modifier flags as bits, with the device-dependent bits that tell left from right.
public struct EventFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let capsLock = EventFlags(rawValue: 1 << 16)
    public static let shift = EventFlags(rawValue: 1 << 17)
    public static let control = EventFlags(rawValue: 1 << 18)
    public static let option = EventFlags(rawValue: 1 << 19)
    public static let command = EventFlags(rawValue: 1 << 20)
    public static let numericPad = EventFlags(rawValue: 1 << 21)
    public static let function = EventFlags(rawValue: 1 << 23)
    /// IOKit's device-dependent bits (NX_DEVICELCTLKEYMASK and the rest): which of each pair
    /// of modifier keys is down.
    public static let leftControl = EventFlags(rawValue: 0x01)
    public static let leftShift = EventFlags(rawValue: 0x02)
    public static let rightShift = EventFlags(rawValue: 0x04)
    public static let leftCommand = EventFlags(rawValue: 0x08)
    public static let rightCommand = EventFlags(rawValue: 0x10)
    public static let leftOption = EventFlags(rawValue: 0x20)
    public static let rightOption = EventFlags(rawValue: 0x40)
    public static let rightControl = EventFlags(rawValue: 0x2000)
}

/// A key press as AppKit reports it, with nothing from AppKit in it.
public struct KeyPress: Sendable, Equatable {
    public var keyCode: UInt16
    public var flags: EventFlags
    /// What the key types with every modifier applied (`NSEvent.characters`): with Option it
    /// is the layout's special character, with Control a control character.
    public var characters: String
    /// What it types with only Shift and Caps Lock applied
    /// (`characters(byApplyingModifiers:)` with Option and Control removed).
    public var plainCharacters: String
    /// What it types with no modifiers (`characters(byApplyingModifiers: [])`), which names
    /// the key.
    public var unmodifiedCharacters: String
    public var isRepeat: Bool

    public init(
        keyCode: UInt16, flags: EventFlags, characters: String, plainCharacters: String, unmodifiedCharacters: String,
        isRepeat: Bool = false
    ) {
        self.keyCode = keyCode
        self.flags = flags
        self.characters = characters
        self.plainCharacters = plainCharacters
        self.unmodifiedCharacters = unmodifiedCharacters
        self.isRepeat = isRepeat
    }
}

/// Decides where a key press goes, before AppKit's text system sees it.
///
/// Typing goes through the input method (`interpretKeyEvents`), which composes accents,
/// Japanese and the rest; the terminal then sends what it inserts. Keys that are commands to
/// the terminal skip it and go straight to the encoder: control chords, Option keys acting as
/// Meta, and keys that type nothing (arrows, function keys, Return, Escape). While an input
/// method is composing, it gets everything.
public enum KeyRouting {
    public enum Route: Sendable, Equatable {
        /// Encode this event now.
        case encode(KeyEvent)
        /// Hand the press to the input method.
        case inputMethod
    }

    public static func route(_ press: KeyPress, optionAsMeta: OptionAsMeta, composing: Bool) -> Route {
        if composing { return .inputMethod }
        let flags = press.flags
        let modifiers = modifiers(flags, optionAsMeta)
        let action: KeyEvent.Action = press.isRepeat ? .repeat : .press

        if let key = MacKeyCode.key(for: press.keyCode) {
            return .encode(KeyEvent(key, modifiers: modifiers, action: action))
        }
        let commandLike = flags.contains(.control) || flags.contains(.command) || modifiers.contains(.alt)
        guard commandLike, let key = characterKey(press) else { return .inputMethod }
        return .encode(
            KeyEvent(
                key, modifiers: modifiers, action: action, text: press.plainCharacters,
                baseLayoutKey: baseLayoutKey(press, key)))
    }

    /// The release of `press`'s key. The encoder sends it only to programs that asked the
    /// Kitty protocol for releases. Nil while an input method composes: the press was its.
    public static func release(_ press: KeyPress, optionAsMeta: OptionAsMeta, composing: Bool) -> KeyEvent? {
        guard !composing, let key = MacKeyCode.key(for: press.keyCode) ?? characterKey(press) else { return nil }
        return KeyEvent(
            key, modifiers: modifiers(press.flags, optionAsMeta), action: .release, text: "",
            baseLayoutKey: baseLayoutKey(press, key))
    }

    /// A modifier key going down or up on its own (AppKit's flagsChanged), with the modifiers
    /// as they are after it. The encoder sends it only to programs that asked the Kitty
    /// protocol for every key. Nil for other keys (Caps Lock, Fn).
    public static func modifierKey(_ press: KeyPress, optionAsMeta: OptionAsMeta) -> KeyEvent? {
        guard case .modifier(let modifier)? = MacKeyCode.key(for: press.keyCode), let bit = deviceBit(modifier) else {
            return nil
        }
        let isDown = press.flags.contains(bit)
        return KeyEvent(
            .modifier(modifier), modifiers: modifiers(press.flags, optionAsMeta), action: isDown ? .press : .release,
            text: "")
    }

    private static func deviceBit(_ modifier: ModifierKey) -> EventFlags? {
        switch modifier {
        case .leftShift: .leftShift
        case .rightShift: .rightShift
        case .leftControl: .leftControl
        case .rightControl: .rightControl
        case .leftAlt: .leftOption
        case .rightAlt: .rightOption
        case .leftCommand: .leftCommand
        case .rightCommand: .rightCommand
        case .leftHyper, .leftMeta, .rightHyper, .rightMeta: nil
        }
    }

    /// The modifiers held, as the encoder knows them; Option only when it acts as Meta.
    static func modifiers(_ flags: EventFlags, _ optionAsMeta: OptionAsMeta) -> KeyModifiers {
        var modifiers = KeyModifiers()
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if optionIsMeta(flags, optionAsMeta) { modifiers.insert(.alt) }
        return modifiers
    }

    /// The event for text the input method inserted for `press`: what a plain key typed, or
    /// what composing produced. Option is not reported: it was used to type the text.
    public static func textEvent(_ text: String, press: KeyPress?) -> KeyEvent {
        guard let press, let key = characterKey(press) else {
            let scalar = text.unicodeScalars.first ?? " "
            return KeyEvent(.character(scalar), text: text)
        }
        var modifiers = KeyModifiers()
        if press.flags.contains(.shift) { modifiers.insert(.shift) }
        if press.flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        return KeyEvent(
            key, modifiers: modifiers, action: press.isRepeat ? .repeat : .press, text: text,
            baseLayoutKey: baseLayoutKey(press, key))
    }

    /// Whether the Option key held for `flags` acts as Meta. Events without the device bits
    /// (made by other apps or by accessibility tools) count as the left key.
    public static func optionIsMeta(_ flags: EventFlags, _ setting: OptionAsMeta) -> Bool {
        guard flags.contains(.option) else { return false }
        let left = flags.contains(.leftOption)
        let right = flags.contains(.rightOption)
        if !left && !right { return setting.usesLeft }
        return (left && setting.usesLeft) || (right && setting.usesRight)
    }

    /// The key a character press is: what it types unmodified, lowercased.
    static func characterKey(_ press: KeyPress) -> Key? {
        let source = press.unmodifiedCharacters.isEmpty ? press.plainCharacters : press.unmodifiedCharacters
        guard var scalar = source.unicodeScalars.first ?? MacKeyCode.usLayoutCharacter(for: press.keyCode) else {
            return nil
        }
        if ("A"..."Z").contains(scalar) { scalar = Unicode.Scalar(scalar.value + 0x20)! }
        return .character(scalar)
    }

    private static func baseLayoutKey(_ press: KeyPress, _ key: Key) -> Unicode.Scalar? {
        guard case .character(let scalar) = key, let us = MacKeyCode.usLayoutCharacter(for: press.keyCode) else {
            return nil
        }
        return us == scalar ? nil : us
    }
}
