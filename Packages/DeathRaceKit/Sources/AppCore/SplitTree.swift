/// One pane: a terminal in a tab. Numbers are unique for the app's life, so a pane keeps
/// its identity when its tab moves to another window.
public struct PaneID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (a: PaneID, b: PaneID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "pane \(rawValue)" }
}

/// How a split lays out its two sides.
public enum SplitAxis: Sendable, Hashable {
    /// Side by side, with a vertical divider (⌘D, "split right").
    case sideBySide
    /// One above the other, with a horizontal divider (⌘⇧D, "split down").
    case stacked
}

public enum Direction: Sendable, Hashable, CaseIterable {
    case left, right, up, down

    var axis: SplitAxis { self == .left || self == .right ? .sideBySide : .stacked }
    /// Right and down move toward a split's second side.
    var isForward: Bool { self == .right || self == .down }
}

/// A rectangle in points, origin at the top left (the pane area is a flipped view).
public struct LayoutRect: Equatable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var description: String { "(\(x), \(y), \(width)×\(height))" }
}

/// The panes of a tab: a binary tree whose leaves are panes and whose inner nodes split
/// their space in two. Pure values, so every operation is tested on Linux; the window lays
/// views out from `frames(in:gap:scale:)`.
public indirect enum SplitTree: Equatable, Sendable {
    case pane(PaneID)
    /// `ratio` is the first side's share of the space the divider leaves, 0 to 1.
    case split(SplitAxis, ratio: Double, SplitTree, SplitTree)

    /// Which side of a split a path takes.
    public enum Branch: Sendable, Hashable { case first, second }

    /// The panes in reading order: left to right, top to bottom.
    public var panes: [PaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }

    public func contains(_ id: PaneID) -> Bool {
        switch self {
        case .pane(let pane): pane == id
        case .split(_, _, let first, let second): first.contains(id) || second.contains(id)
        }
    }

    // MARK: - Splitting and closing

    /// `target` shares its place with `newPane`, which goes after it: to its right or below.
    public func splitting(_ target: PaneID, _ axis: SplitAxis, newPane: PaneID) -> SplitTree {
        switch self {
        case .pane(let id):
            id == target ? .split(axis, ratio: 0.5, .pane(id), .pane(newPane)) : self
        case .split(let a, let ratio, let first, let second):
            .split(
                a, ratio: ratio, first.splitting(target, axis, newPane: newPane),
                second.splitting(target, axis, newPane: newPane))
        }
    }

    /// The tree without `target`: its sibling takes the whole of their split. Nil when
    /// `target` was the only pane.
    public func removing(_ target: PaneID) -> SplitTree? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard let keptFirst = first.removing(target) else { return second }
            guard let keptSecond = second.removing(target) else { return first }
            return .split(axis, ratio: ratio, keptFirst, keptSecond)
        }
    }

    // MARK: - Layout

    /// Each pane's frame in `rect`, with `gap` points between neighbors. Divider positions
    /// are rounded to whole device pixels (`scale` per point): a Metal layer at a
    /// fractional origin is drawn blurred.
    public func frames(in rect: LayoutRect, gap: Double, scale: Double = 2) -> [PaneID: LayoutRect] {
        var frames: [PaneID: LayoutRect] = [:]
        layout(in: rect, gap: gap, scale: scale) { id, frame in frames[id] = frame }
        return frames
    }

    private func layout(
        in rect: LayoutRect, gap: Double, scale: Double, _ visit: (PaneID, LayoutRect) -> Void
    ) {
        switch self {
        case .pane(let id):
            visit(id, rect)
        case .split(let axis, let ratio, let first, let second):
            let (a, b) = Self.halves(of: rect, axis: axis, ratio: ratio, gap: gap, scale: scale)
            first.layout(in: a, gap: gap, scale: scale, visit)
            second.layout(in: b, gap: gap, scale: scale, visit)
        }
    }

    /// A split's two sides in `rect`.
    static func halves(
        of rect: LayoutRect, axis: SplitAxis, ratio: Double, gap: Double, scale: Double
    ) -> (LayoutRect, LayoutRect) {
        let scale = max(scale, 1)
        switch axis {
        case .sideBySide:
            let space = max(rect.width - gap, 0)
            let firstWidth = min(max(((space * ratio) * scale).rounded() / scale, 0), space)
            return (
                LayoutRect(x: rect.x, y: rect.y, width: firstWidth, height: rect.height),
                LayoutRect(x: rect.x + firstWidth + gap, y: rect.y, width: space - firstWidth, height: rect.height)
            )
        case .stacked:
            let space = max(rect.height - gap, 0)
            let firstHeight = min(max(((space * ratio) * scale).rounded() / scale, 0), space)
            return (
                LayoutRect(x: rect.x, y: rect.y, width: rect.width, height: firstHeight),
                LayoutRect(x: rect.x, y: rect.y + firstHeight + gap, width: rect.width, height: space - firstHeight)
            )
        }
    }

    /// A divider: the gap between a split's sides, where dragging resizes them.
    public struct Divider: Equatable, Sendable {
        /// The way from the root to the split.
        public var path: [Branch]
        public var axis: SplitAxis
        /// The gap itself, for hit testing and the resize cursor.
        public var rect: LayoutRect
        /// The whole split, which a drag divides anew.
        public var span: LayoutRect
    }

    public func dividers(in rect: LayoutRect, gap: Double, scale: Double = 2) -> [Divider] {
        var result: [Divider] = []
        collectDividers(in: rect, gap: gap, scale: scale, path: [], into: &result)
        return result
    }

    private func collectDividers(
        in rect: LayoutRect, gap: Double, scale: Double, path: [Branch], into result: inout [Divider]
    ) {
        guard case .split(let axis, let ratio, let first, let second) = self else { return }
        let (a, b) = Self.halves(of: rect, axis: axis, ratio: ratio, gap: gap, scale: scale)
        let gapRect =
            axis == .sideBySide
            ? LayoutRect(x: a.maxX, y: rect.y, width: b.minX - a.maxX, height: rect.height)
            : LayoutRect(x: rect.x, y: a.maxY, width: rect.width, height: b.minY - a.maxY)
        result.append(Divider(path: path, axis: axis, rect: gapRect, span: rect))
        first.collectDividers(in: a, gap: gap, scale: scale, path: path + [.first], into: &result)
        second.collectDividers(in: b, gap: gap, scale: scale, path: path + [.second], into: &result)
    }

    /// The least room this tree can live in, given each pane's minimum.
    public func minimumSize(pane minimum: (width: Double, height: Double), gap: Double) -> (
        width: Double, height: Double
    ) {
        switch self {
        case .pane:
            return minimum
        case .split(let axis, _, let first, let second):
            let a = first.minimumSize(pane: minimum, gap: gap)
            let b = second.minimumSize(pane: minimum, gap: gap)
            return axis == .sideBySide
                ? (a.width + gap + b.width, max(a.height, b.height))
                : (max(a.width, b.width), a.height + gap + b.height)
        }
    }

    // MARK: - Resizing

    /// The split at `path` with its divider at `position` points from the split's leading
    /// edge, held where both sides keep their minimum size.
    public func movingDivider(
        at path: [Branch], to position: Double, in rect: LayoutRect, gap: Double,
        minimum: (width: Double, height: Double)
    ) -> SplitTree {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        guard let step = path.first else {
            let space = axis == .sideBySide ? rect.width - gap : rect.height - gap
            guard space > 0 else { return self }
            let a = first.minimumSize(pane: minimum, gap: gap)
            let b = second.minimumSize(pane: minimum, gap: gap)
            let low = axis == .sideBySide ? a.width : a.height
            let high = space - (axis == .sideBySide ? b.width : b.height)
            // When even the minimums don't fit, both sides shrink alike.
            let clamped = low <= high ? min(max(position, low), high) : space * low / (low + space - high)
            return .split(axis, ratio: clamped / space, first, second)
        }
        let (a, b) = Self.halves(of: rect, axis: axis, ratio: ratio, gap: gap, scale: 1)
        switch step {
        case .first:
            return .split(
                axis, ratio: ratio,
                first.movingDivider(at: Array(path.dropFirst()), to: position, in: a, gap: gap, minimum: minimum),
                second)
        case .second:
            return .split(
                axis, ratio: ratio, first,
                second.movingDivider(at: Array(path.dropFirst()), to: position, in: b, gap: gap, minimum: minimum))
        }
    }

    /// ⌘⌃ arrows: the divider nearest `pane` along that direction's axis moves `points`
    /// that way.
    public func resizing(
        _ pane: PaneID, toward direction: Direction, by points: Double, in rect: LayoutRect, gap: Double,
        minimum: (width: Double, height: Double)
    ) -> SplitTree {
        guard let path = nearestSplit(around: pane, axis: direction.axis),
            let divider = dividers(in: rect, gap: gap, scale: 1).first(where: { $0.path == path })
        else { return self }
        let current =
            divider.axis == .sideBySide ? divider.rect.minX - divider.span.minX : divider.rect.minY - divider.span.minY
        let moved = current + (direction.isForward ? points : -points)
        return movingDivider(at: path, to: moved, in: rect, gap: gap, minimum: minimum)
    }

    /// The path to the innermost split along `axis` that holds `pane`.
    func nearestSplit(around pane: PaneID, axis wanted: SplitAxis) -> [Branch]? {
        guard case .split(let axis, _, let first, let second) = self, contains(pane) else { return nil }
        let (branch, side) = first.contains(pane) ? (Branch.first, first) : (Branch.second, second)
        if let inner = side.nearestSplit(around: pane, axis: wanted) { return [branch] + inner }
        return axis == wanted ? [] : nil
    }

    /// Every split shares its space by the panes on each side along its axis, so three panes
    /// side by side get a third each however they were split. The gaps count, so this is
    /// worked out for the space the tree has now.
    public func equalized(in rect: LayoutRect, gap: Double) -> SplitTree {
        switch self {
        case .pane:
            return self
        case .split(let axis, _, let first, let second):
            let a = Double(first.count(along: axis))
            let b = Double(second.count(along: axis))
            let size = axis == .sideBySide ? rect.width : rect.height
            guard size - gap > 0 else { return self }
            let paneSize = (size - gap * (a + b - 1)) / (a + b)
            let ratio = min(max((a * paneSize + gap * (a - 1)) / (size - gap), 0), 1)
            let (x, y) = Self.halves(of: rect, axis: axis, ratio: ratio, gap: gap, scale: 1)
            return .split(axis, ratio: ratio, first.equalized(in: x, gap: gap), second.equalized(in: y, gap: gap))
        }
    }

    /// How many panes lie side by side (or stacked) across this tree.
    func count(along axis: SplitAxis) -> Int {
        switch self {
        case .pane:
            return 1
        case .split(let a, _, let first, let second):
            let (x, y) = (first.count(along: axis), second.count(along: axis))
            return a == axis ? x + y : max(x, y)
        }
    }

    // MARK: - Moving focus

    /// The pane next to `pane` that way: of the panes beyond its edge that overlap it
    /// across the direction, the nearest, then the one overlapping most, then the one
    /// focused most recently (`recent`, newest first), then the first in reading order.
    public func neighbor(
        of pane: PaneID, toward direction: Direction, in rect: LayoutRect, gap: Double, recent: [PaneID] = []
    ) -> PaneID? {
        let frames = frames(in: rect, gap: gap, scale: 1)
        guard let from = frames[pane] else { return nil }
        var best: (id: PaneID, distance: Double, overlap: Double, recency: Int)?
        for id in panes where id != pane {
            guard let to = frames[id] else { continue }
            let distance: Double
            let overlap: Double
            switch direction {
            case .left:
                (distance, overlap) = (from.minX - to.maxX, Self.overlap(from.minY, from.maxY, to.minY, to.maxY))
            case .right:
                (distance, overlap) = (to.minX - from.maxX, Self.overlap(from.minY, from.maxY, to.minY, to.maxY))
            case .up: (distance, overlap) = (from.minY - to.maxY, Self.overlap(from.minX, from.maxX, to.minX, to.maxX))
            case .down:
                (distance, overlap) = (to.minY - from.maxY, Self.overlap(from.minX, from.maxX, to.minX, to.maxX))
            }
            guard distance >= -0.5, overlap > 0 else { continue }
            let recency = recent.firstIndex(of: id) ?? Int.max
            let better: Bool
            if let best {
                if abs(distance - best.distance) > 0.5 {
                    better = distance < best.distance
                } else if abs(overlap - best.overlap) > 0.5 {
                    better = overlap > best.overlap
                } else {
                    better = recency < best.recency
                }
            } else {
                better = true
            }
            if better { best = (id, distance, overlap, recency) }
        }
        return best?.id
    }

    private static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }
}
