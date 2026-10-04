import AppCore
import AppKit
import QuartzCore
import TerminalUI
import VTCore

/// What a pill shows.
struct PillState: Equatable {
    var title: String
    var isActive: Bool
    /// The equalizer: output in a background tab.
    var isBusy: Bool
    /// The bell rang in a background tab.
    var rang: Bool
    /// The shell ended badly.
    var failed: Bool
}

/// The tab pills, left to right, then the + pill. Pills shrink when the row is full; those
/// that still don't fit go into a "more" menu.
@MainActor
final class TabStripView: NSView {
    private(set) var pills: [TabID: TabPillView] = [:]
    private var order: [TabID] = []
    private let plus = TabPillView(tab: nil)
    private let more = TabPillView(tab: nil)
    private var chrome: Chrome?
    /// Tabs that did not fit, in the "more" menu.
    private var overflow: [TabID] = []

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onDetach: ((TabID) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onNewTab: (() -> Void)?

    static let gap: CGFloat = 6
    static let minimumWidth: CGFloat = 72
    static let maximumWidth: CGFloat = 240

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.state = PillState(title: "+", isActive: false, isBusy: false, rang: false, failed: false)
        plus.toolTip = "New tab (⌘T)"
        plus.onSelect = { [weak self] in self?.onNewTab?() }
        more.onSelect = { [weak self] in self?.showMoreMenu() }
        addSubview(plus)
        addSubview(more)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabStripView is created in code")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Empty space in the strip still drags the window.
    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    func setChrome(_ chrome: Chrome) {
        self.chrome = chrome
        for pill in Array(pills.values) + [plus, more] { pill.chrome = chrome }
    }

    /// Shows `tabs` in order with their states.
    func update(_ tabs: [(id: TabID, state: PillState)]) {
        let ids = tabs.map { $0.id }
        for (id, pill) in pills where !ids.contains(id) {
            pill.removeFromSuperview()
            pills[id] = nil
        }
        for (id, state) in tabs {
            let pill = pills[id] ?? makePill(id)
            pill.state = state
        }
        order = ids
        needsLayout = true
    }

    private func makePill(_ id: TabID) -> TabPillView {
        let pill = TabPillView(tab: id)
        pill.chrome = chrome
        pill.onSelect = { [weak self] in self?.onSelect?(id) }
        pill.onClose = { [weak self] in self?.onClose?(id) }
        pill.onDetach = { [weak self] in self?.onDetach?(id) }
        pill.onDrag = { [weak self, weak pill] location in
            guard let self, let pill else { return }
            self.drag(pill, id: id, to: self.convert(location, from: nil).x)
        }
        pills[id] = pill
        addSubview(pill)
        return pill
    }

    override func layout() {
        super.layout()
        let height = TabPillView.height
        let y = ((bounds.height - height) / 2).rounded()
        var widths = order.map { min(max(pills[$0]?.naturalWidth ?? 0, Self.minimumWidth), Self.maximumWidth) }
        let reserved = height + Self.gap  // the + pill
        var available = bounds.width - reserved
        // Too wide: everything shrinks toward the minimum, the active pill last.
        func total(_ widths: [CGFloat]) -> CGFloat {
            widths.reduce(0, +) + Self.gap * CGFloat(max(widths.count, 0))
        }
        if total(widths) > available {
            let floor = Self.minimumWidth
            let excess = total(widths) - available
            let shrinkable = widths.reduce(0) { $0 + max($1 - floor, 0) }
            if shrinkable > 0 {
                let ratio = min(excess / shrinkable, 1)
                widths = widths.map { $0 - max($0 - floor, 0) * ratio }
            }
        }
        // Still too wide: the last pills go into the menu, keeping the active one.
        overflow = []
        var visible = order
        if total(widths) > available {
            available -= height + Self.gap  // the "more" pill
            while visible.count > 1, total(widths) > available {
                let activeIndex = visible.firstIndex { pills[$0]?.state.isActive == true }
                let drop = activeIndex == visible.count - 1 ? visible.count - 2 : visible.count - 1
                overflow.insert(visible.remove(at: drop), at: 0)
                widths.remove(at: drop)
            }
        }
        var x: CGFloat = 0
        for (id, width) in zip(visible, widths) {
            guard let pill = pills[id] else { continue }
            pill.isHidden = false
            let frame = NSRect(x: x.rounded(), y: y, width: width.rounded(), height: height)
            if pill.frame != frame { pill.frame = frame }
            x += width + Self.gap
        }
        for id in overflow { pills[id]?.isHidden = true }
        more.isHidden = overflow.isEmpty
        if !overflow.isEmpty {
            more.state = PillState(
                title: "+\(overflow.count)", isActive: false, isBusy: false, rang: false, failed: false)
            more.toolTip = "\(overflow.count) more tabs"
            more.frame = NSRect(x: x.rounded(), y: y, width: max(more.naturalWidth, height), height: height)
            x += more.frame.width + Self.gap
        }
        plus.frame = NSRect(x: x.rounded(), y: y, width: height, height: height)
    }

    private func showMoreMenu() {
        let menu = NSMenu()
        for id in overflow {
            guard let pill = pills[id] else { continue }
            let item = NSMenuItem(title: pill.state.title, action: #selector(selectFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY + 4), in: self)
    }

    @objc private func selectFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int else { return }
        onSelect?(TabID(raw))
    }

    /// Dragging a pill: it takes the place of the pill under the pointer.
    private func drag(_ pill: TabPillView, id: TabID, to x: CGFloat) {
        guard let from = order.firstIndex(of: id) else { return }
        var to = from
        for (index, other) in order.enumerated() where other != id {
            guard let frame = pills[other]?.frame, pills[other]?.isHidden == false else { continue }
            if index < from && x < frame.midX { to = min(to, index) }
            if index > from && x > frame.midX { to = max(to, index) }
        }
        if to != from { onMove?(from, to) }
    }
}

/// One tab: its title, and in the background what happened there. The active pill is
/// filled with the theme's gradient.
@MainActor
final class TabPillView: NSView {
    let tab: TabID?
    var state = PillState(title: "", isActive: false, isBusy: false, rang: false, failed: false) {
        didSet {
            guard state != oldValue else { return }
            needsDisplay = true
            equalizer.isRunning = state.isBusy && !state.isActive
            setAccessibilityLabel(accessibilityText)
            setAccessibilityValue(state.isActive)
        }
    }
    var chrome: Chrome? {
        didSet {
            equalizer.colors = chrome?.colors.neon ?? []
            needsDisplay = true
        }
    }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDetach: (() -> Void)?
    /// The pointer moved while the pill was held, in window coordinates.
    var onDrag: ((NSPoint) -> Void)?

    private let equalizer = EqualizerLayer()
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }
    private var mouseDownPoint: NSPoint?
    private var dragging = false
    private var pressingClose = false

    static let height: CGFloat = 28
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let activeFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    static let padding: CGFloat = 12
    static let closeWidth: CGFloat = 16

    init(tab: TabID?) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(equalizer.layer)
        setAccessibilityElement(true)
        setAccessibilityRole(tab == nil ? .button : .radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabPillView is created in code")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var naturalWidth: CGFloat {
        let font = state.isActive ? Self.activeFont : Self.font
        let text = (state.title as NSString).size(withAttributes: [.font: font]).width
        var width = Self.padding * 2 + text
        if leadingMark { width += 12 + 6 }
        if tab != nil { width += Self.closeWidth }
        return width.rounded(.up)
    }

    /// A dot or the equalizer before the title.
    private var leadingMark: Bool { !state.isActive && (state.isBusy || state.rang || state.failed) }

    private var accessibilityText: String {
        var text = state.title
        if state.failed { text += ", ended" } else if state.rang { text += ", rang the bell" }
        if state.isBusy && !state.isActive { text += ", has new output" }
        return text
    }

    override func layout() {
        super.layout()
        let barArea = CGRect(x: Self.padding, y: (bounds.height - 12) / 2, width: 12, height: 12)
        equalizer.place(in: barArea, of: bounds.size, yDown: layer?.contentsAreFlipped() ?? true)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors = chrome?.colors else { return }
        let radius = bounds.height / 2
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if state.isActive {
            NSGradient(colors: colors.gradient.map(\.nsColor))?.draw(in: shape, angle: 0)
        } else {
            if hovering {
                colors.surfaceHover.nsColor.setFill()
                shape.fill()
            }
            colors.line.nsColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        var x = Self.padding
        if leadingMark {
            if !state.isBusy {
                let dot = state.failed ? colors.danger : colors.neon.first ?? colors.danger
                dot.nsColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 3, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
            }
            x += 12 + 6
        }
        let textColor = state.isActive ? colors.onAccent : (hovering ? colors.ink : colors.inkMuted)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(
            string: state.title,
            attributes: [
                .font: state.isActive ? Self.activeFont : Self.font, .foregroundColor: textColor.nsColor,
                .paragraphStyle: style,
            ])
        let closeSpace = tab != nil ? Self.closeWidth : 0
        let available = bounds.width - x - Self.padding - closeSpace + (tab == nil ? Self.padding : 0)
        let size = title.size()
        let textRect = NSRect(
            x: tab == nil ? ((bounds.width - size.width) / 2).rounded() : x,
            y: ((bounds.height - size.height) / 2).rounded(), width: min(size.width, available),
            height: size.height)
        title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        if tab != nil && hovering {
            let mark = NSAttributedString(
                string: "×",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: textColor.nsColor,
                ])
            let markSize = mark.size()
            mark.draw(
                at: NSPoint(
                    x: (closeRect.midX - markSize.width / 2).rounded(),
                    y: ((bounds.height - markSize.height) / 2).rounded()))
        }
    }

    private var closeRect: NSRect {
        NSRect(
            x: bounds.width - Self.padding - Self.closeWidth + 4, y: 0, width: Self.closeWidth, height: bounds.height)
    }

    // MARK: - The mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        dragging = false
        pressingClose = tab != nil && hovering && closeRect.contains(point)
        if !pressingClose { onSelect?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard tab != nil, let start = mouseDownPoint, !pressingClose else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging && abs(point.x - start.x) > 4 { dragging = true }
        if dragging { onDrag?(event.locationInWindow) }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            dragging = false
            pressingClose = false
        }
        let point = convert(event.locationInWindow, from: nil)
        if pressingClose && closeRect.contains(point) { onClose?() }
    }

    /// The middle button closes a tab, as in browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, tab != nil { onClose?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard tab != nil else { return nil }
        let menu = NSMenu()
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeFromMenu(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        let detach = NSMenuItem(
            title: "Move Tab to New Window", action: #selector(detachFromMenu(_:)), keyEquivalent: "")
        detach.target = self
        menu.addItem(detach)
        return menu
    }

    @objc private func closeFromMenu(_ sender: Any?) { onClose?() }
    @objc private func detachFromMenu(_ sender: Any?) { onDetach?() }

    // MARK: - Accessibility

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

/// Three bars that bounce while a background tab prints, like MenuGlance's. Core Animation
/// runs them in the window server, at a low frame rate, so the app never wakes for them;
/// with Reduce Motion they stand still.
@MainActor
final class EqualizerLayer {
    let layer = CALayer()
    private let bars = (0..<3).map { _ in CAGradientLayer() }
    private static let heights: [CGFloat] = [5, 11, 8]
    private var yDown = true

    var colors: [RGB] = [] {
        didSet { paint() }
    }

    var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            layer.isHidden = !isRunning
            if isRunning { animate() } else { for bar in bars { bar.removeAllAnimations() } }
        }
    }

    init() {
        layer.isHidden = true
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        for bar in bars {
            bar.cornerRadius = 1
            bar.actions = ["position": NSNull(), "bounds": NSNull(), "colors": NSNull()]
            layer.addSublayer(bar)
        }
    }

    /// Puts the bars in `rect` (in the pill's coordinates, y down), standing on its bottom.
    func place(in rect: CGRect, of size: CGSize, yDown: Bool) {
        self.yDown = yDown
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame =
            yDown ? rect : CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        for (index, bar) in bars.enumerated() {
            let height = Self.heights[index]
            // Scaled from its foot: the bottom of the box, wherever this layer puts it.
            bar.anchorPoint = CGPoint(x: 0.5, y: yDown ? 1 : 0)
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: height)
            bar.position = CGPoint(x: 1.5 + CGFloat(index) * 5, y: yDown ? rect.height : 0)
        }
        CATransaction.commit()
        paint()
    }

    private func paint() {
        // Cyan on top down to pink at the foot, as the mockups' bars.
        let stops = Array(colors.reversed())
        for bar in bars {
            bar.colors = stops.map(\.cgColor)
            bar.startPoint = CGPoint(x: 0.5, y: yDown ? 0 : 1)
            bar.endPoint = CGPoint(x: 0.5, y: yDown ? 1 : 0)
        }
    }

    private func animate() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (index, bar) in bars.enumerated() {
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.35
            bounce.toValue = 1.0
            bounce.duration = [0.42, 0.55, 0.48][index]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timeOffset = Double(index) * 0.17
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // The window server needn't draw these faster than this.
            bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
            bar.add(bounce, forKey: "bounce")
        }
    }
}
