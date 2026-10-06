import AppKit
import ConfigKit
import Metal
import QuartzCore
import RenderKit
import ScreenProtocol
import SessionKit
import SurfaceCore
import VTCore

/// What to draw beside a command: its words, already rasterized, and whether they are worth a
/// flash.
///
/// A picture rather than a string, because the words and the chrome's fonts and gradients are
/// the app's and `TerminalUI` has no business knowing either. All the view does is find the
/// cell and place it.
public struct CommandBadge: Sendable {
    public var picture: CGImage
    /// The command beat its own best. Flashed once when the badge appears, never after.
    public var isPersonalBest: Bool

    public init(picture: CGImage, isPersonalBest: Bool) {
        self.picture = picture
        self.isPersonalBest = isPersonalBest
    }
}

/// The terminal in a window: it draws a session's screen with Metal and turns keys and input
/// methods into bytes for it.
///
/// Drawing is driven by a display link that runs only while something changes: a session
/// update, a key press or a resize wakes it, and it pauses after a few ticks with nothing to
/// draw, so an idle terminal draws no frames at all. The cursor is a Core Animation layer
/// above the Metal layer.
@MainActor
public final class TerminalSurfaceView: NSView {
    public private(set) var fonts: FontSet
    public private(set) var cell: CellMetrics
    public var theme: Theme {
        didSet {
            needsFrame = true
            metalLayer?.backgroundColor = theme.palette.background.cgColor
            session?.setBasePalette(theme.palette)
            cursorKey = nil
            wake()
        }
    }
    /// Points between the view's edges and the grid.
    public var padding: (x: Double, y: Double) {
        didSet {
            if padding != oldValue { layoutGrid() }
        }
    }
    public var optionAsMeta = OptionAsMeta.left
    public var cursorStyle = CursorShape.block {
        didSet {
            cursorKey = nil
            updateCursor()
        }
    }
    /// The cursor blinks unless a program says otherwise (DECSCUSR).
    public var cursorBlink = true {
        didSet {
            guard cursorBlink != oldValue else { return }
            cursorLayer.removeAnimation(forKey: "blink")
            blinkOrigin = nil
            updateCursor()
        }
    }
    /// Heavier strokes, for light text on dark backgrounds.
    public var fontThicken = false {
        didSet {
            if fontThicken != oldValue { resetGlyphs() }
        }
    }
    /// A pane that is not its tab's active one fades toward the window's ground; nil draws
    /// it as it is.
    public var dimming: Dimming? {
        didSet {
            guard dimming != oldValue else { return }
            cursorKey = nil
            redraw()
        }
    }
    /// Faint stars in each row's empty end, behind no text.
    public var starfield = false {
        didSet { if starfield != oldValue { redraw() } }
    }
    /// Lines a notch of a mouse wheel scrolls.
    public var mouseScrollMultiplier = 3.0
    /// On the alternate screen (less, man), the wheel sends arrow keys even when the program
    /// did not ask for it with mode 1007.
    public var mouseScrollAlternate = true
    /// Ask before a paste that would run commands (see `PasteWarning`).
    public var pasteProtection = true
    /// A finished selection goes to the pasteboard, as in X11 terminals.
    public var copyOnSelect = false

    /// The grid's size in cells changed.
    public var onGridChange: ((GridLayout) -> Void)?
    /// The terminal's default background changed: the theme's, or a program's (OSC 11).
    public var onBackgroundChange: ((RGB) -> Void)?
    /// The program set a new title.
    public var onTitleChange: ((String) -> Void)?
    /// Events for the window to act on: bells, notifications, clipboard writes, directories.
    public var onEvents: (([TerminalEvent]) -> Void)?
    /// The session ended.
    public var onExit: ((Session.Status) -> Void)?
    /// `readsPassword` changed.
    public var onPasswordInputChange: (() -> Void)?
    /// The view became first responder: a click, or focus moved to it. The window marks
    /// its pane active.
    public var onFirstResponder: (() -> Void)?
    /// `isFocused` changed.
    public var onFocusChange: ((Bool) -> Void)?
    /// The screen changed: output arrived, even while out of sight. For tab activity.
    public var onOutput: (() -> Void)?
    /// Return was pressed: a command may have started, or the directory changed.
    public var onReturnKey: (() -> Void)?
    /// The link ⌘ is held over changed: where it goes, or nil.
    public var onHoverLink: ((String?) -> Void)?
    /// A ⌘-click or Open Link chose a link; the app decides what that does.
    public var onOpenLink: ((LinkHit) -> Void)?
    /// Typing here, before it was encoded: keys, composed text and pastes, never the mouse
    /// or the scroll wheel. Armed and Dangerous hands it to the tab's other armed panes.
    public var onTyped: ((TypedInput) -> Void)?
    /// Armed and Dangerous: the modes of the other panes a paste here goes to as well, so
    /// the paste question asks once, for all of them.
    public var pasteAlsoGoesTo: (() -> [TerminalModes])?
    /// The app's items for the context menu, after Copy and Paste (Save Selection to
    /// Wishing Well).
    public var contextMenuItems: (() -> [NSMenuItem])?
    /// The link ⌘ is held over, underlined while the pointer is on it.
    public internal(set) var hoveredLink: LinkHit?
    /// Conversations: what a block's rail and the band behind the one you are in are drawn in.
    /// Nil draws no blocks at all, which is what `conversations = false` comes to — and with
    /// it the terminal draws exactly what it drew before any of this.
    public var blockColors: BlockColors? {
        didSet {
            if blockColors != oldValue {
                needsFrame = true
                wake()
            }
        }
    }
    /// The picture of what to say beside a command, or nil for one not worth a word — which is
    /// most of them. The app draws it, because the words, the records they are compared against
    /// and the chrome's fonts are all the app's; the view only finds the cell and places it.
    public var makeBadge: ((CommandRecord, CGFloat) -> CommandBadge?)? {
        didSet {
            if makeBadge == nil { removeBadges() }
            needsFrame = true
            wake()
        }
    }
    /// How fast the view may draw (`follow-low-power-mode`, `output-frame-rate-cap`).
    public var frameRatePolicy = FrameRatePolicy() {
        didSet { if frameRatePolicy != oldValue { applyFrameRate() } }
    }

    public private(set) var grid: GridLayout
    public private(set) var model: SurfaceModel?
    var session: (any SurfaceSession)? { model?.session }
    private var rasterizer: GlyphRasterizer
    private var glyphs: GlyphCache
    private let builder = FrameBuilder()
    private var renderer: SurfaceRenderer?
    private var pacer = FramePacer()
    private var link: CADisplayLink?
    /// The next tick must draw even if no delta arrived (a resize, a font change, glyphs
    /// that were not ready).
    private var needsFrame = true
    private var reportedExit = false
    private var reportedReadsPassword = false
    private var reportedBackground: RGB?
    /// A drain is scheduled for a view that is out of sight.
    private var hiddenDrainScheduled = false
    let cursorLayer = CALayer()
    /// What the cursor image shows, so it is drawn again only when that changes.
    private var cursorKey: CursorKey?
    /// Where the cursor was when its blink last started; nil while it does not blink.
    private var blinkOrigin: TextPoint?
    /// A key was pressed: the blink starts over, with the cursor shown.
    var restartBlink = false
    /// The visual bell's flash, over everything.
    private let flashLayer = CALayer()
    /// The blocks the last frame drew, so the badges are placed against the same screen the
    /// rail and band were drawn on rather than one recomputed a moment later.
    private var blockRuns: [BlockRun] = []
    /// One layer per badge on screen, recycled rather than remade: a layer that is not needed
    /// this frame is hidden, not removed, because the next frame usually needs it again.
    private var badgeLayers: [CALayer] = []
    /// Badge pictures by the command they are about, so one is drawn once rather than once a
    /// frame. The nil answer is cached too: "nothing worth saying" is the common case and
    /// would otherwise be asked for on every frame of every fast command on screen.
    private var badgePictures: [CommandRecord: CommandBadge?] = [:]
    private var badgePictureScale: CGFloat = 0
    /// Records already flashed, so a personal best is celebrated once rather than on every
    /// frame it is on screen — and not again when it scrolls back into view.
    private var flashedBests: Set<CommandRecord> = []
    /// Enough for a screenful of slow commands, and a bound on the layers either way.
    private static let badgeLimit = 24
    private static let badgePictureLimit = 256
    /// For Debug › Log Frame Stats.
    public private(set) var frameStats = FrameStats()
    /// When the oldest key press not yet on screen happened (CACurrentMediaTime).
    var pendingKeyTime: CFTimeInterval?
    /// Keyboard state kept by the input extension.
    var currentPress: KeyPress?
    var markedText = NSMutableAttributedString()
    var markedSelection = NSRange(location: 0, length: 0)
    /// Mouse state kept by the mouse extension: the cell motion was last reported in, and
    /// the scroll that has not added up to a whole line yet.
    var lastMouseCell: (column: Int, row: Int)?
    var scrollAccumulator = ScrollAccumulator()
    /// The left button went down as a report to the program, so its drags and release go
    /// there too, whatever Shift does meanwhile.
    var leftButtonReported = false
    /// Link state kept by the link extension: the cell the hover was last looked for in, the
    /// link the button went down on with ⌘ held, and the one a context menu is about.
    var hoverCell: (column: Int, row: Int)?
    var pressedLink: LinkHit?
    var menuLink: LinkHit?
    /// When the last key press, scroll or selection drag happened (CACurrentMediaTime).
    var lastInputTime: CFTimeInterval = -.infinity
    /// The display's full rate is on for recent input.
    private var inputBoosted = false
    private var appliedFrameRate: FrameRatePolicy.Range?
    /// Selection state kept by the selection extension.
    var selection: Selection?
    var selectionGeneration: UInt64?
    var autoscrollTimer: Timer?
    var autoscrollDirection = 0

    private struct CursorKey: Equatable {
        var character: [UInt32]
        var cells: Int
        var bold: Bool
        var italic: Bool
        var cursor: RGB
        var text: RGB
    }

    public init(fonts: FontSet, theme: Theme, padding: (x: Double, y: Double), scale: CGFloat) {
        self.fonts = fonts
        let cell = fonts.cellMetrics(scale: scale)
        self.cell = cell
        self.theme = theme
        self.padding = padding
        self.grid = GridLayout(columns: 1, rows: 1, left: padding.x, top: padding.y)
        rasterizer = GlyphRasterizer(fonts: fonts, cell: cell)
        glyphs = GlyphCache(rasterizer: rasterizer)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layerContentsPlacement = .topLeft
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        cursorLayer.isHidden = true
        // Motion with no button held is reported in any-event mode (1003), which needs
        // mouse-moved events. With `inVisibleRect` the area follows the view's visible rect.
        // Entering and leaving end a link's hover.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
        registerForDraggedTypes(Self.droppedTypes)
        // Low Power Mode and the thermal state change how fast output may draw.
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(energyConditionsChanged(_:)), name: .NSProcessInfoPowerStateDidChange,
            object: nil)
        center.addObserver(
            self, selector: #selector(energyConditionsChanged(_:)), name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalSurfaceView is created in code")
    }

    override public func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = RenderContext.shared?.device
        layer.pixelFormat = .bgra8Unorm
        // Theme colors and programs' colors are sRGB; so are the bytes the shaders write.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        // The cursor layer moves in the same Core Animation transaction as the frame.
        layer.presentsWithTransaction = true
        layer.backgroundColor = theme.palette.background.cgColor
        return layer
    }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    // MARK: - The session

    /// Starts showing `session`. Its updates must reach `sessionDidUpdate()` on the main
    /// thread.
    public func attach(_ session: any SurfaceSession) {
        model = SurfaceModel(session: session)
        reportedExit = false
        session.setFocused(isFocused)
        session.resize(columns: grid.columns, rows: grid.rows, cellPixelWidth: cell.width, cellPixelHeight: cell.height)
        needsFrame = true
        wake()
    }

    /// The session has something new.
    public func sessionDidUpdate() {
        guard model != nil else { return }
        if isSeen {
            wake()
        } else {
            scheduleHiddenDrain()
        }
    }

    /// Out of sight: keep up with titles, bells and the shell's exit without drawing, at
    /// most four times a second. The session merges what comes in between.
    private func scheduleHiddenDrain() {
        guard model != nil, !hiddenDrainScheduled else { return }
        hiddenDrainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            MainActor.assumeIsolated { self?.drainWhileHidden() }
        }
    }

    private func drainWhileHidden() {
        hiddenDrainScheduled = false
        // Shown again in the meantime: the next frame takes the update.
        if isSeen { wake() } else { drain() }
    }

    /// Stops drawing and lets go of the display link; closing the session is the caller's.
    public func shutDown() {
        link?.invalidate()
        link = nil
        pacer = FramePacer()
    }

    /// Pauses the display link from outside its own ticks (hidden, covered); the next
    /// `wake()` starts it again.
    private func pauseDrawing() {
        link?.isPaused = true
        pacer = FramePacer()
        // A delta the paused link was about to take would otherwise wait until the view is
        // seen again: the session tells only once until it is taken.
        scheduleHiddenDrain()
    }

    /// Applies what the session sent since the last call and acts on it; true when there is
    /// something new to draw.
    @discardableResult
    private func drain() -> Bool {
        guard let model else { return false }
        let applying = Signposts.signposter.beginInterval("DeltaApply")
        let update = model.drain()
        Signposts.signposter.endInterval("DeltaApply", applying)
        // A new screen (a resize, the alternate screen): the selection's lines are gone.
        if selection != nil, model.mirror.generation != selectionGeneration { clearSelection() }
        if update.titleChanged { onTitleChange?(model.mirror.title) }
        if !update.rows.isEmpty || update.replaced { onOutput?() }
        if !update.events.isEmpty { onEvents?(update.events) }
        if model.mirror.readingPassword != reportedReadsPassword {
            reportedReadsPassword = model.mirror.readingPassword
            onPasswordInputChange?()
        }
        if model.mirror.generation != nil, model.mirror.palette.background != reportedBackground {
            reportedBackground = model.mirror.palette.background
            onBackgroundChange?(model.mirror.palette.background)
        }
        if !reportedExit, case .exited = model.session.status {
            reportedExit = true
            onExit?(model.session.status)
        }
        return !update.isEmpty
    }

    /// The program is reading a password: a line with echo off, as sudo and ssh read them.
    public var readsPassword: Bool { reportedReadsPassword }

    /// Clear to Start (⌘K) or Clear Scrollback (⌥⌘K); the alternate screen is left alone.
    public func clear(_ kind: Terminal.ClearKind) {
        clearSelection()
        session?.clear(kind)
    }

    // MARK: - Drawing

    /// Something the session does not know about changed (composing text, the selection):
    /// draw again.
    func redraw() {
        needsFrame = true
        wake()
    }

    /// Something changed: make sure the display link is running.
    func wake() {
        guard isSeen, pacer.wake() else { return }
        frameStats.linkResumed()
        Signposts.signposter.emitEvent("LinkResumed")
        if link == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            appliedFrameRate = nil
        }
        link?.isPaused = false
        applyFrameRate()
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Typing stopped a second ago: back to the rate for output.
        if inputBoosted && CACurrentMediaTime() - lastInputTime >= FrameRatePolicy.inputWindow { applyFrameRate() }
        let changed = drain()
        let drew = (changed || needsFrame) && drawFrame()
        if !pacer.tick(drew: drew) {
            link.isPaused = true
            Signposts.signposter.emitEvent("LinkPaused")
        }
    }

    /// Whether drawing would be seen: in a window, on screen, not hidden. (Not `canDraw`:
    /// NSView has a deprecated property of that name.)
    private var isSeen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Builds and presents a frame. True when a frame was drawn or has to be tried again.
    private func drawFrame() -> Bool {
        guard let model, let metalLayer, let context = RenderContext.shared else { return false }
        let pixelWidth = Int(metalLayer.drawableSize.width)
        let pixelHeight = Int(metalLayer.drawableSize.height)
        guard pixelWidth > 0, pixelHeight > 0, model.mirror.generation != nil else { return false }
        if renderer == nil { renderer = SurfaceRenderer(device: context.device, pipelines: context.pipelines) }
        guard let renderer else { return false }
        let started = CACurrentMediaTime()
        let signpost = Signposts.signposter.beginInterval("Frame")
        defer { Signposts.signposter.endInterval("Frame", signpost) }

        glyphs.beginFrame()
        // The screen may have moved under a hovered link.
        if hoveredLink != nil { updateHoveredLink(redrawing: false) }
        blockRuns = blockColors == nil && makeBadge == nil ? [] : Blocks.runs(in: model.mirror)
        let frame = builder.build(
            mirror: model.mirror, theme: theme, cell: cell, selection: selectionRange, glyphs: glyphs,
            preedit: preedit, starfield: starfield, link: hoveredLink,
            blocks: blockColors.map { BlockChrome(runs: blockRuns, colors: $0) })
        guard let drawable = metalLayer.nextDrawable(), let commandBuffer = context.queue.makeCommandBuffer() else {
            needsFrame = true
            return true
        }
        let layout = PixelLayout(
            width: pixelWidth, height: pixelHeight, originX: Int((grid.left * cell.scale).rounded()),
            originY: Int((grid.top * cell.scale).rounded()))
        guard
            renderer.encode(
                frame, cell: cell, layout: layout, glyphs: glyphs, target: drawable.texture,
                commandBuffer: commandBuffer, dim: dimming?.packed ?? 0)
        else {
            needsFrame = true
            return true
        }
        // With presentsWithTransaction the frame appears with this transaction, together
        // with the cursor's move.
        if let keyTime = pendingKeyTime {
            pendingKeyTime = nil
            // On Metal's thread, so not isolated to the main actor: it only hops back.
            drawable.addPresentedHandler { @Sendable [weak self] drawable in
                let presented = drawable.presentedTime
                guard presented > 0, let view = self else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { view.keyReachedScreen((presented - keyTime) * 1000) }
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
        updateCursor()
        updateBadges()
        CATransaction.commit()
        needsFrame = !frame.isComplete
        frameStats.frameDrawn(milliseconds: (CACurrentMediaTime() - started) * 1000)
        return true
    }

    private func keyReachedScreen(_ milliseconds: Double) {
        frameStats.keyReachedScreen(milliseconds: milliseconds)
        Signposts.signposter.emitEvent("KeyToScreen", "\(milliseconds) ms")
    }

    // MARK: - The cursor

    /// Places the cursor layer over its cell: a block with the character under it in the
    /// cursor's text color, a bar or an underline; hollow while the view is not focused.
    func updateCursor() {
        if cursorLayer.superlayer == nil, let layer { layer.addSublayer(cursorLayer) }
        guard let mirror = model?.mirror, mirror.generation != nil else { return hideCursor() }
        if let preedit {
            // While an input method composes, a bar marks its caret in the composing text.
            guard preedit.row >= 0, preedit.row < mirror.lines.count else { return hideCursor() }
            setBlinking(from: nil)
            let rect = CellGeometry(cell: cell, layout: grid).rect(column: preedit.caretColumn, row: preedit.row)
            cursorLayer.isHidden = false
            cursorLayer.contents = nil
            cursorLayer.borderWidth = 0
            cursorLayer.backgroundColor = mirror.palette.cursor.cgColor
            cursorKey = nil
            cursorLayer.frame = convertToLayer(
                NSRect(x: rect.x, y: rect.y, width: barWidth, height: rect.height))
            return
        }
        let cursor = mirror.cursor
        let row = cursor.y + mirror.viewportOffset
        guard cursor.visible, row >= 0, row < mirror.lines.count, cursor.x >= 0, cursor.x < mirror.columns else {
            return hideCursor()
        }
        let line = mirror.lines[row]
        guard cursor.x < line.cells.count else { return hideCursor() }
        var column = cursor.x
        if column > 0, line.cells[column].width == .spacerTail { column -= 1 }
        let cells = line.cells[column].width == .wide ? 2 : 1
        // A program's shape wins; for a block, the user's preferred style applies.
        let style = cursor.shape == .block ? cursorStyle : cursor.shape
        let rect = CellGeometry(cell: cell, layout: grid).rect(column: column, row: row, cells: cells)
        var frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        // The cursor is a layer of its own, so it fades here as the frame does in the shaders.
        let color = faded(mirror.palette.cursor)

        cursorLayer.isHidden = false
        if !isFocused {
            cursorLayer.contents = nil
            cursorLayer.backgroundColor = nil
            cursorLayer.borderColor = color.cgColor
            cursorLayer.borderWidth = 1
            cursorKey = nil
            setBlinking(from: nil)
        } else {
            let blinks = cursor.blinks ?? cursorBlink
            setBlinking(from: blinks ? TextPoint(line: mirror.viewportTopLine + UInt64(row), column: column) : nil)
            cursorLayer.borderWidth = 0
            cursorLayer.backgroundColor = color.cgColor
            switch style {
            case .block:
                let style = line.style(of: line.cells[column])
                let key = CursorKey(
                    character: line.scalars(at: column), cells: cells, bold: style.attributes.contains(.bold),
                    italic: style.attributes.contains(.italic), cursor: color,
                    text: faded(theme.cursorText ?? mirror.palette.background))
                if key != cursorKey {
                    let glyph =
                        key.character.isEmpty
                        ? nil
                        : rasterizer.rasterize(
                            GlyphKey(scalars: key.character, bold: key.bold, italic: key.italic, wide: cells == 2))
                    cursorLayer.contents = CursorImage.make(
                        glyph: glyph, cell: cell, cells: cells, cursor: key.cursor, text: key.text)
                    cursorLayer.contentsScale = CGFloat(cell.scale)
                    cursorKey = key
                }
            case .bar:
                cursorLayer.contents = nil
                cursorKey = nil
                frame.size.width = barWidth
            case .underline:
                cursorLayer.contents = nil
                cursorKey = nil
                let thickness = max(1, (Double(cell.height) / 12).rounded()) / cell.scale
                frame.origin.y += frame.size.height - thickness
                frame.size.height = thickness
            }
        }
        cursorLayer.frame = convertToLayer(frame)
    }

    private func faded(_ color: RGB) -> RGB {
        dimming?.apply(to: color) ?? color
    }

    private func hideCursor() {
        cursorLayer.isHidden = true
        setBlinking(from: nil)
    }

    /// Blinks the cursor, starting from `origin`, or stops it (nil). Core Animation runs the
    /// blink in the window server, 25 times (30 seconds) from the last key press or cursor
    /// move, and then leaves the cursor shown, so an idle terminal never wakes the app.
    private func setBlinking(from origin: TextPoint?) {
        guard let origin else {
            if blinkOrigin != nil {
                cursorLayer.removeAnimation(forKey: "blink")
                blinkOrigin = nil
            }
            return
        }
        guard origin != blinkOrigin || restartBlink else { return }
        blinkOrigin = origin
        restartBlink = false
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1.0, 0.0]
        // Discrete keyframes take one more key time than values.
        blink.keyTimes = [0, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1.2
        blink.repeatCount = 25
        // Replaces the running blink, so it starts over shown.
        cursorLayer.add(blink, forKey: "blink")
    }

    /// The visual bell: the terminal flashes once.
    public func flash() {
        Signposts.signposter.emitEvent("Bell")
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if flashLayer.superlayer == nil {
            flashLayer.opacity = 0
            layer.addSublayer(flashLayer)
        }
        flashLayer.frame = layer.bounds
        flashLayer.backgroundColor = theme.palette.foreground.cgColor
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.25
        fade.toValue = 0.0
        fade.duration = 0.25
        flashLayer.add(fade, forKey: "flash")
    }

    /// A bar cursor's width in points: an eighth of a cell, at least a pixel.
    private var barWidth: Double {
        max(1, (Double(cell.width) / 8).rounded()) / cell.scale
    }

    /// The text an input method is composing, placed at the cursor; nil when there is none.
    var preedit: PreeditLayout? {
        guard hasMarkedText(), let mirror = model?.mirror else { return nil }
        let text = markedText.string
        // The input method's caret comes in UTF-16 units; the layout counts characters.
        var caret = 0
        var offset = 0
        for character in text {
            guard offset < markedSelection.location else { break }
            offset += character.utf16.count
            caret += 1
        }
        return PreeditLayout(
            text: text, cursorColumn: mirror.cursor.x, cursorRow: mirror.cursor.y + mirror.viewportOffset,
            columns: mirror.columns, caret: caret)
    }

    // MARK: - Focus

    /// Keys go here: this view is the key window's first responder and the app is active.
    public private(set) var isFocused = false

    override public func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // The window records its new first responder only after this returns.
        if became {
            focusChanged(firstResponder: true)
            onFirstResponder?()
        }
        return became
    }

    override public func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged(firstResponder: false) }
        return resigned
    }

    /// The window or the app gained or lost focus: the session's priority, focus reports
    /// (mode 1004) and the cursor follow.
    public func focusChanged() {
        focusChanged(firstResponder: window?.firstResponder === self)
    }

    private func focusChanged(firstResponder: Bool) {
        if window?.isKeyWindow != true || !NSApp.isActive { updateHoveredLink(commandHeld: false) }
        let focused = firstResponder && window?.isKeyWindow == true && NSApp.isActive
        guard focused != isFocused else { return }
        isFocused = focused
        onFocusChange?(focused)
        session?.setFocused(focused)
        if let mirror = model?.mirror {
            let report = InputEncoder.focus(focused, modes: mirror.modes)
            if !report.isEmpty { session?.sendReport(report) }
        }
        if !focused { discardComposition() }
        updateCursor()
    }

    // MARK: - Snapshots

    /// What the view shows, drawn offscreen at its size, as its next frame would be: for
    /// previews and tests, which cannot ask the window server for a Metal layer's picture.
    /// Nil before the session's first screen arrives.
    public func snapshot(using renderer: OffscreenRenderer) throws -> RenderedImage? {
        guard let model, model.mirror.generation != nil else { return nil }
        let scale = cell.scale
        let width = Int((Double(bounds.width) * scale).rounded())
        let height = Int((Double(bounds.height) * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let glyphs = GlyphCache(rasterizer: GlyphRasterizer(fonts: fonts, cell: cell, thicken: fontThicken))
        // As many frames as the glyph cache's per-frame budget needs to draw every glyph.
        let (frame, _) = FrameBuilder().buildComplete(
            mirror: model.mirror, theme: theme, cell: cell, selection: selectionRange, glyphs: glyphs,
            starfield: starfield, link: hoveredLink,
            blocks: blockColors.map { BlockChrome(runs: Blocks.runs(in: model.mirror), colors: $0) })
        let layout = PixelLayout(
            width: width, height: height, originX: Int((grid.left * scale).rounded()),
            originY: Int((grid.top * scale).rounded()))
        return try renderer.render(frame, cell: cell, layout: layout, glyphs: glyphs, dim: dimming?.packed ?? 0)
    }

    /// Places a badge beside each command worth a word, at the right-hand end of the line its
    /// prompt is on, as the board draws it.
    ///
    /// Called from inside the transaction that presents the frame, where the cursor is placed:
    /// `presentsWithTransaction` is what makes a layer and the Metal frame appear together, and
    /// a badge placed outside it shears against scrolling text. Placed on every frame drawn
    /// rather than when the view scrolls, for the same reason the cursor is: scrolling always
    /// draws, so there is no second signal to listen for.
    func updateBadges() {
        guard self.layer != nil, let makeBadge, let model, !blockRuns.isEmpty else { return hideBadges() }
        let scale = window?.backingScaleFactor ?? cell.scale
        if scale != badgePictureScale {
            badgePictures.removeAll(keepingCapacity: true)
            badgePictureScale = scale
        }
        if badgePictures.count > Self.badgePictureLimit { badgePictures.removeAll(keepingCapacity: true) }
        let geometry = CellGeometry(cell: cell, layout: grid)
        let top = model.mirror.viewportTopLine
        let right = grid.left + Double(grid.columns) * cell.pointWidth
        var placed = 0
        for run in blockRuns {
            guard placed < Self.badgeLimit else { break }
            guard let command = run.command, !command.isEmpty else { continue }
            // The prompt's own line. A block whose prompt is above the screen has nowhere to
            // put a badge, and putting it on the top row would label the wrong command.
            guard run.lines.lowerBound >= top else { continue }
            let row = Int(run.lines.lowerBound - top)
            guard row >= 0, row < model.mirror.lines.count else { continue }
            if badgePictures.index(forKey: command) == nil {
                badgePictures[command] = makeBadge(command, scale)
            }
            guard let found = badgePictures[command] ?? nil else { continue }
            let width = Double(found.picture.width) / Double(scale)
            let height = Double(found.picture.height) / Double(scale)
            let cellRect = geometry.rect(column: 0, row: row)
            let badge = badgeLayer(at: placed)
            placed += 1
            badge.contentsScale = scale
            badge.contents = found.picture
            badge.isHidden = false
            badge.frame = convertToLayer(
                NSRect(
                    x: max(right - width, grid.left), y: cellRect.y + (cell.pointHeight - height) / 2,
                    width: width, height: height))
            if found.isPersonalBest, flashedBests.insert(command).inserted {
                flash(badge)
            }
        }
        for index in placed..<badgeLayers.count { badgeLayers[index].isHidden = true }
    }

    /// A new personal best, once: `docs/DESIGN.md` says nothing animates at idle, so this is a
    /// one-shot added when the badge first appears, the shape the visual bell already uses —
    /// not a running animation on a badge that simply sits there.
    private func flash(_ badge: CALayer) {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.0
        pulse.toValue = 1.0
        pulse.duration = 0.35
        badge.add(pulse, forKey: "best")
    }

    private func badgeLayer(at index: Int) -> CALayer {
        if index < badgeLayers.count { return badgeLayers[index] }
        let badge = CALayer()
        // No implicit animations: a badge moves with the frame or not at all.
        badge.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        badge.contentsGravity = .resizeAspect
        layer?.addSublayer(badge)
        badgeLayers.append(badge)
        return badge
    }

    private func hideBadges() {
        for badge in badgeLayers { badge.isHidden = true }
    }

    /// Every badge gone, for a pane whose blocks were turned off.
    private func removeBadges() {
        for badge in badgeLayers { badge.removeFromSuperlayer() }
        badgeLayers.removeAll()
        badgePictures.removeAll()
        flashedBests.removeAll()
        blockRuns = []
    }

    /// Draws the badges into `context`, whose coordinates are the window's, the way
    /// `drawCursor(in:)` draws the cursor: `OffscreenRenderer` only ever draws the `Frame`, and
    /// a badge is a layer, so a picture of a pane has to be told about it.
    public func drawBadges(in context: CGContext) {
        updateBadges()
        for badge in badgeLayers where !badge.isHidden {
            guard let contents = badge.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
                continue
            }
            let rect = convert(convertFromLayer(badge.frame), to: nil)
            context.saveGState()
            context.draw(contents as! CGImage, in: rect)
            context.restoreGState()
        }
    }

    /// Draws the cursor, a layer of its own over the frame, into `context`, whose coordinates
    /// are the window's: a picture of the pane is `snapshot(using:)`, then this. Like the
    /// snapshot, it follows the screen as it is now, so the layer is placed first: frames
    /// place it, and a view out of sight draws none.
    public func drawCursor(in context: CGContext) {
        updateCursor()
        guard cursorLayer.superlayer != nil, !cursorLayer.isHidden else { return }
        let rect = convert(convertFromLayer(cursorLayer.frame), to: nil)
        context.saveGState()
        defer { context.restoreGState() }
        if let contents = cursorLayer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            // A block, with the character under it.
            context.draw(contents as! CGImage, in: rect)
        } else if let color = cursorLayer.backgroundColor {
            context.setFillColor(color)
            context.fill(rect)
        }
        if cursorLayer.borderWidth > 0, let color = cursorLayer.borderColor {
            // Hollow, while the view is not focused.
            let width = cursorLayer.borderWidth
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
        }
    }

    // MARK: - Frame rate

    /// A key press, a scroll or a selection drag: the display's full rate for a second.
    func noteInput() {
        lastInputTime = CACurrentMediaTime()
        if !inputBoosted { applyFrameRate() }
    }

    /// Sets the display link's frame rate range from `frameRatePolicy`, only when the answer
    /// changed.
    func applyFrameRate() {
        let recent = CACurrentMediaTime() - lastInputTime < FrameRatePolicy.inputWindow
        inputBoosted = recent
        guard let link else { return }
        var policy = frameRatePolicy
        if let fastest = window?.screen?.maximumFramesPerSecond, fastest > 0 { policy.displayMaximum = Double(fastest) }
        let info = ProcessInfo.processInfo
        let range = policy.range(
            for: FrameRatePolicy.Conditions(
                recentInput: recent, lowPowerMode: info.isLowPowerModeEnabled,
                thermal: FrameRatePolicy.Thermal(rawValue: info.thermalState.rawValue) ?? .nominal))
        guard range != appliedFrameRate else { return }
        appliedFrameRate = range
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(range.minimum), maximum: Float(range.maximum), preferred: Float(range.preferred))
    }

    /// Posted on whatever thread noticed the change: the view hears of it on the main one.
    @objc nonisolated private func energyConditionsChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyFrameRate() }
        }
    }

    // MARK: - Size

    /// The view size, in points, for a grid of `columns` × `rows`.
    public func size(columns: Int, rows: Int) -> NSSize {
        let size = GridLayout.viewSize(
            columns: columns, rows: rows, cell: cell, paddingX: padding.x, paddingY: padding.y)
        return NSSize(width: size.width, height: size.height)
    }

    /// One cell in points, for the window's resize increments.
    public var cellSize: NSSize {
        NSSize(width: cell.pointWidth, height: cell.pointHeight)
    }

    /// New faces (a font size change): the grid is laid out again at the same view size.
    public func setFonts(_ fonts: FontSet) {
        self.fonts = fonts
        resetCell(scale: window?.backingScaleFactor ?? CGFloat(cell.scale))
    }

    private func resetCell(scale: CGFloat) {
        cell = fonts.cellMetrics(scale: scale)
        resetGlyphs()
        layoutGrid(force: true)
    }

    /// Glyphs are drawn again, from scratch, with the current faces, cell and thickening.
    private func resetGlyphs() {
        rasterizer = GlyphRasterizer(fonts: fonts, cell: cell, thicken: fontThicken)
        glyphs = GlyphCache(rasterizer: rasterizer)
        cursorKey = nil
        redraw()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor else { return }
        metalLayer?.contentsScale = scale
        if Double(scale) != cell.scale {
            resetCell(scale: scale)
        } else {
            layoutGrid(force: true)
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            shutDown()
        } else {
            redraw()
        }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutGrid()
    }

    /// Sizes the drawable to the view and the grid to whole cells, and tells the session
    /// when the grid changed. When neither changed it does nothing, so a layout pass of the
    /// window around it (a title or a status change) draws no frame.
    private func layoutGrid(force: Bool = false) {
        let scale = window?.backingScaleFactor ?? CGFloat(cell.scale)
        let drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let layout = GridLayout(
            width: Double(bounds.width), height: Double(bounds.height), cell: cell, paddingX: padding.x,
            paddingY: padding.y)
        guard force || layout != grid || metalLayer?.drawableSize != drawableSize else { return }
        metalLayer?.drawableSize = drawableSize
        needsFrame = true
        if force || layout != grid {
            grid = layout
            session?.resize(
                columns: layout.columns, rows: layout.rows, cellPixelWidth: cell.width, cellPixelHeight: cell.height)
            onGridChange?(layout)
        }
        if inLiveResize, isSeen {
            // Draw now rather than on the next tick, so the window never shows a stretched frame.
            drain()
            _ = drawFrame()
        } else {
            wake()
        }
    }

    // MARK: - Visibility

    override public func viewDidHide() {
        super.viewDidHide()
        pauseDrawing()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        redraw()
    }

    /// The window was shown, hidden or covered: draw again once it is seen.
    public func visibilityChanged() {
        if isSeen {
            redraw()
        } else {
            pauseDrawing()
        }
    }
}

extension RGB {
    /// The color as sRGB, which is what themes and programs mean by their hex values.
    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}
