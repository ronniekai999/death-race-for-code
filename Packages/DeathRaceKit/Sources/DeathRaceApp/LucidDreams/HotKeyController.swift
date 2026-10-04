import AppCore
import AppKit
import Carbon

/// Registers one system-wide hotkey. Behind a seam so the controller's "read the setting,
/// register this key, re-register when it changes" logic is testable without Carbon; the real
/// registrar talks to Carbon's `RegisterEventHotKey`, which — unlike a CGEvent tap — needs no
/// Accessibility permission.
@MainActor
protocol HotKeyRegistrar: AnyObject {
    /// Registers `keyCode` + `modifiers` (a Carbon modifier mask) system-wide, replacing any
    /// previous one; `onPress` fires on each press. Returns whether it took.
    func register(keyCode: UInt32, modifiers: UInt32, onPress: @escaping @MainActor () -> Void) -> Bool
    /// Removes the hotkey, if any.
    func unregister()
}

/// Owns the app's Lucid Dreams hotkey: reads the `lucid-dreams-hotkey` setting, registers it,
/// and re-registers when the setting changes. Modelled on `SecureInputController` — a small,
/// `@MainActor` Carbon-backed controller the app delegate owns.
@MainActor
final class HotKeyController {
    private let registrar: any HotKeyRegistrar
    private let onTrigger: @MainActor () -> Void
    /// The shortcut now registered, or nil when the hotkey is off or couldn't be registered.
    private(set) var active: KeyShortcut?

    init(registrar: any HotKeyRegistrar = CarbonHotKeyRegistrar(), onTrigger: @escaping @MainActor () -> Void) {
        self.registrar = registrar
        self.onTrigger = onTrigger
    }

    /// Reads a `lucid-dreams-hotkey` value and (re-)registers it. "none", blank, or anything
    /// that isn't a usable shortcut turns the hotkey off. Returns whether a hotkey is now live.
    @discardableResult
    func apply(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let wanted: KeyShortcut? =
            (trimmed.isEmpty || trimmed.lowercased() == "none") ? nil : KeyShortcut(parsing: trimmed)
        // Leave an unchanged registration in place: a config reload shouldn't tear down and
        // reinstall the Carbon handler (needless churn, and a window where the hotkey is dead).
        if wanted == active { return active != nil }
        registrar.unregister()
        active = nil
        guard let shortcut = wanted, let keyCode = Self.keyCode(for: shortcut.key) else { return false }
        if registrar.register(
            keyCode: keyCode, modifiers: Self.carbonModifiers(shortcut.modifiers), onPress: onTrigger)
        {
            active = shortcut
            return true
        }
        return false
    }

    func stop() {
        registrar.unregister()
        active = nil
    }

    /// A `KeyShortcut.Modifiers` as Carbon's `cmdKey`/`optionKey`/… mask.
    static func carbonModifiers(_ modifiers: KeyShortcut.Modifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// A key's Carbon virtual key code, or nil for a key with none in the table.
    static func keyCode(for key: KeyShortcut.Key) -> UInt32? {
        switch key {
        case .character(let character): return characterKeyCodes[Character(character.lowercased())]
        case .left: return UInt32(kVK_LeftArrow)
        case .right: return UInt32(kVK_RightArrow)
        case .up: return UInt32(kVK_UpArrow)
        case .down: return UInt32(kVK_DownArrow)
        case .returnKey: return UInt32(kVK_Return)
        }
    }

    static let characterKeyCodes: [Character: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        " ": UInt32(kVK_Space),
        "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal), "+": UInt32(kVK_ANSI_Equal),
        "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket),
        ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote), ",": UInt32(kVK_ANSI_Comma),
        ".": UInt32(kVK_ANSI_Period), "/": UInt32(kVK_ANSI_Slash), "\\": UInt32(kVK_ANSI_Backslash),
        "`": UInt32(kVK_ANSI_Grave),
    ]
}

/// The real registrar: Carbon's `RegisterEventHotKey`, with one installed event handler that
/// routes presses back to the controller.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?
    private let id: UInt32
    private static var nextID: UInt32 = 1
    /// 'DRfc', this app's four-char hotkey signature.
    private static let signature: OSType = 0x4452_6663

    init() {
        id = Self.nextID
        Self.nextID += 1
    }

    func register(keyCode: UInt32, modifiers: UInt32, onPress: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        self.onPress = onPress
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        // One global hotkey today, so the handler fires onPress for any kEventHotKeyPressed it
        // receives. If a second CarbonHotKeyRegistrar is ever added, match the event's
        // EventHotKeyID (GetEventParameter, kEventParamDirectObject) against `id` here first,
        // or every registrar would fire on every hotkey.
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { registrar.onPress?() }
                return noErr
            }, 1, &type, context, &handler)
        guard installed == noErr else {
            self.onPress = nil
            return false
        }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registered = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        if registered != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        onPress = nil
    }
}
