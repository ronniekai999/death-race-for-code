import AppCore
import AppKit
import ConfigKit
import SessionIPC
import SessionKit

extension PitLaneWindowController {
    convenience init(config: Config, host: any WindowHost, reattaching sessions: [[SessionDescription]]) {
        self.init(config: config, host: host, reattaching: sessions.map(\.count))
        var selected = model.tabs.first?.id
        for (descriptions, tab) in zip(sessions, model.tabs) {
            guard let saved = descriptions.compactMap({ SessionPlacement.decode($0.metadata)?.workspace }).first else {
                continue
            }
            var slots: [Int: PaneID] = [:]
            for (description, pane) in zip(descriptions, tab.panes) {
                if let placement = SessionPlacement.decode(description.metadata) { slots[placement.slot] = pane }
            }
            guard let tree = SplitTree.restored(saved.tree, panes: slots), Set(tree.panes) == Set(tab.panes) else {
                continue
            }
            let restored = TabModel(
                id: tab.id, tree: tree, activePane: slots[saved.activeSlot] ?? tree.panes[0],
                zoomedPane: saved.zoomedSlot.flatMap { slots[$0] })
            restoreWorkspaceTab(restored)
            if saved.selectedTab { selected = tab.id }
            if let frame = saved.frame { restoreWindowFrame(frame) }
        }
        if let selected { selectWorkspaceTab(selected) }
    }

    private func restoreWindowFrame(_ frame: SavedWindowFrame) {
        let proposed = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(proposed) }) ?? NSScreen.main
        else { return }
        let bounds = screen.visibleFrame
        let width = min(proposed.width, bounds.width)
        let height = min(proposed.height, bounds.height)
        window?.setFrame(
            NSRect(
                x: min(max(proposed.minX, bounds.minX), bounds.maxX - width),
                y: min(max(proposed.minY, bounds.minY), bounds.maxY - height), width: width, height: height),
            display: false)
    }

    var workspaceLayout: [[(id: SessionID, place: SessionPlacement)]] {
        model.tabs.enumerated().map { index, tab in
            let slots = Dictionary(uniqueKeysWithValues: tab.panes.enumerated().map { ($0.element, $0.offset) })
            let frame = window?.frame
            let saved = tab.tree.saved(slots: slots).map { tree in
                SavedWorkspace(
                    tree: tree, activeSlot: slots[tab.activePane] ?? 0,
                    zoomedSlot: tab.zoomedPane.flatMap { slots[$0] }, selectedTab: model.activeTabID == tab.id,
                    focusedWindow: window?.isKeyWindow == true,
                    frame: frame.map { SavedWindowFrame(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
            }
            return tab.panes.compactMap { id in
                guard let pane = panes[id], let session = pane.sessionID else { return nil }
                return (
                    id: session,
                    place: SessionPlacement(
                        window: 0, tab: index, slot: slots[id] ?? 0,
                        title: pane.title, workspace: saved)
                )
            }
        }
    }

    var sessionLayout: [[(id: SessionID, title: String)]] {
        model.tabs.map { tab in
            tab.panes.compactMap { id -> (id: SessionID, title: String)? in
                guard let pane = panes[id], let session = pane.sessionID else { return nil }
                return (
                    id: session,
                    title: TabLabel.text(
                        title: pane.title, program: pane.programName ?? pane.shellName, directory: pane.directory,
                        home: Self.home)
                )
            }
        }
    }

}
