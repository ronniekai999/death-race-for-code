import AppCore
import AppKit
import QuartzCore
import TerminalUI
import VTCore

/// One pane on the ground: a rounded card with the terminal view inside it. The card draws
/// the rounded fill, in the terminal's background color, and the border; the terminal view
/// sits `Chrome.cardInset` inside, clear of the corners, so nothing is masked and nothing
/// is composited offscreen while it draws.
@MainActor
final class PaneCardView: NSView {
    let pane: PaneID
    let surface: TerminalSurfaceView
    private let neon = NeonBorderView()
    private var banner: EndBannerView?
    private var chrome: Chrome
    /// The terminal's background now (a program can change it with OSC 11).
    private var fill: RGB

    /// The tab's active pane: the NeonBorder marks it.
    var isActive = false {
        didSet { if isActive != oldValue { applyState() } }
    }
    /// The window is key: only then does the active pane glow.
    var isWindowKey = false {
        didSet { if isWindowKey != oldValue { applyState() } }
    }

    init(pane: PaneID, surface: TerminalSurfaceView, chrome: Chrome) {
        self.pane = pane
        self.surface = surface
        self.chrome = chrome
        fill = chrome.terminalBackground
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = Chrome.cardRadius
        layer?.cornerCurve = .continuous
        layer?.shadowOffset = .zero
        layer?.shadowRadius = Chrome.glowRadius
        addSubview(surface)
        addSubview(neon)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneCardView is created in code")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: Chrome.cardInset, dy: Chrome.cardInset)
        if surface.frame != inner { surface.frame = inner }
        if neon.frame != bounds { neon.frame = bounds }
        if let banner {
            let height: CGFloat = 40
            banner.frame = NSRect(x: inner.minX, y: inner.maxY - height, width: inner.width, height: height)
        }
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Chrome.cardRadius, cornerHeight: Chrome.cardRadius, transform: nil)
    }

    /// A click on the card's rim focuses its terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(surface)
    }

    func setChrome(_ chrome: Chrome) {
        self.chrome = chrome
        fill = chrome.terminalBackground
        banner?.chrome = chrome
        applyColors()
    }

    /// Why the shell ended, along the card's bottom, with a button to start another; nil
    /// takes it away.
    func showEnd(_ message: String?, restart: (() -> Void)?) {
        banner?.removeFromSuperview()
        banner = nil
        guard let message else { return }
        let banner = EndBannerView(message: message, chrome: chrome, restart: restart)
        addSubview(banner, positioned: .below, relativeTo: neon)
        self.banner = banner
        needsLayout = true
    }

    /// A program set the terminal's background (OSC 11): the card's rim follows it.
    func setFill(_ color: RGB) {
        guard color != fill else { return }
        fill = color
        layer?.backgroundColor = color.cgColor
    }

    private func applyColors() {
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = chrome.colors.line.cgColor
        layer?.shadowColor = chrome.colors.glow.cgColor
        neon.colors = chrome.colors.neon
        applyState()
    }

    private func applyState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        neon.isHidden = !isActive
        layer?.borderWidth = isActive ? 0 : 1
        layer?.shadowOpacity = isActive && isWindowKey ? Float(chrome.colors.glowOpacity) : 0
        CATransaction.commit()
    }
}

/// The focused pane's border: the theme's neon gradient running across the whole card at
/// 120°, as in the mockups. It is four gradient strips along the straight edges, each
/// sampling the one gradient, and four solid quarter circles at the corners. No mask
/// layers, so it costs nothing per frame and draws in snapshots.
@MainActor
final class NeonBorderView: NSView {
    var colors: [RGB] = [] {
        didSet { if colors != oldValue { rebuild() } }
    }
    private let strips = (0..<4).map { _ in CAGradientLayer() }
    private let corners = (0..<4).map { _ in CAShapeLayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for strip in strips {
            strip.actions = NeonBorderView.noAnimations
            layer?.addSublayer(strip)
        }
        for corner in corners {
            corner.actions = NeonBorderView.noAnimations
            corner.fillColor = nil
            corner.lineWidth = Chrome.neonWidth
            layer?.addSublayer(corner)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NeonBorderView is created in code")
    }

    static let noAnimations: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "colors": NSNull(), "path": NSNull(), "strokeColor": NSNull(),
        "hidden": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(),
    ]

    override var isFlipped: Bool { true }

    /// Clicks go to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        rebuild()
    }

    private func rebuild() {
        guard let layer else { return }
        let width = bounds.width
        let height = bounds.height
        let radius = Chrome.cardRadius
        let line = Chrome.neonWidth
        guard width > radius * 2, height > radius * 2, colors.count > 1 else {
            for sublayer in (strips as [CALayer]) + (corners as [CALayer]) { sublayer.isHidden = true }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Whether this layer's y runs down the screen, as the view's does, decides where
        // "top" is in its coordinates: AppKit does not promise either way.
        let yDown = layer.contentsAreFlipped()
        func placeRect(_ rect: CGRect) -> CGRect {
            yDown ? rect : CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        func placePoint(_ point: CGPoint) -> CGPoint {
            yDown ? point : CGPoint(x: point.x, y: height - point.y)
        }
        // CSS's 120°: toward the right and 30° down. The gradient line is as long as it
        // must be for the corners to reach its ends.
        let dx: CGFloat = 0.866_025_4
        let dy: CGFloat = 0.5
        let length = width * dx + height * dy
        let ramp = GradientRamp(stops: colors)
        func color(at point: CGPoint) -> RGB {
            let along: CGFloat = ((point.x - width / 2) * dx + (point.y - height / 2) * dy) / length
            return ramp.color(at: Double(along) + 0.5)
        }

        // The straight edges, in view coordinates (y down): top, bottom, left, right.
        let edges: [(rect: CGRect, from: CGPoint, to: CGPoint, horizontal: Bool)] = [
            (
                CGRect(x: radius, y: 0, width: width - radius * 2, height: line), CGPoint(x: radius, y: 0),
                CGPoint(x: width - radius, y: 0), true
            ),
            (
                CGRect(x: radius, y: height - line, width: width - radius * 2, height: line),
                CGPoint(x: radius, y: height), CGPoint(x: width - radius, y: height), true
            ),
            (
                CGRect(x: 0, y: radius, width: line, height: height - radius * 2), CGPoint(x: 0, y: radius),
                CGPoint(x: 0, y: height - radius), false
            ),
            (
                CGRect(x: width - line, y: radius, width: line, height: height - radius * 2),
                CGPoint(x: width, y: radius), CGPoint(x: width, y: height - radius), false
            ),
        ]
        let samples = 8
        for (strip, edge) in zip(strips, edges) {
            strip.isHidden = false
            strip.frame = placeRect(edge.rect)
            var stops: [CGColor] = []
            for step in 0...samples {
                let t = CGFloat(step) / CGFloat(samples)
                let point = CGPoint(
                    x: edge.from.x + (edge.to.x - edge.from.x) * t, y: edge.from.y + (edge.to.y - edge.from.y) * t)
                stops.append(color(at: point).cgColor)
            }
            strip.colors = stops
            if edge.horizontal {
                strip.startPoint = CGPoint(x: 0, y: 0.5)
                strip.endPoint = CGPoint(x: 1, y: 0.5)
            } else {
                // From the top of the edge to its bottom, wherever the layer puts them.
                strip.startPoint = CGPoint(x: 0.5, y: yDown ? 0 : 1)
                strip.endPoint = CGPoint(x: 0.5, y: yDown ? 1 : 0)
            }
        }

        // The corners: quarter circles from one edge to the next, stroked down the middle of
        // the line. Top left, top right, bottom right, bottom left.
        let half = line / 2
        let arcs: [(start: CGPoint, corner: CGPoint, end: CGPoint)] = [
            (CGPoint(x: half, y: radius), CGPoint(x: half, y: half), CGPoint(x: radius, y: half)),
            (
                CGPoint(x: width - radius, y: half), CGPoint(x: width - half, y: half),
                CGPoint(x: width - half, y: radius)
            ),
            (
                CGPoint(x: width - half, y: height - radius), CGPoint(x: width - half, y: height - half),
                CGPoint(x: width - radius, y: height - half)
            ),
            (
                CGPoint(x: radius, y: height - half), CGPoint(x: half, y: height - half),
                CGPoint(x: half, y: height - radius)
            ),
        ]
        for (shape, arc) in zip(corners, arcs) {
            let path = CGMutablePath()
            path.move(to: placePoint(arc.start))
            path.addArc(tangent1End: placePoint(arc.corner), tangent2End: placePoint(arc.end), radius: radius - half)
            path.addLine(to: placePoint(arc.end))
            shape.isHidden = false
            shape.frame = layer.bounds
            shape.path = path
            shape.strokeColor = color(at: arc.corner).cgColor
        }
    }
}

/// A tab's panes on the ground: laid out from its split tree, or the zoomed one alone.
@MainActor
final class PaneAreaView: NSView {
    private(set) var cards: [PaneID: PaneCardView] = [:]
    var tree: SplitTree {
        didSet { if tree != oldValue { needsLayout = true } }
    }
    var zoomedPane: PaneID? {
        didSet { if zoomedPane != oldValue { needsLayout = true } }
    }

    init(tree: SplitTree) {
        self.tree = tree
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneAreaView is created in code")
    }

    override var isFlipped: Bool { true }

    func setChrome(_ chrome: Chrome) {
        layer?.backgroundColor = chrome.colors.ground.cgColor
        for card in cards.values { card.setChrome(chrome) }
    }

    func add(_ card: PaneCardView) {
        cards[card.pane] = card
        addSubview(card)
        needsLayout = true
    }

    func remove(_ pane: PaneID) {
        cards.removeValue(forKey: pane)?.removeFromSuperview()
        needsLayout = true
    }

    /// Where the panes go: inside the margin, in points.
    var paneRect: LayoutRect {
        LayoutRect(
            x: Double(Chrome.paneMargin), y: Double(Chrome.paneMargin),
            width: max(Double(bounds.width - Chrome.paneMargin * 2), 0),
            height: max(Double(bounds.height - Chrome.paneMargin * 2), 0))
    }

    override func layout() {
        super.layout()
        let rect = paneRect
        let scale = Double(window?.backingScaleFactor ?? 2)
        let frames = zoomedPane.map { [$0: rect] } ?? tree.frames(in: rect, gap: Double(Chrome.paneGap), scale: scale)
        for (pane, card) in cards {
            guard let frame = frames[pane] else {
                card.isHidden = true
                continue
            }
            card.isHidden = false
            let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            if card.frame != rect { card.frame = rect }
        }
    }
}

/// "The shell exited with status 3." and a Restart button, over the bottom of a pane whose
/// shell ended badly.
@MainActor
final class EndBannerView: NSView {
    private let message: String
    var chrome: Chrome {
        didSet { needsDisplay = true }
    }
    private let button: NSButton
    private let restart: (() -> Void)?

    init(message: String, chrome: Chrome, restart: (() -> Void)?) {
        self.message = message
        self.chrome = chrome
        self.restart = restart
        button = NSButton(title: "Restart", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        button.bezelStyle = .push
        button.controlSize = .small
        button.target = self
        button.action = #selector(restartClicked(_:))
        addSubview(button)
        setAccessibilityElement(true)
        setAccessibilityLabel(message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EndBannerView is created in code")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        button.sizeToFit()
        button.frame.origin = NSPoint(
            x: bounds.width - button.frame.width - 12, y: ((bounds.height - button.frame.height) / 2).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = chrome.colors
        colors.surface.nsColor.setFill()
        bounds.fill()
        colors.line.nsColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let text = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: colors.inkMuted.nsColor,
            ])
        let size = text.size()
        text.draw(at: NSPoint(x: 12, y: ((bounds.height - size.height) / 2).rounded()))
    }

    @objc private func restartClicked(_ sender: Any?) {
        restart?()
    }
}
