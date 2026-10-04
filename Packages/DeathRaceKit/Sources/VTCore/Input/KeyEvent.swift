/// A key press, repeat or release, in terms the encoder understands. The app builds these
/// from `NSEvent`s; nothing here depends on AppKit, so encoding is tested on Linux.
public struct KeyEvent: Sendable, Equatable {
    public enum Action: UInt8, Sendable {
        case press = 1
        case `repeat` = 2
        case release = 3
    }

    public var key: Key
    public var modifiers: KeyModifiers
    public var action: Action
    /// What the key types with the current layout and modifiers, before Control is applied:
    /// "a", "A", "é", "!". Empty for keys that type nothing (arrows, a dead key mid-compose).
    /// When Option composes characters instead of acting as Alt, the app passes the composed
    /// text and leaves `.alt` out of `modifiers`.
    public var text: String
    /// The key in the US layout, for layouts where it differs ("a" for the key that types
    /// "ф"). Kitty reports it as the base layout key.
    public var baseLayoutKey: Unicode.Scalar?

    public init(
        _ key: Key, modifiers: KeyModifiers = [], action: Action = .press, text: String? = nil,
        baseLayoutKey: Unicode.Scalar? = nil
    ) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
        if let text {
            self.text = text
        } else if case .character(let scalar) = key {
            self.text = String(Character(scalar))
        } else if case .keypad(let keypad) = key, let keypadText = keypad.text {
            self.text = keypadText
        } else {
            self.text = ""
        }
        self.baseLayoutKey = baseLayoutKey
    }
}

/// Modifier state, with the bit values of the Kitty keyboard protocol (its modifier field
/// is this value plus one).
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    /// Alt, or Option acting as Meta.
    public static let alt = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    /// Command; Kitty calls it super.
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let hyper = KeyModifiers(rawValue: 1 << 4)
    public static let meta = KeyModifiers(rawValue: 1 << 5)
    public static let capsLock = KeyModifiers(rawValue: 1 << 6)
    public static let numLock = KeyModifiers(rawValue: 1 << 7)

    /// Caps Lock and Num Lock.
    public static let locks: KeyModifiers = [.capsLock, .numLock]
}

public enum Key: Hashable, Sendable {
    /// A key that types a character. The scalar is what the key types without Shift ("a"
    /// for both a and A, "1" for 1 and !), which is how Kitty identifies it.
    case character(Unicode.Scalar)
    case enter, tab, backspace, escape
    case insert, delete, home, end, pageUp, pageDown
    case up, down, left, right
    /// F1 through F35.
    case function(Int)
    case keypad(KeypadKey)
    case modifier(ModifierKey)
    case capsLock, scrollLock, numLock, printScreen, pause, menu
}

public enum KeypadKey: Hashable, Sendable {
    case digit(UInt8)
    case decimal, divide, multiply, subtract, add, enter, equal, separator
    case left, right, up, down, pageUp, pageDown, home, end, insert, delete, begin

    /// The text the key types in numeric mode, if any.
    var text: String? {
        switch self {
        case .digit(let d): String(d % 10)
        case .decimal: "."
        case .divide: "/"
        case .multiply: "*"
        case .subtract: "-"
        case .add: "+"
        case .equal: "="
        case .separator: ","
        default: nil
        }
    }
}

public enum ModifierKey: Hashable, Sendable {
    case leftShift, leftControl, leftAlt, leftCommand, leftHyper, leftMeta
    case rightShift, rightControl, rightAlt, rightCommand, rightHyper, rightMeta
}
