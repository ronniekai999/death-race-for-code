import AppKit
import QuartzCore
import ScreenProtocol
import SurfaceCore

extension TerminalSurfaceView {
    /// The most matches Find keeps: the newest, since it starts at the bottom and works back.
    static let mostFindMatches = 1000

    @objc public func showFind(_ sender: Any?) {
        if findBar == nil {
            let bar = TerminalFindBar()
            bar.onChange = { [weak self] query in
                self?.searchText = query; self?.refreshFind()
            }
            bar.onStep = { [weak self] older in self?.stepFind(older: older) }
            bar.onClose = { [weak self] in self?.closeFind(nil) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
                bar.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            ])
            findBar = bar
        }
        findBar?.isHidden = false
        window?.makeFirstResponder(findBar?.field)
        refreshFind()
    }

    /// Further back, away from the newest match Find starts at; Find Previous comes forward.
    @objc public func findNext(_ sender: Any?) { stepFind(older: true) }
    @objc public func findPrevious(_ sender: Any?) { stepFind(older: false) }

    @objc public func closeFind(_ sender: Any?) {
        findTask?.cancel()
        findTask = nil
        findBar?.isHidden = true
        searchMatches = []
        updateSearchHighlights()
        window?.makeFirstResponder(self)
    }

    func refreshFind() {
        findTask?.cancel()
        findTask = nil
        searchMatches = []
        searchIndex = 0
        updateSearchHighlights()
        guard !searchText.isEmpty, let session, let mirror = model?.mirror, let generation = mirror.generation else {
            findBar?.count.stringValue = ""
            return
        }
        guard searchText.utf16.count <= SearchQuery.longestNeedle else {
            findBar?.count.stringValue = "Search is too long"
            return
        }
        let text = searchText
        let lastLine = mirror.viewportTopLine + UInt64(mirror.viewportOffset + max(0, mirror.rows - 1))
        findBar?.count.stringValue = "Searching…"
        findTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            var query = SearchQuery(text, endLine: lastLine)
            // Oldest first, as the pages come; only the newest are kept, so the ones Find
            // starts at are there however many the history holds.
            let most = Self.mostFindMatches
            var matches: [TextRegion] = []
            var total = 0
            // A page resumes at the first match the last one left out, so only the page
            // before can have reported a match again.
            var previous: Set<TextRegion> = []
            repeat {
                guard !Task.isCancelled else { return }
                guard let page = await session.search(query, generation: generation),
                    page.generation == generation
                else {
                    guard !Task.isCancelled, let self else { return }
                    self.findBar?.count.stringValue = "Search unavailable"
                    self.findTask = nil
                    return
                }
                for match in page.matches where !previous.contains(match) {
                    matches.append(match)
                    total += 1
                }
                previous = Set(page.matches)
                if matches.count >= 2 * most { matches.removeFirst(matches.count - most) }
                query.startLine = page.nextLine
                query.startColumn = page.nextColumn
                await Task.yield()
            } while query.startLine != nil
            if matches.count > most { matches.removeFirst(matches.count - most) }
            guard !Task.isCancelled, let self, self.model?.mirror.generation == generation else { return }
            self.searchMatches = matches
            self.searchGeneration = generation
            self.searchIndex = max(0, matches.count - 1)
            let kept = total > matches.count ? " (newest \(matches.count))" : ""
            self.findBar?.count.stringValue = matches.isEmpty ? "No matches" : "\(total)\(kept)"
            self.revealFindMatch()
            self.findTask = nil
        }
    }

    /// The match before the current one (`older`), or after it; past either end, round to
    /// the other.
    private func stepFind(older: Bool) {
        guard !searchMatches.isEmpty else { showFind(nil); return }
        searchIndex = (searchIndex + (older ? -1 : 1) + searchMatches.count) % searchMatches.count
        revealFindMatch()
    }

    private func revealFindMatch() {
        guard searchMatches.indices.contains(searchIndex), let mirror = model?.mirror,
            mirror.generation == searchGeneration
        else { refreshFind(); return }
        let region = searchMatches[searchIndex]
        let lines = Blocks.scroll(toPut: region.start.line, atTopOf: mirror)
        if lines != 0 { session?.scroll(by: lines) }
        updateSearchHighlights()
        redraw()
    }

    func updateSearchHighlights() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        searchHighlights.sublayers = nil
        guard let mirror = model?.mirror, mirror.generation == searchGeneration else { return }
        if searchHighlights.superlayer == nil { layer?.addSublayer(searchHighlights) }
        let geometry = CellGeometry(cell: cell, layout: grid)
        var highlights = 0
        for (index, match) in searchMatches.enumerated() {
            for row in mirror.lines.indices {
                let number = mirror.viewportTopLine + UInt64(row)
                guard let columns = match.columns(on: number, width: mirror.columns) else { continue }
                let first = max(0, columns.lowerBound)
                let last = min(mirror.columns - 1, columns.upperBound)
                guard last >= first else { continue }
                let rect = geometry.rect(column: first, row: row, cells: last - first + 1)
                let highlight = CALayer()
                highlight.backgroundColor =
                    NSColor.systemYellow.withAlphaComponent(index == searchIndex ? 0.4 : 0.18).cgColor
                highlight.frame = convertToLayer(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
                searchHighlights.addSublayer(highlight)
                highlights += 1
                if highlights >= 2048 { return }
            }
        }
    }
}

@MainActor final class TerminalFindBar: NSVisualEffectView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let count = NSTextField(labelWithString: "")
    var onChange: ((String) -> Void)?
    /// To an older match (true) or a newer one.
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 8
        field.placeholderString = "Find in terminal history"
        field.delegate = self
        field.target = self
        field.action = #selector(changed)
        field.setAccessibilityLabel("Find in terminal history")
        let previous = NSButton(title: "↑", target: self, action: #selector(olderMatch))
        previous.setAccessibilityLabel("Older match")
        let next = NSButton(title: "↓", target: self, action: #selector(newerMatch))
        next.setAccessibilityLabel("Newer match")
        let close = NSButton(title: "×", target: self, action: #selector(closeBar))
        close.setAccessibilityLabel("Close find")
        let stack = NSStackView(views: [field, count, previous, next, close])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("created in code") }
    func controlTextDidChange(_ notification: Notification) { onChange?(field.stringValue) }
    @objc private func changed() { onChange?(field.stringValue) }
    @objc private func olderMatch() { onStep?(true) }
    @objc private func newerMatch() { onStep?(false) }
    @objc private func closeBar() { onClose?() }
    /// Return goes on back through history, as ⌘G does; ⇧Return comes forward.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
            return true
        }
        return false
    }
}
