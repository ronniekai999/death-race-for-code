import ScreenProtocol

/// Pane slots rather than process-local pane IDs make a layout portable across relaunch.
public indirect enum SavedSplit: Sendable, Equatable {
    case pane(Int)
    case split(stacked: Bool, ratio: Double, SavedSplit, SavedSplit)

    public var slots: [Int] {
        switch self {
        case .pane(let slot): [slot]
        case .split(_, _, let a, let b): a.slots + b.slots
        }
    }

    func isValid(depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        switch self {
        case .pane(let slot): return (0..<128).contains(slot)
        case .split(_, let ratio, let a, let b):
            return ratio.isFinite && ratio > 0 && ratio < 1 && a.isValid(depth: depth + 1)
                && b.isValid(depth: depth + 1)
        }
    }
}

public struct SavedWindowFrame: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite && abs($0) <= 100_000 } && width >= 100 && height >= 100
    }
}

public struct SavedWorkspace: Sendable, Equatable {
    public var tree: SavedSplit
    public var activeSlot: Int
    public var zoomedSlot: Int?
    public var selectedTab: Bool
    public var focusedWindow: Bool
    public var frame: SavedWindowFrame?

    public init(
        tree: SavedSplit, activeSlot: Int, zoomedSlot: Int? = nil, selectedTab: Bool = false,
        focusedWindow: Bool = false, frame: SavedWindowFrame? = nil
    ) {
        self.tree = tree; self.activeSlot = activeSlot; self.zoomedSlot = zoomedSlot
        self.selectedTab = selectedTab; self.focusedWindow = focusedWindow; self.frame = frame
    }

    public var isValid: Bool {
        guard tree.isValid() else { return false }
        let slots = tree.slots
        return slots.count <= 128 && Set(slots).count == slots.count && slots.contains(activeSlot)
            && (zoomedSlot.map { slots.contains($0) } ?? true) && (frame?.isValid ?? true)
    }
}

extension ByteWriter {
    mutating func savedSplit(_ tree: SavedSplit) {
        switch tree {
        case .pane(let slot): u8(0); u32(UInt32(slot))
        case .split(let stacked, let ratio, let a, let b):
            u8(stacked ? 2 : 1); u64(ratio.bitPattern); savedSplit(a); savedSplit(b)
        }
    }
    mutating func savedWorkspace(_ workspace: SavedWorkspace) {
        savedSplit(workspace.tree)
        u32(UInt32(workspace.activeSlot))
        u32(workspace.zoomedSlot.map { UInt32($0) } ?? .max)
        bool(workspace.selectedTab); bool(workspace.focusedWindow)
        bool(workspace.frame != nil)
        if let frame = workspace.frame {
            for value in [frame.x, frame.y, frame.width, frame.height] { u64(value.bitPattern) }
        }
    }
}

extension ByteReader {
    mutating func savedSplit(depth: Int = 0, leaves: inout Int) throws(SessionWire.Fault) -> SavedSplit {
        guard depth < 32, leaves < 128 else { throw .invalid("workspace tree exceeds limits") }
        let tag = try u8()
        switch tag {
        case 0:
            leaves += 1
            let slot = try u32()
            guard slot < 128 else { throw .invalid("workspace slot") }
            return .pane(Int(slot))
        case 1, 2:
            let ratio = Double(bitPattern: try u64())
            guard ratio.isFinite, ratio > 0, ratio < 1 else { throw .invalid("workspace ratio") }
            let a = try savedSplit(depth: depth + 1, leaves: &leaves)
            let b = try savedSplit(depth: depth + 1, leaves: &leaves)
            return .split(stacked: tag == 2, ratio: ratio, a, b)
        default: throw .invalid("workspace split")
        }
    }
    mutating func savedWorkspace() throws(SessionWire.Fault) -> SavedWorkspace {
        var leaves = 0
        let tree = try savedSplit(leaves: &leaves)
        let active = try u32()
        let zoomed = try u32()
        let selected = try bool()
        let focused = try bool()
        let frame: SavedWindowFrame?
        if try bool() {
            frame = try SavedWindowFrame(
                x: Double(bitPattern: u64()), y: Double(bitPattern: u64()),
                width: Double(bitPattern: u64()), height: Double(bitPattern: u64()))
        } else {
            frame = nil
        }
        let workspace = SavedWorkspace(
            tree: tree, activeSlot: Int(active), zoomedSlot: zoomed == .max ? nil : Int(zoomed),
            selectedTab: selected, focusedWindow: focused, frame: frame)
        guard workspace.isValid else { throw .invalid("workspace focus or geometry") }
        return workspace
    }
}
