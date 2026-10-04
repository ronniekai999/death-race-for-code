import AppCore
import AppKit
import ConfigKit
import TerminalUI
import VTCore

/// What a pane's header says.
struct PaneHeader: Equatable {
    var program = ""
    /// Where the pane is, with the home directory as `~`.
    var directory: String?
    var branch: String?
    /// The N of ⌥⌘N, which focuses the pane.
    var number: Int?
    /// Armed and Dangerous, while the tab is armed: whether typing reaches this pane.
    var armed: Armed?

    enum Armed: Equatable {
        case receiving, leftOut
    }

    /// "⌥⌘2".
    var keys: String? { number.map { "⌥⌘\($0)" } }
}

/// The row along a card's top while its tab is split: the program, where it is, its branch,
/// and the keys that focus it; while the tab is armed, whether typing reaches the pane, which
/// a click changes. Drawn again only when what it says changes.
@MainActor
final class PaneHeaderView: NSView {
    var content = PaneHeader() {
        didSet {
            guard content != oldValue else { return }
            needsDisplay = true
            let parts = [content.program, content.directory, content.branch].compactMap { $0 }
            setAccessibilityLabel(parts.filter { !$0.isEmpty }.joined(separator: ", "))
            if content.armed != oldValue.armed || content.keys != oldValue.keys { updateToggle() }
        }
    }
    var chrome: Chrome? {
        didSet {
            needsDisplay = true
            updateToggle()
        }
    }
    /// A click on "receiving input" or "left out".
    var onToggleArmed: (() -> Void)?
    private let toggle = NSButton(title: "", target: nil, action: nil)

    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let boldFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let keyFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        toggle.isBordered = false
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.isHidden = true
        addSubview(toggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneHeaderView is created in code")
    }

    override var isFlipped: Bool { true }

    /// Clicks go to the card, which gives its terminal the keys, except on the armed toggle.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !toggle.isHidden, toggle.frame.contains(convert(point, from: superview)) else { return nil }
        return toggle
    }

    private static let margin: CGFloat = 12

    /// "● receiving input" in the warning color, or "○ left out", or nothing.
    private func updateToggle() {
        guard let armed = content.armed, let colors = chrome?.colors else {
            toggle.isHidden = true
            return
        }
        let receiving = armed == .receiving
        toggle.attributedTitle = NSAttributedString(
            string: receiving ? "● receiving input" : "○ left out",
            attributes: [
                .font: receiving ? Self.boldFont : Self.font,
                .foregroundColor: (receiving ? colors.warning : colors.inkMuted).nsColor,
            ])
        toggle.toolTip = receiving ? "Leave this pane out of Armed and Dangerous" : "Put this pane back"
        toggle.setAccessibilityLabel(
            receiving ? "Receiving input. Leave this pane out" : "Left out. Put this pane back")
        toggle.isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !toggle.isHidden else { return }
        toggle.sizeToFit()
        var trailing = bounds.width - Self.margin
        if let keys = content.keys { trailing -= KeyCap.width(keys, font: Self.keyFont) + 10 }
        toggle.frame.origin = NSPoint(
            x: trailing - toggle.frame.width, y: ((bounds.height - toggle.frame.height) / 2).rounded())
    }

    @objc private func toggled() {
        onToggleArmed?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors = chrome?.colors else { return }
        // Inside the card's 1 pt border, following its round top corners.
        let rect = NSRect(x: 1, y: 1, width: max(bounds.width - 2, 0), height: max(bounds.height - 1, 0))
        let radius = min(Chrome.cardRadius - 1, rect.width / 2)
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        shape.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        shape.appendArc(
            from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        shape.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        shape.appendArc(
            from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        shape.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        shape.close()
        colors.surface.nsColor.setFill()
        shape.fill()
        colors.line.nsColor.setFill()
        NSRect(x: rect.minX, y: bounds.height - 1, width: rect.width, height: 1).fill()

        let margin = Self.margin
        var trailing = bounds.width - margin
        if let keys = content.keys {
            let width = KeyCap.width(keys, font: Self.keyFont)
            trailing -= width
            KeyCap.draw(keys, at: NSPoint(x: trailing, y: 0), height: bounds.height, colors: colors, font: Self.keyFont)
            trailing -= 10
        }
        if !toggle.isHidden { trailing = toggle.frame.minX - 10 }
        let text = describe(colors)
        let size = text.size()
        let textRect = NSRect(
            x: margin, y: ((bounds.height - size.height) / 2).rounded(),
            width: max(min(size.width, trailing - margin), 0), height: size.height)
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// "zsh · ~/code · main": the program in bold, the branch in the accent.
    private func describe(_ colors: ChromeColors) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(
            string: content.program,
            attributes: [.font: Self.boldFont, .foregroundColor: colors.ink.nsColor])
        let separator: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: colors.inkFaint.nsColor]
        if let directory = content.directory {
            text.append(NSAttributedString(string: StatusLine.separator, attributes: separator))
            text.append(
                NSAttributedString(
                    string: directory, attributes: [.font: Self.font, .foregroundColor: colors.inkMuted.nsColor]))
        }
        if let branch = content.branch {
            text.append(NSAttributedString(string: StatusLine.separator, attributes: separator))
            text.append(
                NSAttributedString(
                    string: branch, attributes: [.font: Self.boldFont, .foregroundColor: colors.accent.nsColor]))
        }
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }
}
