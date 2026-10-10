import SessionIPC

extension SplitTree {
    public func saved(slots: [PaneID: Int]) -> SavedSplit? {
        switch self {
        case .pane(let id): return slots[id].map { .pane($0) }
        case .split(let axis, let ratio, let a, let b):
            guard let first = a.saved(slots: slots), let second = b.saved(slots: slots) else { return nil }
            return .split(stacked: axis == .stacked, ratio: ratio, first, second)
        }
    }

    /// A session that ended while the app was closed leaves a hole. Its sibling takes that
    /// space, preserving the rest of the tree and its proportions.
    public static func restored(_ saved: SavedSplit, panes: [Int: PaneID]) -> SplitTree? {
        switch saved {
        case .pane(let slot): return panes[slot].map { .pane($0) }
        case .split(let stacked, let ratio, let a, let b):
            let first = restored(a, panes: panes)
            let second = restored(b, panes: panes)
            switch (first, second) {
            case (let a?, let b?): return .split(stacked ? .stacked : .sideBySide, ratio: ratio, a, b)
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (nil, nil): return nil
            }
        }
    }
}
