import AppKit
import ConfigKit
import RenderKit
import SurfaceCore
import VTCore

/// The terminal in a window: it draws a session's screen and turns keys, the mouse and input
/// methods into bytes for it.
///
/// For now it lays out an empty grid in the theme's background; the renderer and input
/// arrive in the next steps.
@MainActor
public final class TerminalSurfaceView: NSView {
    public private(set) var fonts: FontSet
    public private(set) var cell: CellMetrics
    public var theme: Theme {
        didSet { needsDisplay = true }
    }
    /// Points between the view's edges and the grid.
    public var padding: (x: Double, y: Double) {
        didSet { gridDidChangeIfNeeded() }
    }
    /// Called when the grid's size in cells changes.
    public var onGridChange: ((GridLayout) -> Void)?
    public private(set) var grid: GridLayout

    public init(fonts: FontSet, theme: Theme, padding: (x: Double, y: Double), scale: CGFloat) {
        self.fonts = fonts
        self.cell = fonts.cellMetrics(scale: scale)
        self.theme = theme
        self.padding = padding
        self.grid = GridLayout(columns: 1, rows: 1, left: padding.x, top: padding.y)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalSurfaceView is created in code")
    }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }
    override public var isOpaque: Bool { true }
    override public var wantsUpdateLayer: Bool { true }

    override public func updateLayer() {
        layer?.backgroundColor = theme.palette.background.cgColor
    }

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
        cell = fonts.cellMetrics(scale: window?.backingScaleFactor ?? 2)
        gridDidChangeIfNeeded(force: true)
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, scale != CGFloat(cell.scale) else { return }
        cell = fonts.cellMetrics(scale: scale)
        gridDidChangeIfNeeded(force: true)
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        gridDidChangeIfNeeded()
    }

    private func gridDidChangeIfNeeded(force: Bool = false) {
        let layout = GridLayout(
            width: Double(bounds.width), height: Double(bounds.height), cell: cell, paddingX: padding.x,
            paddingY: padding.y)
        guard force || layout != grid else { return }
        grid = layout
        onGridChange?(layout)
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
