import AppCore
import AppKit
import ConfigKit
import LegendsUI
import SwiftUI
import TerminalUI

/// Hear Me Calling's state for its rows, and what moving and choosing do.
@MainActor
@Observable
final class HearMeCallingModel {
    private(set) var state: PaletteState
    var palette: LegendsPalette
    /// The row to bring into view after a move by the keyboard.
    private(set) var scrollTarget: String?
    @ObservationIgnored var onChoose: ((PaletteItem) -> Void)?
    /// The highlighted theme changed; nil when no theme is highlighted.
    @ObservationIgnored var onPreview: ((String?) -> Void)?
    @ObservationIgnored private var previewed: String?

    init(state: PaletteState, palette: LegendsPalette) {
        self.state = state
        self.palette = palette
    }

    func setQuery(_ text: String) {
        state.setQuery(text)
        changed()
    }

    func cycleKind(forward: Bool) {
        state.cycleKind(forward: forward)
        changed()
    }

    func move(by offset: Int) {
        state.move(by: offset)
        changed()
    }

    func choose() {
        if let item = state.selected { onChoose?(item) }
    }

    func choose(at index: Int) {
        state.select(index)
        choose()
    }

    /// A theme previews once the highlight reaches it; opening on a recent theme does not
    /// repaint the window before anything was typed.
    private func changed() {
        scrollTarget = state.selected?.id
        let theme = state.previewTheme
        guard theme != previewed else { return }
        previewed = theme
        onPreview?(theme)
    }
}

/// Hear Me Calling over a window: everything dimmed and the palette near the top. It is
/// made when it opens and released when it closes, so a closed palette costs nothing.
///
/// AppKit owns the geometry and the keys: the search field's delegate takes ↑ ↓ ⇥ ↵ and esc
/// before the field editor can. SwiftUI draws the rows and the footer.
@MainActor
final class HearMeCallingOverlay: NSView, NSTextFieldDelegate {
    let model: HearMeCallingModel
    let field = NSTextField()
    private let panel = HearMeCallingPanel()
    private let border = NeonBorderView()
    private let prompt = NSTextField(labelWithString: "❯")
    private let separator = NSView()
    private let list: NSHostingView<HearMeCallingList>
    /// Esc, a click outside the palette, or the keys going elsewhere.
    var onDismiss: (() -> Void)?
    private var dismissed = false

    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 54
    static let rowHeight: CGFloat = 40
    static let visibleRows = 8
    static let listPadding: CGFloat = 6
    static let footerHeight: CGFloat = 34
    static let placeholder = "Search actions, tabs, themes and settings"
    static let font = NSFont.systemFont(ofSize: 18, weight: .regular)
    /// The mockup's dimming: rgba(8, 4, 20, 0.55).
    static let dim = NSColor(srgbRed: 8 / 255, green: 4 / 255, blue: 20 / 255, alpha: 0.55)

    init(model: HearMeCallingModel, chrome: Chrome) {
        self.model = model
        list = NSHostingView(rootView: HearMeCallingList(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.dim.cgColor
        autoresizingMask = [.width, .height]

        panel.wantsLayer = true
        panel.layer?.cornerRadius = Chrome.cardRadius
        panel.layer?.cornerCurve = .continuous
        panel.layer?.shadowOffset = .zero
        panel.layer?.shadowRadius = Chrome.glowRadius
        addSubview(panel)

        prompt.font = .monospacedSystemFont(ofSize: 18, weight: .bold)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Hear Me Calling")
        separator.wantsLayer = true
        // The overlay places the list; its SwiftUI sizes must not fight that.
        list.sizingOptions = []
        for view in [prompt, field, separator, list, border] as [NSView] { panel.addSubview(view) }
        setChrome(chrome)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HearMeCallingOverlay is created in code")
    }

    override var isFlipped: Bool { true }

    func setChrome(_ chrome: Chrome) {
        let colors = chrome.colors
        panel.layer?.backgroundColor = colors.surface.cgColor
        panel.layer?.shadowColor = colors.glow.cgColor
        panel.layer?.shadowOpacity = Float(colors.glowOpacity)
        border.colors = colors.neon
        separator.layer?.backgroundColor = colors.line.cgColor
        prompt.textColor = colors.accent.nsColor
        field.textColor = colors.ink.nsColor
        field.placeholderAttributedString = NSAttributedString(
            string: Self.placeholder, attributes: [.foregroundColor: colors.inkFaint.nsColor, .font: Self.font])
        let palette = LegendsPalette(chrome)
        if model.palette != palette { model.palette = palette }
    }

    /// The rows the list shows: at least one, for "Nothing matches", and at most eight.
    var listHeight: CGFloat {
        let rows = min(max(model.state.results.count, 1), Self.visibleRows)
        return CGFloat(rows) * Self.rowHeight + Self.listPadding * 2
    }

    override func layout() {
        super.layout()
        let width = max(min(Self.width, bounds.width - 32), 200)
        let top = Chrome.titleRowHeight + 24
        let smallest = Self.fieldHeight + 1 + Self.rowHeight + Self.listPadding * 2 + Self.footerHeight
        let height = max(min(Self.fieldHeight + 1 + listHeight + Self.footerHeight, bounds.height - top - 16), smallest)
        panel.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: top, width: width, height: height)
        panel.layer?.shadowPath = CGPath(
            roundedRect: panel.bounds, cornerWidth: Chrome.cardRadius, cornerHeight: Chrome.cardRadius, transform: nil)
        border.frame = panel.bounds
        let promptSize = prompt.intrinsicContentSize
        prompt.frame = NSRect(
            x: 18, y: ((Self.fieldHeight - promptSize.height) / 2).rounded(), width: promptSize.width,
            height: promptSize.height)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(
            x: prompt.frame.maxX + 10, y: ((Self.fieldHeight - fieldHeight) / 2).rounded(),
            width: max(width - prompt.frame.maxX - 10 - 18, 0), height: fieldHeight)
        separator.frame = NSRect(x: 0, y: Self.fieldHeight, width: width, height: 1)
        list.frame = NSRect(x: 0, y: Self.fieldHeight + 1, width: width, height: max(height - Self.fieldHeight - 1, 0))
    }

    // MARK: - Keys, through the field

    func controlTextDidChange(_ notification: Notification) {
        model.setQuery(field.stringValue)
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): model.move(by: -1)
        case #selector(NSResponder.moveDown(_:)): model.move(by: 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            model.move(by: -Self.visibleRows)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            model.move(by: Self.visibleRows)
        case #selector(NSResponder.insertTab(_:)): model.cycleKind(forward: true)
        case #selector(NSResponder.insertBacktab(_:)): model.cycleKind(forward: false)
        case #selector(NSResponder.insertNewline(_:)): model.choose()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        needsLayout = true
        return true
    }

    /// The keys went elsewhere: a click on a pill, ⌘1 showing another tab.
    func controlTextDidEndEditing(_ notification: Notification) {
        dismiss()
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        onDismiss?()
    }

    /// Taken off the window without a word back, as the window closes the palette itself.
    func detach() {
        dismissed = true
        field.delegate = nil
        removeFromSuperview()
    }

    // MARK: - The mouse, outside the palette

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// The palette's own rectangle: a click on its padding is not a click outside it.
@MainActor
final class HearMeCallingPanel: NSView {
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {}
}

extension PaletteItem.Kind {
    /// The tag at the end of a row.
    var tag: String {
        switch self {
        case .action: "ACTION"
        case .place: "TAB"
        case .theme: "THEME"
        case .settings: "SETTINGS"
        }
    }
}

// MARK: - The rows, in SwiftUI

/// The matches and the footer. The overlay sizes it and owns the keys.
struct HearMeCallingList: View {
    let model: HearMeCallingModel

    var body: some View {
        // One reading of the results for the whole list, so a row never looks up an index
        // the next query no longer has.
        let state = model.state
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(state.results.indices, id: \.self) { index in
                            PaletteRow(result: state.results[index], isSelected: index == state.selection) {
                                model.choose(at: index)
                            }
                            .id(state.results[index].id)
                        }
                        if state.results.isEmpty {
                            PaletteEmptyRow(query: state.query)
                        }
                    }
                    .padding(HearMeCallingOverlay.listPadding)
                }
                .onChange(of: model.scrollTarget) { _, target in
                    if let target { proxy.scrollTo(target) }
                }
            }
            Rectangle().fill(model.palette.line).frame(height: 1)
            PaletteFooter(state: state)
                .frame(height: HearMeCallingOverlay.footerHeight)
        }
        .environment(\.legends, model.palette)
    }
}

struct PaletteRow: View {
    let result: PaletteSearch.Result
    let isSelected: Bool
    let choose: () -> Void
    @Environment(\.legends) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            PaletteGlyph(item: result.item, isSelected: isSelected)
            Text(title)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = result.item.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let shortcut = result.item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.inkMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(palette.lineStrong, lineWidth: 1))
            }
            Text(result.item.kind.tag)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(isSelected ? palette.accent : palette.inkFaint)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: HearMeCallingOverlay.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? palette.surfaceHover : hovering ? palette.surfaceHover.opacity(0.5) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(LinearGradient(colors: palette.gradient, startPoint: .top, endPoint: .bottom))
                    .frame(width: 3, height: 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    /// The title, its matched letters bold and in the ink.
    private var title: AttributedString {
        let characters = Array(result.item.title)
        let plain = isSelected ? palette.ink : palette.inkMuted
        var text = AttributedString()
        func append(_ range: Range<Int>, matched: Bool) {
            guard !range.isEmpty else { return }
            var part = AttributedString(String(characters[range]))
            part[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = Font.system(
                size: 14, weight: matched ? .bold : .regular)
            part[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = matched ? palette.ink : plain
            text.append(part)
        }
        var position = 0
        for range in result.ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
        where range.lowerBound >= position && range.upperBound <= characters.count {
            append(position..<range.lowerBound, matched: false)
            append(range, matched: true)
            position = range.upperBound
        }
        append(position..<characters.count, matched: false)
        return text
    }
}

/// A row's picture: a theme's gradient, or a symbol for what the row is.
struct PaletteGlyph: View {
    let item: PaletteItem
    let isSelected: Bool
    @Environment(\.legends) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? palette.surface : palette.surfaceHover)
            if let colors = themeColors {
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: Self.symbol(for: item))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? palette.accent : palette.inkMuted)
            }
        }
        .frame(width: 26, height: 26)
    }

    private var themeColors: [Color]? {
        guard case .theme(let id) = item.target, let theme = ThemeCatalog.theme(id: id) else { return nil }
        return theme.chrome.gradient.map(swiftUIColor)
    }

    static func symbol(for item: PaletteItem) -> String {
        switch item.target {
        case .action(let id):
            switch ActionCatalog.action(id).group {
            case .app: return "gearshape"
            case .shell: return "terminal"
            case .edit: return "pencil"
            case .view: return "eye"
            case .window: return "macwindow"
            }
        case .pane: return "rectangle.split.2x1"
        case .theme: return "paintpalette"
        case .settings(let page): return page.symbol
        }
    }
}

struct PaletteEmptyRow: View {
    let query: String
    @Environment(\.legends) private var palette

    var body: some View {
        Text("Nothing matches “\(query)”")
            .font(.system(size: 13))
            .foregroundStyle(palette.inkFaint)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: HearMeCallingOverlay.rowHeight)
    }
}

/// The kinds ⇥ steps through, the current one in the gradient, and the keys.
struct PaletteFooter: View {
    let state: PaletteState
    @Environment(\.legends) private var palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(state.kinds.indices, id: \.self) { index in
                PaletteKindChip(kind: state.kinds[index], isCurrent: state.kinds[index] == state.kind)
            }
            Spacer(minLength: 8)
            PaletteKeyHint(keys: "⇥", label: "kinds")
            PaletteKeyHint(keys: "↑↓", label: "move")
            PaletteKeyHint(keys: "↵", label: "open")
            PaletteKeyHint(keys: "esc", label: "close")
        }
        .padding(.horizontal, 12)
    }
}

struct PaletteKindChip: View {
    let kind: PaletteItem.Kind?
    let isCurrent: Bool
    @Environment(\.legends) private var palette

    var body: some View {
        Text(kind?.rawValue ?? "All")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isCurrent ? palette.onAccent : palette.inkFaint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isCurrent ? AnyShapeStyle(palette.horizontalGradient) : AnyShapeStyle(Color.clear)))
    }
}

struct PaletteKeyHint: View {
    let keys: String
    let label: String
    @Environment(\.legends) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.inkMuted)
            Text(label).font(.system(size: 11)).foregroundStyle(palette.inkFaint)
        }
        .padding(.leading, 8)
    }
}
