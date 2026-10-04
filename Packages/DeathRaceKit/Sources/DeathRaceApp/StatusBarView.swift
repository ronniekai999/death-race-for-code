import AppCore
import AppKit
import TerminalUI
import VTCore

/// The bar under the panes: the active pane's directory, branch and Secure input on the
/// left; its size and program on the right. It is drawn, not laid out, and only when its
/// text changes.
@MainActor
final class StatusBarView: NSView {
    var line = StatusLine(StatusLine.Facts(columns: 0, rows: 0)) {
        didSet {
            guard line != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel((line.leading + line.trailing).map(\.text).joined(separator: ", "))
        }
    }
    private var chrome: Chrome
    /// A click on "N settings could not be used".
    var onProblemsClick: (() -> Void)?
    private var problemsRect: NSRect?

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    init(chrome: Chrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusBarView is created in code")
    }

    override var isFlipped: Bool { true }

    func setChrome(_ chrome: Chrome) {
        self.chrome = chrome
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = chrome.colors
        colors.groundDeep.nsColor.setFill()
        bounds.fill()
        colors.line.nsColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let margin: CGFloat = 16
        let trailing = attributed(line.trailing, colors: colors)
        let trailingSize = trailing.size()
        let trailingOrigin = NSPoint(
            x: (bounds.width - margin - trailingSize.width).rounded(),
            y: ((bounds.height - trailingSize.height) / 2).rounded())
        trailing.draw(at: trailingOrigin)

        let leading = attributed(line.leading, colors: colors)
        let available = trailingOrigin.x - margin - 24
        let size = leading.size()
        let rect = NSRect(
            x: margin, y: ((bounds.height - size.height) / 2).rounded(), width: max(min(size.width, available), 0),
            height: size.height)
        leading.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        problemsRect = line.leading.last?.style == .warning ? rect : nil
    }

    private func attributed(_ runs: [StatusLine.Run], colors: ChromeColors) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString()
        for (index, run) in runs.enumerated() {
            if index > 0 {
                text.append(
                    NSAttributedString(
                        string: StatusLine.separator,
                        attributes: [.font: Self.font, .foregroundColor: colors.inkFaint.nsColor]))
            }
            let color: RGB
            let font: NSFont
            switch run.style {
            case .muted: (color, font) = (colors.inkMuted, Self.font)
            case .ink: (color, font) = (colors.ink, Self.boldFont)
            case .accent: (color, font) = (colors.accent, Self.boldFont)
            case .warning: (color, font) = (colors.warning, Self.boldFont)
            }
            if let symbol = run.symbol,
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [color.nsColor])))
            {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            text.append(
                NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: color.nsColor]))
        }
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let problemsRect, problemsRect.contains(point) { onProblemsClick?() }
    }
}
