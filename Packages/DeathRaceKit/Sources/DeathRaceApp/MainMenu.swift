import AppKit

/// The menu bar. Every item sends its action up the responder chain (a nil target), so the
/// terminal view, its window controller or the app delegate answers, whichever is focused.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        for menu in [application(), shell(), edit(), view(), window(), help()] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    private static func application() -> NSMenu {
        let menu = NSMenu(title: "Death Race for Code")
        menu.addItem(item("About Death Race for Code", #selector(AppDelegate.showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.openSettings(_:)), ","))
        menu.addItem(
            item("Reload Configuration", #selector(AppDelegate.reloadConfiguration(_:)), ",", [.command, .shift]))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide Death Race for Code", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Death Race for Code", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func shell() -> NSMenu {
        let menu = NSMenu(title: "Shell")
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Bigger", #selector(TerminalWindowController.increaseFontSize(_:)), "+"))
        // ⌘= as well, so Bigger needs no Shift on layouts where + is a shifted =.
        let alsoBigger = item("Bigger", #selector(TerminalWindowController.increaseFontSize(_:)), "=")
        alsoBigger.isHidden = true
        alsoBigger.allowsKeyEquivalentWhenHidden = true
        menu.addItem(alsoBigger)
        menu.addItem(item("Smaller", #selector(TerminalWindowController.decreaseFontSize(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(TerminalWindowController.resetFontSize(_:)), "0"))
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        // As the windows menu it also gets AppKit's own items: the window list, and for tabs
        // Show Previous Tab, Show Next Tab, Move Tab to New Window and Merge All Windows.
        // ⌘⇧[ and ⌘⇧] switch tabs too (TerminalWindow), as in Terminal.
        NSApp.windowsMenu = menu
        return menu
    }

    private static func help() -> NSMenu {
        let menu = NSMenu(title: "Help")
        NSApp.helpMenu = menu
        return menu
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }
}
