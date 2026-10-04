import Testing

@testable import AppCore

@Suite struct SplitTreeTests {
    let window = LayoutRect(x: 14, y: 14, width: 1000, height: 600)
    let p = (1...9).map { PaneID($0) }

    /// 1 | 2 over 3: one pane on the left, two stacked on the right.
    var lShape: SplitTree {
        SplitTree.pane(p[0]).splitting(p[0], .sideBySide, newPane: p[1]).splitting(p[1], .stacked, newPane: p[2])
    }

    @Test func splittingPutsTheNewPaneAfter() {
        #expect(lShape.panes == [p[0], p[1], p[2]])
        #expect(
            lShape
                == .split(.sideBySide, ratio: 0.5, .pane(p[0]), .split(.stacked, ratio: 0.5, .pane(p[1]), .pane(p[2]))))
    }

    @Test func removingGivesTheSiblingTheSpace() {
        #expect(lShape.removing(p[1]) == .split(.sideBySide, ratio: 0.5, .pane(p[0]), .pane(p[2])))
        #expect(lShape.removing(p[0]) == .split(.stacked, ratio: 0.5, .pane(p[1]), .pane(p[2])))
        #expect(SplitTree.pane(p[0]).removing(p[0]) == nil)
        #expect(lShape.removing(p[8]) == lShape)
    }

    @Test func framesLeaveTheGapsBetweenPanes() {
        let frames = lShape.frames(in: window, gap: 12)
        #expect(frames[p[0]] == LayoutRect(x: 14, y: 14, width: 494, height: 600))
        #expect(frames[p[1]] == LayoutRect(x: 520, y: 14, width: 494, height: 294))
        #expect(frames[p[2]] == LayoutRect(x: 520, y: 320, width: 494, height: 294))
    }

    /// Random splits and closes: every pane appears once, frames stay inside the window,
    /// never overlap, and sit on whole device pixels.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func randomTreesTileTheWindow(_ seed: UInt64) {
        var random = SeededRandom(seed)
        var tree = SplitTree.pane(PaneID(0))
        var next = 1
        for _ in 0..<40 {
            let panes = tree.panes
            let target = panes[Int(random.next() % UInt64(panes.count))]
            if panes.count > 1 && random.next() % 3 == 0 {
                tree = tree.removing(target)!
            } else {
                tree = tree.splitting(target, random.next() % 2 == 0 ? .sideBySide : .stacked, newPane: PaneID(next))
                next += 1
            }
            #expect(Set(tree.panes).count == tree.panes.count)
            let frames = tree.frames(in: window, gap: 12, scale: 2)
            #expect(frames.count == tree.panes.count)
            let rects = Array(frames.values)
            for (i, a) in rects.enumerated() {
                #expect(
                    a.minX >= window.minX && a.maxX <= window.maxX && a.minY >= window.minY && a.maxY <= window.maxY)
                for value in [a.x, a.y, a.width, a.height] { #expect((value * 2).rounded() == value * 2) }
                for b in rects[(i + 1)...] {
                    let overlaps = a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
                    #expect(!overlaps)
                }
            }
        }
    }

    @Test func dividersSitInTheGaps() {
        let dividers = lShape.dividers(in: window, gap: 12)
        #expect(dividers.count == 2)
        #expect(dividers[0].path == [])
        #expect(dividers[0].axis == .sideBySide)
        #expect(dividers[0].rect == LayoutRect(x: 508, y: 14, width: 12, height: 600))
        #expect(dividers[1].path == [.second])
        #expect(dividers[1].rect == LayoutRect(x: 520, y: 308, width: 494, height: 12))
    }

    @Test func draggingADividerKeepsBothSidesUsable() {
        let minimum = (width: 100.0, height: 60.0)
        let moved = lShape.movingDivider(at: [], to: 300, in: window, gap: 12, minimum: minimum)
        #expect(moved.frames(in: window, gap: 12)[p[0]]?.width == 300)
        let tooFar = lShape.movingDivider(at: [], to: 990, in: window, gap: 12, minimum: minimum)
        #expect(tooFar.frames(in: window, gap: 12)[p[1]]?.width == 100)
        let nested = lShape.movingDivider(at: [.second], to: 10, in: window, gap: 12, minimum: minimum)
        #expect(nested.frames(in: window, gap: 12)[p[1]]?.height == 60)
    }

    @Test func arrowsMoveTheNearestDividerAlongTheirAxis() {
        let minimum = (width: 100.0, height: 60.0)
        let wider = lShape.resizing(p[0], toward: .right, by: 50, in: window, gap: 12, minimum: minimum)
        #expect(wider.frames(in: window, gap: 12)[p[0]]?.width == 544)
        // Pane 2 sits in the second side of the outer split: right moves that divider too,
        // so pane 2 gets narrower.
        let narrower = lShape.resizing(p[1], toward: .right, by: 50, in: window, gap: 12, minimum: minimum)
        #expect(narrower.frames(in: window, gap: 12)[p[1]]?.width == 444)
        let taller = lShape.resizing(p[1], toward: .down, by: 20, in: window, gap: 12, minimum: minimum)
        #expect(taller.frames(in: window, gap: 12)[p[1]]?.height == 314)
        // Pane 1 has no stacked split around it.
        #expect(lShape.resizing(p[0], toward: .up, by: 20, in: window, gap: 12, minimum: minimum) == lShape)
    }

    @Test func equalizingSharesSpaceByPaneCount() {
        // Split right twice from the first pane: 1 | (2 | 3) gets a half and two quarters.
        let three = SplitTree.pane(p[0]).splitting(p[0], .sideBySide, newPane: p[1]).splitting(
            p[1], .sideBySide, newPane: p[2])
        let space = LayoutRect(x: 0, y: 0, width: 324, height: 100)
        let frames = three.equalized(in: space, gap: 12).frames(in: space, gap: 12, scale: 1)
        #expect(frames[p[0]]?.width == 100)
        #expect(frames[p[1]]?.width == 100)
        #expect(frames[p[2]]?.width == 100)
        // A stacked pair counts as one column.
        #expect(lShape.equalized(in: window, gap: 12) == lShape)
    }

    @Test func neighborsAcrossAnLShape() {
        let tree = lShape
        #expect(tree.neighbor(of: p[0], toward: .right, in: window, gap: 12) == p[1])
        #expect(tree.neighbor(of: p[0], toward: .right, in: window, gap: 12, recent: [p[2], p[1]]) == p[2])
        #expect(tree.neighbor(of: p[2], toward: .left, in: window, gap: 12) == p[0])
        #expect(tree.neighbor(of: p[1], toward: .down, in: window, gap: 12) == p[2])
        #expect(tree.neighbor(of: p[2], toward: .up, in: window, gap: 12) == p[1])
        #expect(tree.neighbor(of: p[0], toward: .left, in: window, gap: 12) == nil)
        #expect(tree.neighbor(of: p[1], toward: .up, in: window, gap: 12) == nil)
    }

    @Test func neighborsPreferTheNearestThenTheMostOverlap() {
        // 1 | 2 over 3, with 2 short: right of 1, pane 3 overlaps it most.
        let tree = lShape.movingDivider(
            at: [.second], to: 100, in: window, gap: 12, minimum: (width: 50, height: 50))
        #expect(tree.neighbor(of: p[0], toward: .right, in: window, gap: 12) == p[2])
    }
}

/// SplitMix64, so random trees are the same on every run.
struct SeededRandom {
    private var state: UInt64

    init(_ seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
