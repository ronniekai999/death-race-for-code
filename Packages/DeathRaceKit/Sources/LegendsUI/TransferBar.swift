import SwiftUI

/// A read-only progress bar in the brand gradient — one Maze transfer's share of the way done.
/// The fill is `NeonSlider`'s, without the knob or the drag.
public struct TransferBar: View {
    @Environment(\.legends) private var palette
    private let fraction: Double

    public init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surfaceHover)
                Capsule().fill(palette.horizontalGradient).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Transferred")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
