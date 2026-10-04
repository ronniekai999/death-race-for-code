/// Packs glyph bitmaps into a square texture in shelves: rows of slots, each shelf as tall as
/// the first glyph placed on it. Terminal glyphs come in a few heights (a cell, a wide cell,
/// a box-drawing sprite), so shelves fill well and finding room is a short scan.
///
/// When there is no room it grows, doubling up to `maxSize`; past that it reuses the shelf
/// least recently drawn from, if no frame has drawn from it lately. Reuse invalidates every
/// placement on that shelf, which the glyph cache tracks.
public struct ShelfAtlas: Sendable {
    public struct Slot: Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var shelf: Int
    }

    struct Shelf: Sendable {
        var y: Int
        var height: Int
        /// The next free x.
        var used: Int
        var lastUsedFrame: UInt64
    }

    public enum Outcome: Sendable, Equatable {
        case placed(Slot)
        /// Placed after the atlas grew to `size`: the texture must grow too, keeping what it
        /// holds in place.
        case grew(Slot, size: Int)
        /// Placed on a reused shelf: every glyph that was on `evicted` is gone.
        case reused(Slot, evicted: Int)
        /// No room: the glyph is too big, or every shelf was drawn from too recently.
        case full
    }

    public private(set) var size: Int
    public let maxSize: Int
    private(set) var shelves: [Shelf] = []
    /// One pixel between glyphs, so sampling at an edge never picks up a neighbour.
    let padding = 1
    /// Frames a shelf must go unused before it can be reused.
    static let reuseAfterFrames: UInt64 = 3

    public init(size: Int, maxSize: Int) {
        self.size = size
        self.maxSize = max(size, maxSize)
    }

    /// Room for a `width` × `height` bitmap, drawn from in `frame`.
    public mutating func allocate(width: Int, height: Int, frame: UInt64) -> Outcome {
        let w = width + padding
        let h = height + padding
        guard w <= maxSize, h <= maxSize else { return .full }
        if let slot = place(w, h, frame: frame) { return .placed(slot) }
        // Grow while that helps: double, up to the largest size the GPU is given.
        while size < maxSize {
            size = min(size * 2, maxSize)
            if let slot = place(w, h, frame: frame) { return .grew(slot, size: size) }
        }
        // Reuse the least recently drawn shelf that is tall enough and has gone unused for a
        // few frames.
        let candidates = shelves.indices.filter {
            shelves[$0].height >= h && frame &- shelves[$0].lastUsedFrame >= Self.reuseAfterFrames
        }
        guard let oldest = candidates.min(by: { shelves[$0].lastUsedFrame < shelves[$1].lastUsedFrame }) else {
            return .full
        }
        shelves[oldest].used = w
        shelves[oldest].lastUsedFrame = frame
        return .reused(Slot(x: 0, y: shelves[oldest].y, shelf: oldest), evicted: oldest)
    }

    /// A frame drew from `shelf`.
    public mutating func markUsed(shelf: Int, frame: UInt64) {
        guard shelves.indices.contains(shelf) else { return }
        shelves[shelf].lastUsedFrame = max(shelves[shelf].lastUsedFrame, frame)
    }

    /// Everything forgotten (the texture was recreated): empty shelves at the initial size.
    public mutating func reset(size: Int) {
        self.size = size
        shelves.removeAll()
    }

    private mutating func place(_ w: Int, _ h: Int, frame: UInt64) -> Slot? {
        // The best existing shelf: room left, tall enough, and not much taller than needed.
        var best: Int?
        for index in shelves.indices {
            let shelf = shelves[index]
            guard shelf.height >= h, shelf.height * 3 <= h * 4 + 4, shelf.used + w <= size else { continue }
            if best == nil || shelf.height < shelves[best!].height { best = index }
        }
        if let index = best {
            let slot = Slot(x: shelves[index].used, y: shelves[index].y, shelf: index)
            shelves[index].used += w
            shelves[index].lastUsedFrame = max(shelves[index].lastUsedFrame, frame)
            return slot
        }
        // A new shelf below the last one.
        let top = shelves.last.map { $0.y + $0.height } ?? 0
        guard top + h <= size, w <= size else { return nil }
        shelves.append(Shelf(y: top, height: h, used: w, lastUsedFrame: frame))
        return Slot(x: 0, y: top, shelf: shelves.count - 1)
    }
}
