import AppCore
import AppKit

/// The menu bar, built from `ActionCatalog`, so every title and shortcut matches what Hear
/// Me Calling and Settings › Keys show. Every item sends its action up the responder chain
/// (a nil target), so the terminal view, its window's controller or the app delegate
/// answers, whichever is focused.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        var menus = [application(), shell(), edit(), view(), window()]
        #if DEBUG
            menus.append(debug())
        #endif
        menus.append(help())
        for menu in menus {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    private static func application() -> NSMenu {
        let menu = NSMenu(title: "Death Race for Code")
        add([.about], to: menu)
        menu.addItem(.separator())
        add([.settings, .openSettingsFile, .reloadConfiguration], to: menu)
        menu.addItem(.separator())
        // In the app menu, where Terminal keeps it.
        add([.secureKeyboardEntry], to: menu)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        add([.hide, .hideOthers, .showAll], to: menu)
        menu.addItem(.separator())
        add([.quit], to: menu)
        return menu
    }

    private static func shell() -> NSMenu {
        let menu = NSMenu(title: "Shell")
        add([.newWindow, .newTab, .newHost, .openWRLD, .toggleLucidDreams], to: menu)
        menu.addItem(.separator())
        add([.splitRight, .splitDown], to: menu)
        menu.addItem(.separator())
        add([.armedAndDangerous], to: menu)
        menu.addItem(.separator())
        add([.closePane, .closeTab, .closeWindow], to: menu)
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        add([.copy, .paste, .selectAll], to: menu)
        menu.addItem(.separator())
        add([.saveSelectionToWishingWell], to: menu)
        menu.addItem(.separator())
        add([.clearToStart, .clearScrollback], to: menu)
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        add([.hearMeCalling, .toggleSidebar], to: menu)
        menu.addItem(.separator())
        add([.bigger, .smaller, .actualSize], to: menu)
        menu.addItem(.separator())
        add([.zoomPane, .equalizePanes], to: menu)
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        add([.minimize, .zoomWindow], to: menu)
        menu.addItem(.separator())
        add([.showPreviousTab, .showNextTab, .moveTabToNewWindow], to: menu)
        menu.addItem(.separator())
        add([.previousPane, .nextPane, .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown], to: menu)
        menu.addItem(.separator())
        add([.moveDividerLeft, .moveDividerRight, .moveDividerUp, .moveDividerDown], to: menu)
        menu.addItem(.separator())
        add([.bringAllToFront], to: menu)
        // As the windows menu it also lists the windows.
        NSApp.windowsMenu = menu
        return menu
    }

    private static func help() -> NSMenu {
        let menu = NSMenu(title: "Help")
        NSApp.helpMenu = menu
        return menu
    }

    #if DEBUG
        /// Debug builds only: measuring.
        private static func debug() -> NSMenu {
            let menu = NSMenu(title: "Debug")
            menu.addItem(item("Log Frame Stats", #selector(PitLaneWindowController.logFrameStats(_:))))
            menu.addItem(.separator())
            // The legendsd spike (docs/SPIKE.md).
            menu.addItem(item("Run Spike Probe in App", #selector(AppDelegate.runSpikeProbe(_:))))
            menu.addItem(item("Register Spike Agent", #selector(AppDelegate.registerSpikeAgent(_:))))
            menu.addItem(item("Unregister Spike Agent", #selector(AppDelegate.unregisterSpikeAgent(_:))))
            return menu
        }
    #endif

    /// The catalog's actions as items, with their hidden alternates (⌘= for Bigger).
    private static func add(_ ids: [ActionID], to menu: NSMenu) {
        for id in ids {
            let action = ActionCatalog.action(id)
            let item = NSMenuItem(title: action.menuTitle, action: selector(id), keyEquivalent: "")
            if let shortcut = action.shortcut { set(shortcut, on: item) }
            menu.addItem(item)
            for alternate in action.alternates {
                let hidden = NSMenuItem(title: action.menuTitle, action: selector(id), keyEquivalent: "")
                set(alternate, on: hidden)
                hidden.isHidden = true
                hidden.allowsKeyEquivalentWhenHidden = true
                menu.addItem(hidden)
            }
        }
    }

    private static func set(_ shortcut: KeyShortcut, on item: NSMenuItem) {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        item.keyEquivalent = keyEquivalent(shortcut.key)
        item.keyEquivalentModifierMask = flags
    }

    static func keyEquivalent(_ key: KeyShortcut.Key) -> String {
        func function(_ code: Int) -> String {
            UnicodeScalar(UInt32(code)).map { String(Character($0)) } ?? ""
        }
        switch key {
        case .character(let character): return String(character)
        case .left: return function(NSLeftArrowFunctionKey)
        case .right: return function(NSRightArrowFunctionKey)
        case .up: return function(NSUpArrowFunctionKey)
        case .down: return function(NSDownArrowFunctionKey)
        case .returnKey: return "\r"
        }
    }

    /// What each action sends. A switch, so every selector is checked by the compiler.
    static func selector(_ id: ActionID) -> Selector {
        switch id {
        case .about: #selector(AppDelegate.showAbout(_:))
        case .settings: #selector(AppDelegate.openSettings(_:))
        case .openSettingsFile: #selector(AppDelegate.openSettingsFile(_:))
        case .reloadConfiguration: #selector(AppDelegate.reloadConfiguration(_:))
        case .secureKeyboardEntry: #selector(AppDelegate.toggleSecureKeyboardEntry(_:))
        case .hide: #selector(NSApplication.hide(_:))
        case .hideOthers: #selector(NSApplication.hideOtherApplications(_:))
        case .showAll: #selector(NSApplication.unhideAllApplications(_:))
        case .quit: #selector(NSApplication.terminate(_:))
        case .newWindow: #selector(AppDelegate.newWindow(_:))
        case .newTab: #selector(PitLaneWindowController.newTab(_:))
        case .newHost: #selector(AppDelegate.newHost(_:))
        case .openWRLD: #selector(AppDelegate.openWRLD(_:))
        case .toggleLucidDreams: #selector(AppDelegate.toggleLucidDreams(_:))
        case .splitRight: #selector(PitLaneWindowController.splitRight(_:))
        case .splitDown: #selector(PitLaneWindowController.splitDown(_:))
        case .closePane: #selector(PitLaneWindowController.closePane(_:))
        case .closeTab: #selector(PitLaneWindowController.closeTab(_:))
        case .closeWindow: #selector(PitLaneWindowController.closeWindow(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .saveSelectionToWishingWell: #selector(PitLaneWindowController.saveSelectionToWishingWell(_:))
        case .clearToStart: #selector(PitLaneWindowController.clearToStart(_:))
        case .clearScrollback: #selector(PitLaneWindowController.clearScrollback(_:))
        case .hearMeCalling: #selector(PitLaneWindowController.showHearMeCalling(_:))
        case .toggleSidebar: #selector(PitLaneWindowController.toggleSidebar(_:))
        case .bigger: #selector(PitLaneWindowController.increaseFontSize(_:))
        case .smaller: #selector(PitLaneWindowController.decreaseFontSize(_:))
        case .actualSize: #selector(PitLaneWindowController.resetFontSize(_:))
        case .armedAndDangerous: #selector(PitLaneWindowController.toggleArmed(_:))
        case .zoomPane: #selector(PitLaneWindowController.togglePaneZoom(_:))
        case .equalizePanes: #selector(PitLaneWindowController.equalizePanes(_:))
        case .minimize: #selector(NSWindow.performMiniaturize(_:))
        case .zoomWindow: #selector(NSWindow.performZoom(_:))
        case .showPreviousTab: #selector(PitLaneWindowController.showPreviousTab(_:))
        case .showNextTab: #selector(PitLaneWindowController.showNextTab(_:))
        case .moveTabToNewWindow: #selector(PitLaneWindowController.detachTab(_:))
        case .previousPane: #selector(PitLaneWindowController.selectPreviousPane(_:))
        case .nextPane: #selector(PitLaneWindowController.selectNextPane(_:))
        case .focusPaneLeft: #selector(PitLaneWindowController.selectPaneLeft(_:))
        case .focusPaneRight: #selector(PitLaneWindowController.selectPaneRight(_:))
        case .focusPaneUp: #selector(PitLaneWindowController.selectPaneAbove(_:))
        case .focusPaneDown: #selector(PitLaneWindowController.selectPaneBelow(_:))
        case .moveDividerLeft: #selector(PitLaneWindowController.moveDividerLeft(_:))
        case .moveDividerRight: #selector(PitLaneWindowController.moveDividerRight(_:))
        case .moveDividerUp: #selector(PitLaneWindowController.moveDividerUp(_:))
        case .moveDividerDown: #selector(PitLaneWindowController.moveDividerDown(_:))
        case .bringAllToFront: #selector(NSApplication.arrangeInFront(_:))
        }
    }

    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }
}
