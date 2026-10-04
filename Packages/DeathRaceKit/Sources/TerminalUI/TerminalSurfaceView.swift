import AppKit
import ConfigKit
import Metal
import QuartzCore
import RenderKit
import ScreenProtocol
import SessionKit
import SurfaceCore
import VTCore

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
    /// Heavier strokes, for light text on dark backgrounds.
    public var fontThicken = false {
        didSet {
            if fontThicken != oldValue { resetGlyphs() }
        }
    }
    /// Lines a notch of a mouse wheel scrolls.
    public var mouseScrollMultiplier = 3.0
    /// On the alternate screen (less, man), the wheel sends arrow keys even when the program
    /// did not ask for it with mode 1007.
    public var mouseScrollAlternate = true

    /// The grid's size in cells changed.
    public var onGridChange: ((GridLayout) -> Void)?
    /// The program set a new title.
    public var onTitleChange: ((String) -> Void)?
    /// Events for the window to act on: bells, notifications, clipboard writes, directories.
    public var onEvents: (([TerminalEvent]) -> Void)?
    /// The session ended.
    public var onExit: ((Session.Status) -> Void)?

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
    /// A drain is scheduled for a view that is out of sight.
    private var hiddenDrainScheduled = false
    let cursorLayer = CALayer()
    /// What the cursor image shows, so it is drawn again only when that changes.
    private var cursorKey: CursorKey?
    /// Keyboard state kept by the input extension.
    var currentPress: KeyPress?
    var markedText = NSMutableAttributedString()
    var markedSelection = NSRange(location: 0, length: 0)
    /// Mouse state kept by the mouse extension: the cell motion was last reported in, and
    /// the scroll that has not added up to a whole line yet.
    var lastMouseCell: (column: Int, row: Int)?
    var scrollAccumulator = ScrollAccumulator()

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
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
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
        if canDraw {
            wake()
        } else if !hiddenDrainScheduled {
            // Out of sight: keep up with titles, bells and the shell's exit without drawing,
            // at most four times a second. The session merges what comes in between.
            hiddenDrainScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                MainActor.assumeIsolated { self?.drainWhileHidden() }
            }
        }
    }

    private func drainWhileHidden() {
        hiddenDrainScheduled = false
        // Shown again in the meantime: the next frame takes the update.
        if canDraw { wake() } else { drain() }
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
    }

    /// Applies what the session sent since the last call and acts on it; true when there is
    /// something new to draw.
    @discardableResult
    private func drain() -> Bool {
        guard let model else { return false }
        let update = model.drain()
        if update.titleChanged { onTitleChange?(model.mirror.title) }
        if !update.events.isEmpty { onEvents?(update.events) }
        if !reportedExit, case .exited = model.session.status {
            reportedExit = true
            onExit?(model.session.status)
        }
        return !update.isEmpty
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
        guard canDraw, pacer.wake() else { return }
        if link == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let changed = drain()
        let drew = (changed || needsFrame) && drawFrame()
        if !pacer.tick(drew: drew) { link.isPaused = true }
    }

    /// Whether drawing would be seen: in a window, on screen, not hidden.
    private var canDraw: Bool {
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

        glyphs.beginFrame()
        let frame = builder.build(
            mirror: model.mirror, theme: theme, cell: cell, selection: nil, glyphs: glyphs, preedit: preedit)
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
                commandBuffer: commandBuffer)
        else {
            needsFrame = true
            return true
        }
        // With presentsWithTransaction the frame appears with this transaction, together
        // with the cursor's move.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
        updateCursor()
        CATransaction.commit()
        needsFrame = !frame.isComplete
        return true
    }

    // MARK: - The cursor

    /// Places the cursor layer over its cell: a block with the character under it in the
    /// cursor's text color, a bar or an underline; hollow while the view is not focused.
    func updateCursor() {
        if cursorLayer.superlayer == nil, let layer { layer.addSublayer(cursorLayer) }
        guard let mirror = model?.mirror, mirror.generation != nil else {
            cursorLayer.isHidden = true
            return
        }
        if let preedit {
            // While an input method composes, a bar marks its caret in the composing text.
            guard preedit.row >= 0, preedit.row < mirror.lines.count else {
                cursorLayer.isHidden = true
                return
            }
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
            cursorLayer.isHidden = true
            return
        }
        let line = mirror.lines[row]
        guard cursor.x < line.cells.count else {
            cursorLayer.isHidden = true
            return
        }
        var column = cursor.x
        if column > 0, line.cells[column].width == .spacerTail { column -= 1 }
        let cells = line.cells[column].width == .wide ? 2 : 1
        // A program's shape wins; for a block, the user's preferred style applies.
        let style = cursor.shape == .block ? cursorStyle : cursor.shape
        let rect = CellGeometry(cell: cell, layout: grid).rect(column: column, row: row, cells: cells)
        var frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let color = mirror.palette.cursor

        cursorLayer.isHidden = false
        if !isFocused {
            cursorLayer.contents = nil
            cursorLayer.backgroundColor = nil
            cursorLayer.borderColor = color.cgColor
            cursorLayer.borderWidth = 1
            cursorKey = nil
        } else {
            cursorLayer.borderWidth = 0
            cursorLayer.backgroundColor = color.cgColor
            switch style {
            case .block:
                let style = line.style(of: line.cells[column])
                let key = CursorKey(
                    character: line.scalars(at: column), cells: cells, bold: style.attributes.contains(.bold),
                    italic: style.attributes.contains(.italic), cursor: color,
                    text: theme.cursorText ?? mirror.palette.background)
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
    private(set) var isFocused = false

    override public func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // The window records its new first responder only after this returns.
        if became { focusChanged(firstResponder: true) }
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
        let focused = firstResponder && window?.isKeyWindow == true && NSApp.isActive
        guard focused != isFocused else { return }
        isFocused = focused
        session?.setFocused(focused)
        if let mirror = model?.mirror {
            let report = InputEncoder.focus(focused, modes: mirror.modes)
            if !report.isEmpty { session?.send(report) }
        }
        if !focused { discardComposition() }
        updateCursor()
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
    /// when the grid changed.
    private func layoutGrid(force: Bool = false) {
        let scale = window?.backingScaleFactor ?? CGFloat(cell.scale)
        metalLayer?.drawableSize = CGSize(
            width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let layout = GridLayout(
            width: Double(bounds.width), height: Double(bounds.height), cell: cell, paddingX: padding.x,
            paddingY: padding.y)
        needsFrame = true
        if force || layout != grid {
            grid = layout
            session?.resize(
                columns: layout.columns, rows: layout.rows, cellPixelWidth: cell.width, cellPixelHeight: cell.height)
            onGridChange?(layout)
        }
        if inLiveResize, canDraw {
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
        if canDraw {
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
