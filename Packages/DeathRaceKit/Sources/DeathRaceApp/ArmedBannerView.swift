import AppCore
import AppKit
import ConfigKit
import VTCore

/// Armed and Dangerous's banner across the top of an armed tab: where typing goes, and how
/// to stop. One line, so the panes give up as little room as they can while it shows. Esc
/// isn't the way out: it belongs to the programs typing goes to.
@MainActor
final class ArmedBannerView: NSView {
    /// "Typing goes to 3 panes: prod-api-1, prod-api-2 and prod-api-3."
    var sentence: String {
        didSet {
            guard sentence != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel("Armed and Dangerous. \(sentence)")
        }
    }
    var chrome: Chrome {
        didSet { needsDisplay = true }
    }
    var onStop: (() -> Void)?
    private let stop = NSButton(title: "Stop", target: nil, action: nil)

    static let height: CGFloat = 36
    static let keys = "⇧⌘I"
    private static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let keyFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let margin: CGFloat = 12

    init(sentence: String, chrome: Chrome) {
        self.sentence = sentence
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        stop.bezelStyle = .push
        stop.controlSize = .small
        stop.target = self
        stop.action = #selector(stopClicked)
        stop.toolTip = "Stop Armed and Dangerous (\(Self.keys))"
        addSubview(stop)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Armed and Dangerous. \(sentence)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ArmedBannerView is created in code")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        stop.sizeToFit()
        stop.frame.origin = NSPoint(
            x: bounds.width - Self.margin - stop.frame.width, y: ((bounds.height - stop.frame.height) / 2).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = chrome.colors
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Chrome.cardRadius, yRadius: Chrome.cardRadius)
        NSGradient(colors: colors.armedTint.map(\.nsColor))?.draw(in: shape, angle: 0)
        colors.warning.nsColor.withAlphaComponent(0.5).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        var x = Self.margin
        if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [colors.warning.nsColor])))
        {
            let size = symbol.size
            symbol.draw(
                in: NSRect(
                    x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height))
            x += size.width + 8
        }

        // The keys that stop it, just before Stop.
        let keysWidth = KeyCap.width(Self.keys, font: Self.keyFont)
        let keysX = stop.frame.minX - 8 - keysWidth
        KeyCap.draw(Self.keys, at: NSPoint(x: keysX, y: 0), height: bounds.height, colors: colors, font: Self.keyFont)

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(
            string: "Armed and Dangerous", attributes: [.font: Self.titleFont, .foregroundColor: colors.ink.nsColor])
        text.append(
            NSAttributedString(
                string: "   " + sentence, attributes: [.font: Self.font, .foregroundColor: colors.inkMuted.nsColor]))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let size = text.size()
        let rect = NSRect(
            x: x, y: ((bounds.height - size.height) / 2).rounded(), width: max(min(size.width, keysX - 12 - x), 0),
            height: size.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    @objc private func stopClicked() {
        onStop?()
    }
}
