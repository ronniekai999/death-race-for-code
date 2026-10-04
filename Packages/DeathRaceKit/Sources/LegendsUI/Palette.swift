import SwiftUI

/// The colors Legends components draw with, carried in the environment so a window can follow
/// the app's theme. `.midnight` is the design system's own: the static `Legends` tokens.
public struct LegendsPalette: Equatable, Sendable {
    public var ground: Color
    public var groundDeep: Color
    public var surface: Color
    public var surfaceHover: Color
    public var line: Color
    public var lineStrong: Color
    public var ink: Color
    public var inkMuted: Color
    public var inkFaint: Color
    /// The branch, links, the selected item.
    public var accent: Color
    /// Text on the gradient.
    public var onAccent: Color
    public var glow: Color
    public var warning: Color
    public var danger: Color
    /// Left to right, as the tab pills and borders run it.
    public var gradient: [Color]
    /// Righteous: the window is light.
    public var isLight: Bool

    public init(
        ground: Color, groundDeep: Color, surface: Color, surfaceHover: Color, line: Color, lineStrong: Color,
        ink: Color, inkMuted: Color, inkFaint: Color, accent: Color, onAccent: Color, glow: Color, warning: Color,
        danger: Color, gradient: [Color], isLight: Bool
    ) {
        self.ground = ground
        self.groundDeep = groundDeep
        self.surface = surface
        self.surfaceHover = surfaceHover
        self.line = line
        self.lineStrong = lineStrong
        self.ink = ink
        self.inkMuted = inkMuted
        self.inkFaint = inkFaint
        self.accent = accent
        self.onAccent = onAccent
        self.glow = glow
        self.warning = warning
        self.danger = danger
        self.gradient = gradient
        self.isLight = isLight
    }

    public static var midnight: LegendsPalette {
        LegendsPalette(
            ground: Legends.ground, groundDeep: Legends.groundDeep, surface: Legends.surface,
            surfaceHover: Legends.surfaceHover, line: Legends.line, lineStrong: Legends.lineStrong, ink: Legends.ink,
            inkMuted: Legends.inkMuted, inkFaint: Legends.inkFaint, accent: Legends.cyan, onAccent: Legends.onAccent,
            glow: Legends.glow, warning: Legends.warning, danger: Legends.danger,
            gradient: [Legends.pink, Legends.orchid, Legends.violet, Legends.periwinkle, Legends.cyan], isLight: false)
    }

    /// The gradient, left to right.
    public var horizontalGradient: LinearGradient {
        LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing)
    }

    /// The gradient from the top-left corner, as a NeonBorder runs it.
    public var borderGradient: LinearGradient {
        LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension EnvironmentValues {
    /// The palette Legends components draw with.
    @Entry public var legends: LegendsPalette = .midnight
}

/// A switch in the gradient: on, the track fills with it; off, it is outlined.
public struct NeonSwitchStyle: ToggleStyle {
    @Environment(\.legends) private var palette

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        return HStack(spacing: 8) {
            configuration.label
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(palette.horizontalGradient) : AnyShapeStyle(palette.surfaceHover))
                    .overlay(Capsule().strokeBorder(isOn ? Color.clear : palette.lineStrong, lineWidth: 1))
                Circle()
                    .fill(isOn ? palette.onAccent : palette.inkMuted)
                    .padding(4)
            }
            .frame(width: 40, height: 22)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == NeonSwitchStyle {
    /// A switch in the gradient.
    public static var neon: NeonSwitchStyle { NeonSwitchStyle() }
}

/// A slider whose filled part runs the gradient, stepping by `step`.
public struct NeonSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let onEditingChanged: (Bool) -> Void
    @State private var editing = false
    @Environment(\.legends) private var palette

    /// `onEditingChanged` hears true when a drag starts and false when it ends, as with
    /// SwiftUI's Slider.
    public init(
        value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
            / (range.upperBound - range.lowerBound)
    }

    public var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 16
            let travel: CGFloat = max(geometry.size.width - knob, 1)
            let filled: CGFloat = travel * CGFloat(fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surfaceHover).frame(height: 4)
                Capsule().fill(palette.horizontalGradient).frame(width: knob / 2 + filled, height: 4)
                Circle()
                    .fill(palette.ink)
                    .frame(width: knob, height: knob)
                    .shadow(color: palette.glow.opacity(0.4), radius: 4)
                    .offset(x: filled)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    if !editing {
                        editing = true
                        onEditingChanged(true)
                    }
                    let position = Double(min(max((drag.location.x - knob / 2) / travel, 0), 1))
                    let raw: Double = range.lowerBound + position * (range.upperBound - range.lowerBound)
                    let stepped = (raw / step).rounded() * step
                    let clamped = min(max(stepped, range.lowerBound), range.upperBound)
                    if clamped != value { value = clamped }
                }
                .onEnded { _ in
                    editing = false
                    onEditingChanged(false)
                })
        }
        .frame(height: 22)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step)
        }
    }
}
