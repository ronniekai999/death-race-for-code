import AppCore
import AppKit
import ConfigKit
import QuartzCore
import TerminalUI
import VTCore

/// The row the traffic lights share: tab pills, the + pill, Hear Me Calling and the 999.
/// Empty space drags the window, and a double click there does what System Settings says.
@MainActor
final class TitleBarView: NSView {
    let strip = TabStripView()
    let paletteButton = PaletteButtonView()
    private let wordmark = WordmarkView()
    private var chrome: Chrome
    /// Where the pills start: after the traffic lights, or at the margin in full screen.
    var leadingInset: CGFloat = 84 {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }

    init(chrome: Chrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(strip)
        addSubview(paletteButton)
        addSubview(wordmark)
        setChrome(chrome)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TitleBarView is created in code")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func setChrome(_ chrome: Chrome) {
        self.chrome = chrome
        layer?.backgroundColor = chrome.colors.groundDeep.cgColor
        strip.setChrome(chrome)
        paletteButton.chrome = chrome
        wordmark.chrome = chrome
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        wordmark.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let margin: CGFloat = 16
        let gap: CGFloat = 14
        let height = bounds.height
        let mark = wordmark.intrinsicContentSize
        wordmark.frame = NSRect(
            x: bounds.width - margin - mark.width, y: ((height - mark.height) / 2).rounded(), width: mark.width,
            height: mark.height)
        let button = paletteButton.intrinsicContentSize
        paletteButton.frame = NSRect(
            x: wordmark.frame.minX - gap - button.width, y: ((height - button.height) / 2).rounded(),
            width: button.width, height: button.height)
        let stripWidth = max(paletteButton.frame.minX - gap - leadingInset, 0)
        strip.frame = NSRect(x: leadingInset, y: 0, width: stripWidth, height: height)
    }

    /// The bottom hairline.
    override func draw(_ dirtyRect: NSRect) {
        chrome.colors.line.nsColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performDoubleClickAction(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// What double-clicking a title bar does, from System Settings › Desktop & Dock.
    static func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "" {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// The 999 in the theme's neon. Clicks fall through to the row, so it drags the window.
@MainActor
final class WordmarkView: NSView {
    var chrome: Chrome? {
        didSet {
            image = nil
            needsDisplay = true
        }
    }
    private var image: CGImage?
    private var imageScale: CGFloat = 0
    static let size: CGFloat = 20

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize {
        let scale = window?.backingScaleFactor ?? 2
        guard let image = render(scale: scale) else { return NSSize(width: 40, height: Self.size) }
        return NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    private func render(scale: CGFloat) -> CGImage? {
        if let image, imageScale == scale { return image }
        image = chrome?.wordmark(size: Self.size, scale: scale)
        imageScale = scale
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
            let image = render(scale: window?.backingScaleFactor ?? 2)
        else { return }
        // CGContext draws images upright in unflipped coordinates; this view is flipped.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// "Hear Me Calling ⇧⌘P": opens the palette.
@MainActor
final class PaletteButtonView: NSView {
    var chrome: Chrome? {
        didSet { needsDisplay = true }
    }
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let title = "Hear Me Calling"
    static let shortcut = ActionCatalog.action(.hearMeCalling).shortcut?.description ?? ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolTip = "Search actions, tabs and themes"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaletteButtonView is created in code")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let title = (Self.title as NSString).size(withAttributes: [.font: Self.font]).width
        let key = (Self.shortcut as NSString).size(withAttributes: [.font: Self.keyFont]).width
        return NSSize(width: (12 + 16 + 6 + title + 8 + key + 10 + 12).rounded(.up), height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
                userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSApp.sendAction(#selector(PitLaneWindowController.showHearMeCalling(_:)), to: nil, from: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors = chrome?.colors else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if hovering {
            colors.surfaceHover.nsColor.setFill()
            shape.fill()
        }
        colors.lineStrong.nsColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        var x: CGFloat = 12
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colors.inkMuted.nsColor]))
        if let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        {
            symbol.draw(
                in: NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += 16 + 6
        let title = NSAttributedString(
            string: Self.title, attributes: [.font: Self.font, .foregroundColor: colors.inkMuted.nsColor])
        let titleSize = title.size()
        title.draw(at: NSPoint(x: x, y: ((bounds.height - titleSize.height) / 2).rounded()))
        x += titleSize.width + 8
        KeyCap.draw(Self.shortcut, at: NSPoint(x: x, y: 0), height: bounds.height, colors: colors, font: Self.keyFont)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { Self.title }
    override func accessibilityPerformPress() -> Bool {
        NSApp.sendAction(#selector(PitLaneWindowController.showHearMeCalling(_:)), to: nil, from: self)
    }
}

/// A key cap, as the mockups draw them: small semibold text in a rounded outline.
enum KeyCap {
    @MainActor
    @discardableResult
    static func draw(_ text: String, at origin: NSPoint, height: CGFloat, colors: ChromeColors, font: NSFont) -> CGFloat
    {
        let label = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: colors.inkMuted.nsColor])
        let size = label.size()
        let cap = NSRect(
            x: origin.x, y: ((height - 16) / 2).rounded(), width: (size.width + 10).rounded(.up), height: 16)
        let shape = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        colors.lineStrong.nsColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        label.draw(at: NSPoint(x: cap.minX + 5, y: cap.minY + ((cap.height - size.height) / 2).rounded()))
        return cap.width
    }
}
