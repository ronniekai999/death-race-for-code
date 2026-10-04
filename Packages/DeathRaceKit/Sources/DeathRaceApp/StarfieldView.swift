import AppCore
import AppKit
import QuartzCore

/// The stars on the ground behind the cards (`StarField`): each a tiny layer with a color and
/// no bitmap, so they cost no memory and are drawn by the window server only when the window
/// changes. They come in fixed tiles: a window that grows shows more sky, and the stars it
/// had stay where they were.
@MainActor
final class StarfieldView: NSView {
    private let sky = CALayer()
    private var tiles: [StarField.Tile: [CALayer]] = [:]
    private static let noAnimations: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "sublayers": NSNull(),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        sky.actions = Self.noAnimations
        sky.masksToBounds = true
        layer?.addSublayer(sky)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StarfieldView is created in code")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The stars in view, for tests.
    var starCount: Int { tiles.values.reduce(0) { $0 + $1.count } }

    override func layout() {
        super.layout()
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        sky.frame = layer.bounds
        // The stars count from the top, as StarField does, whichever way AppKit set up y.
        sky.isGeometryFlipped = !layer.contentsAreFlipped()
        let wanted = Set(StarField.tiles(width: Double(bounds.width), height: Double(bounds.height)))
        for (tile, specks) in tiles where !wanted.contains(tile) {
            for speck in specks { speck.removeFromSuperlayer() }
            tiles[tile] = nil
        }
        for tile in wanted where tiles[tile] == nil {
            tiles[tile] = tile.stars.map { star in
                let speck = CALayer()
                speck.actions = Self.noAnimations
                speck.frame = CGRect(x: star.x, y: star.y, width: star.diameter, height: star.diameter)
                speck.cornerRadius = star.diameter / 2
                speck.backgroundColor = CGColor(gray: 1, alpha: star.opacity)
                sky.addSublayer(speck)
                return speck
            }
        }
    }
}
