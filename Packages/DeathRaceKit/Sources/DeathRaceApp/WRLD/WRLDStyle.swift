import AppCore
import LegendsUI
import SwiftUI

/// The WRLD window's small pieces, in the theme's colors: eyebrows, chips, status dots,
/// tiles, buttons, and a layout that wraps chips onto as many lines as they need.

/// A section's label: small, wide-spaced capitals.
struct Eyebrow: View {
    let text: String
    var count: Int?
    @Environment(\.legends) private var palette

    init(_ text: String, count: Int? = nil) {
        self.text = text
        self.count = count
    }

    var body: some View {
        HStack {
            Text(text.uppercased()).tracking(2)
            Spacer(minLength: 0)
            if let count { Text(String(count)) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(palette.inkMuted)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded chip: how a host signs in, a tag. Chips about signing in take the accent.
struct ChipView: View {
    let chip: HostChip
    @Environment(\.legends) private var palette

    var body: some View {
        Text(chip.text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(chip.isKey ? palette.accent : palette.inkMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .overlay(
                Capsule().strokeBorder(chip.isKey ? palette.accent.opacity(0.5) : palette.lineStrong, lineWidth: 1))
    }
}

/// A host's dot: lit while connected, the accent when it answered its last check, faint
/// when it didn't, an outline when nothing is known.
struct StatusDotView: View {
    let dot: HostStatus.Dot
    var size: CGFloat = 8
    @Environment(\.legends) private var palette

    var body: some View {
        Group {
            switch dot {
            case .connected:
                Circle().fill(palette.accent).shadow(color: palette.accent.opacity(0.7), radius: 4)
            case .answering:
                Circle().fill(palette.accent.opacity(0.8))
            case .silent:
                Circle().fill(palette.inkFaint)
            case .unknown:
                Circle().strokeBorder(palette.lineStrong, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A rounded square holding a symbol, as on the boards.
struct Tile: View {
    let symbol: String
    @Environment(\.legends) private var palette

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.ink)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.surfaceHover))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The board's buttons: the gradient for the one that leads, an outline for the rest, and
/// text alone for the quiet ones.
struct WRLDButtonStyle: ButtonStyle {
    enum Kind {
        case primary, plain, ghost, destructive
    }

    var kind: Kind = .plain
    @Environment(\.legends) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background {
                switch kind {
                case .primary: shape.fill(palette.horizontalGradient)
                case .plain, .destructive: shape.fill(palette.surface)
                case .ghost: shape.fill(Color.clear)
                }
            }
            .overlay {
                if kind == .plain || kind == .destructive { shape.strokeBorder(palette.lineStrong, lineWidth: 1) }
            }
            .opacity(configuration.isPressed ? 0.75 : isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .primary: palette.onAccent
        case .plain: palette.ink
        case .ghost: palette.inkMuted
        case .destructive: palette.danger
        }
    }
}

extension ButtonStyle where Self == WRLDButtonStyle {
    static var wrld: WRLDButtonStyle { WRLDButtonStyle() }
    static func wrld(_ kind: WRLDButtonStyle.Kind) -> WRLDButtonStyle { WRLDButtonStyle(kind: kind) }
}

/// A field's label above it, as the inspector and the forms show them.
struct FieldLabel: View {
    let text: String
    @Environment(\.legends) private var palette

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .tracking(1.6)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(palette.inkMuted)
    }
}

/// A text field in the board's style: the deep ground, a strong line, monospaced for
/// addresses and commands. `.wrldField()` on a plain TextField.
struct WRLDFieldChrome: ViewModifier {
    var monospaced = false
    @Environment(\.legends) private var palette

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: monospaced ? .monospaced : .default))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.groundDeep))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.lineStrong, lineWidth: 1))
    }
}

extension View {
    func wrldField(monospaced: Bool = false) -> some View {
        modifier(WRLDFieldChrome(monospaced: monospaced))
    }
}

/// Lays its views out left to right, starting a new line when one is full: chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(lines.count - 1, 0))
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if needed > width, !line.indices.isEmpty {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}
