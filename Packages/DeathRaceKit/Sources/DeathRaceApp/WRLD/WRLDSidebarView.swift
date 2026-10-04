import AppCore
import AppKit
import ConfigKit
import Vault

/// The WRLD sidebar (⌃⌘S), as on the Main board: Search WRLD, then Legends, WRLD's groups
/// and hosts, Wishing Well and Come & Go, then Add host and the tagline. It draws a
/// `SidebarModel` and says what was clicked; the window decides what that does.
@MainActor
final class WRLDSidebarView: NSView, NSTextFieldDelegate {
    /// What a click did: a row, with ⌘ held or not.
    var onRow: ((SidebarModel.Row, _ commandHeld: Bool) -> Void)?
    /// The menu for a row.
    var menuForRow: ((SidebarModel.Row) -> NSMenu?)?
    var onSearch: ((String) -> Void)?
    var onAddHost: (() -> Void)?

    private let search = NSTextField()
    private let scroll = NSScrollView()
    private let list = SidebarListView()
    private let addHost = NSButton(title: "Add host", target: nil, action: nil)
    private var chrome: Chrome

    static let width: CGFloat = 220
    private static let margin: CGFloat = 12
    private static let searchHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 76

    init(chrome: Chrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        search.placeholderString = "Search WRLD"
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 13, weight: .medium)
        search.delegate = self
        search.setAccessibilityLabel("Search WRLD")
        addSubview(search)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        addSubview(scroll)
        addHost.isBordered = false
        addHost.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addHost.imagePosition = .imageLeading
        addHost.target = self
        addHost.action = #selector(addHostClicked)
        addSubview(addHost)
        list.onRow = { [weak self] row, command in self?.onRow?(row, command) }
        list.menuForRow = { [weak self] row in self?.menuForRow?(row) }
        setChrome(chrome)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("WRLD")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WRLDSidebarView is created in code")
    }

    override var isFlipped: Bool { true }

    var model: SidebarModel {
        get { list.model }
        set { list.model = newValue }
    }

    func setChrome(_ chrome: Chrome) {
        self.chrome = chrome
        list.chrome = chrome
        search.textColor = chrome.colors.ink.nsColor
        search.placeholderAttributedString = NSAttributedString(
            string: "Search WRLD",
            attributes: [.foregroundColor: chrome.colors.inkFaint.nsColor, .font: NSFont.systemFont(ofSize: 13)])
        addHost.attributedTitle = NSAttributedString(
            string: " Add host",
            attributes: [
                .foregroundColor: chrome.colors.inkMuted.nsColor,
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            ])
        addHost.contentTintColor = chrome.colors.inkMuted.nsColor
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let margin = Self.margin
        let inner = bounds.width - margin * 2
        // The field sits in the box `draw` paints, past the magnifier.
        search.frame = NSRect(x: margin + 28, y: margin + 6, width: max(inner - 34, 0), height: 18)
        let listTop = margin + Self.searchHeight + 8
        scroll.frame = NSRect(
            x: 0, y: listTop, width: bounds.width, height: max(bounds.height - listTop - Self.footerHeight, 0))
        list.frame.size.width = scroll.contentSize.width
        list.layoutRows()
        addHost.sizeToFit()
        addHost.frame.origin = NSPoint(
            x: ((bounds.width - addHost.frame.width) / 2).rounded(), y: bounds.height - Self.footerHeight + 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = chrome.colors
        colors.groundDeep.nsColor.setFill()
        bounds.fill()
        colors.line.nsColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        // The search box and its magnifier.
        let box = NSRect(
            x: Self.margin, y: Self.margin, width: bounds.width - Self.margin * 2, height: Self.searchHeight)
        let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        colors.ground.nsColor.setFill()
        shape.fill()
        colors.lineStrong.nsColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        if let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [colors.inkFaint.nsColor])))
        {
            glass.draw(in: NSRect(x: box.minX + 10, y: box.midY - 6, width: 12, height: 12))
        }
        // "LEGENDS NEVER DIE", spaced out, under Add host.
        let tagline = NSAttributedString(
            string: "LEGENDS NEVER DIE",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .kern: 3,
                .foregroundColor: colors.inkFaint.nsColor,
            ])
        let size = tagline.size()
        tagline.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - 24))
    }

    func controlTextDidChange(_ notification: Notification) {
        onSearch?(search.stringValue)
    }

    @objc private func addHostClicked() {
        onAddHost?()
    }
}

/// The rows, drawn in one view: section eyebrows, then hosts, groups, snippets and
/// tunnels. Each row is an accessibility element of its own, with a press action.
@MainActor
final class SidebarListView: NSView {
    var model = SidebarModel(.init(vault: Vault())) {
        didSet {
            guard model != oldValue else { return }
            layoutRows()
            needsDisplay = true
        }
    }
    var chrome: Chrome? {
        didSet { needsDisplay = true }
    }
    var onRow: ((SidebarModel.Row, Bool) -> Void)?
    var menuForRow: ((SidebarModel.Row) -> NSMenu?)?

    /// Where each eyebrow and row is.
    private var items: [(rect: NSRect, kind: Item)] = []
    private var hovered: String?
    private var pressed: String?
    private var elements: [SidebarRowElement] = []

    enum Item {
        case eyebrow(SidebarModel.Section)
        case row(SidebarModel.Row)
        case hint(String)
    }

    static let rowHeight: CGFloat = 28
    static let eyebrowHeight: CGFloat = 24
    private static let margin: CGFloat = 12

    override var isFlipped: Bool { true }

    /// Rows top to bottom, and the view's height to hold them.
    func layoutRows() {
        var y: CGFloat = 4
        var laid: [(rect: NSRect, kind: Item)] = []
        let width = bounds.width
        for (index, section) in model.sections.enumerated() {
            if index > 0 { y += 10 }
            laid.append((NSRect(x: 0, y: y, width: width, height: Self.eyebrowHeight), .eyebrow(section)))
            y += Self.eyebrowHeight
            if section.kind == .wrld && section.rows.isEmpty && !model.isSearching {
                laid.append((NSRect(x: 0, y: y, width: width, height: 44), .hint(SidebarModel.emptyHint)))
                y += 44
            }
            for row in section.rows {
                laid.append((NSRect(x: 0, y: y, width: width, height: Self.rowHeight), .row(row)))
                y += Self.rowHeight
            }
        }
        items = laid
        let height = max(y + 8, enclosingScrollView?.contentSize.height ?? 0)
        if frame.height != height { setFrameSize(NSSize(width: width, height: height)) }
        rebuildElements()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors = chrome?.colors else { return }
        for item in items where item.rect.intersects(dirtyRect) {
            switch item.kind {
            case .eyebrow(let section): drawEyebrow(section, in: item.rect, colors: colors)
            case .row(let row): drawRow(row, in: item.rect, colors: colors)
            case .hint(let text):
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: colors.inkMuted.nsColor,
                        .paragraphStyle: style,
                    ]
                ).draw(in: item.rect.insetBy(dx: Self.margin + 8, dy: 4))
            }
        }
    }

    private func drawEyebrow(_ section: SidebarModel.Section, in rect: NSRect, colors: ChromeColors) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .kern: 1.6,
            .foregroundColor: colors.inkMuted.nsColor,
        ]
        let title = NSAttributedString(string: section.title.uppercased(), attributes: attributes)
        let size = title.size()
        let y = rect.minY + ((rect.height - size.height) / 2).rounded()
        title.draw(at: NSPoint(x: rect.minX + Self.margin + 8, y: y))
        let count = NSAttributedString(string: String(section.count), attributes: attributes)
        count.draw(at: NSPoint(x: rect.maxX - Self.margin - 8 - count.size().width, y: y))
    }

    private func drawRow(_ row: SidebarModel.Row, in rect: NSRect, colors: ChromeColors) {
        let box = rect.insetBy(dx: Self.margin - 4, dy: 1)
        if hovered == row.id || pressed == row.id {
            colors.surface.nsColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        }
        var x = box.minX + 8 + (row.isIndented ? 14 : 0)
        let midY = rect.midY
        // The leading mark: a dot, a group's chevron, Wishing Well's », Come & Go's ⇄.
        switch row.kind {
        case .host:
            drawDot(row.dot ?? .unknown, at: NSPoint(x: x + 4, y: midY), colors: colors)
            x += 16
        case .group(_, let expanded):
            drawSymbol(expanded ? "chevron.down" : "chevron.right", at: x, midY: midY, color: colors.inkFaint)
            x += 16
        case .snippet:
            drawGlyph("»", at: x, midY: midY, color: colors.accent)
            x += 16
        case .tunnel:
            drawGlyph("⇄", at: x, midY: midY, color: colors.accent)
            x += 18
        }
        // The end: the meta, or a tunnel's dot.
        var end = box.maxX - 8
        if case .tunnel = row.kind {
            drawDot(row.dot ?? .unknown, at: NSPoint(x: end - 4, y: midY), colors: colors, size: 6)
            end -= 14
        } else if let meta = row.meta {
            let text = NSAttributedString(
                string: meta,
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: colors.inkFaint.nsColor])
            let size = text.size()
            end -= size.width
            text.draw(at: NSPoint(x: end, y: midY - size.height / 2))
            end -= 8
        }
        // A snippet's fields, as small chips after its name, while they fit.
        let offline = row.dot == .silent
        let title = NSAttributedString(
            string: row.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: (offline ? colors.inkMuted : colors.ink).nsColor,
            ])
        let titleSize = title.size()
        let titleWidth = min(titleSize.width, max(end - x, 0))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let truncated = NSMutableAttributedString(attributedString: title)
        truncated.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: truncated.length))
        truncated.draw(
            with: NSRect(x: x, y: midY - titleSize.height / 2, width: titleWidth, height: titleSize.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        x += titleWidth + 6
        for field in row.fields {
            let chip = NSAttributedString(
                string: field,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: colors.accent.nsColor,
                ])
            let size = chip.size()
            let chipRect = NSRect(x: x, y: midY - 8, width: size.width + 10, height: 16)
            guard chipRect.maxX <= end else { break }
            colors.lineStrong.nsColor.setStroke()
            let outline = NSBezierPath(roundedRect: chipRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            outline.lineWidth = 1
            outline.stroke()
            chip.draw(at: NSPoint(x: chipRect.minX + 5, y: midY - size.height / 2))
            x = chipRect.maxX + 4
        }
    }

    private func drawDot(_ dot: HostStatus.Dot, at center: NSPoint, colors: ChromeColors, size: CGFloat = 8) {
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let circle = NSBezierPath(ovalIn: rect)
        switch dot {
        case .connected, .answering:
            (dot == .connected ? colors.accent : colors.accent.mixed(with: colors.groundDeep, by: 0.2)).nsColor
                .setFill()
            circle.fill()
        case .silent:
            colors.inkFaint.nsColor.setFill()
            circle.fill()
        case .unknown:
            colors.lineStrong.nsColor.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    private func drawSymbol(_ name: String, at x: CGFloat, midY: CGFloat, color: RGB) {
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color.nsColor])))
        else { return }
        let size = image.size
        image.draw(in: NSRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height))
    }

    private func drawGlyph(_ glyph: String, at x: CGFloat, midY: CGFloat, color: RGB) {
        let text = NSAttributedString(
            string: glyph,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: color.nsColor])
        let size = text.size()
        text.draw(at: NSPoint(x: x, y: midY - size.height / 2))
    }

    // MARK: - The mouse

    private func row(at point: NSPoint) -> SidebarModel.Row? {
        for item in items where item.rect.contains(point) {
            if case .row(let row) = item.kind { return row }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let id = row(at: convert(event.locationInWindow, from: nil))?.id
        guard id != hovered else { return }
        hovered = id
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = row(at: convert(event.locationInWindow, from: nil))?.id
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            needsDisplay = true
        }
        guard let row = row(at: convert(event.locationInWindow, from: nil)), row.id == pressed else { return }
        onRow?(row, event.modifierFlags.contains(.command))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuForRow?(row)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Accessibility

    private func rebuildElements() {
        elements = items.compactMap { item in
            guard case .row(let row) = item.kind else { return nil }
            let element = SidebarRowElement(row: row, frame: item.rect, list: self)
            return element
        }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { elements }

    fileprivate func press(_ row: SidebarModel.Row) {
        onRow?(row, false)
    }

    fileprivate func screenFrame(of rect: NSRect) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
}

/// One row, to VoiceOver: a button with the row's words, which a press clicks.
@MainActor
final class SidebarRowElement: NSAccessibilityElement {
    let row: SidebarModel.Row
    private let rect: NSRect
    private weak var list: SidebarListView?

    init(row: SidebarModel.Row, frame: NSRect, list: SidebarListView) {
        self.row = row
        rect = frame
        self.list = list
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.accessibilityLabel)
        setAccessibilityParent(list)
    }

    override func accessibilityFrame() -> NSRect {
        list?.screenFrame(of: rect) ?? .zero
    }

    override func accessibilityPerformPress() -> Bool {
        list?.press(row)
        return true
    }
}

/// A menu item that runs a closure: the sidebar's menus, built per row.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, _ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is created in code")
    }

    @objc private func fire() {
        handler()
    }
}
