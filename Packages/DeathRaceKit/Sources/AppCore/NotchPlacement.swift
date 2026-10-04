/// Where the Lucid Dreams panel rests: centred under the notch on its screen, or top-centre
/// when the screen has none, always kept inside the screen's usable area. Pure arithmetic in
/// AppKit's screen coordinates (origin bottom-left, y up), so it is tested on Linux; the
/// controller reads the screen's `visibleFrame` and notch from AppKit and calls this.
public enum NotchPlacement {
    /// The panel's resting rect.
    ///
    /// - Parameters:
    ///   - visible: the screen's usable area (its `visibleFrame`, below the menu bar).
    ///   - notchCenterX: the notch's horizontal centre, or nil on a screen without a notch.
    ///   - width: the panel's width.
    ///   - height: the panel's height.
    ///   - topInset: points to leave between the top of the usable area and the panel.
    public static func frame(
        inVisible visible: LayoutRect, notchCenterX: Double?, width: Double, height: Double, topInset: Double = 0
    ) -> LayoutRect {
        // Never wider or taller than the usable area.
        let width = min(width, visible.width)
        let height = min(height, visible.height)
        // Centre under the notch, or on the screen when there is none; then keep it on screen.
        let centerX = notchCenterX ?? (visible.minX + visible.width / 2)
        let x = min(max(centerX - width / 2, visible.minX), visible.maxX - width)
        // Hang from the top of the usable area, dropping the inset, without running off the bottom.
        let y = max(visible.maxY - topInset - height, visible.minY)
        return LayoutRect(x: x, y: y, width: width, height: height)
    }
}
