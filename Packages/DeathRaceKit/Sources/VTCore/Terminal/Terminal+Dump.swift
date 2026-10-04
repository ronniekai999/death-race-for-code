extension Terminal {
    /// The screen as text: the form `vthost` prints and the recorded-session goldens hold.
    /// Each row with trailing blanks trimmed, then the cursor (and whether the whole screen is
    /// in reverse video, DECSCNM), then every run of styled cells:
    ///
    ///     (END)
    ///     ---- cursor 24;6 ----
    ///     ---- styles ----
    ///     24: 1-5 7
    ///
    /// Rows and columns count from 1, as in the cursor reports programs see. A style run is its
    /// columns and the SGR parameters of its style; runs on one row are separated by ` · `.
    /// With `scrollback`, the scrollback comes first, oldest line on top.
    public func dump(scrollback: Bool = false, styles: Bool = true) -> String {
        var out = ""
        if scrollback {
            for index in 0..<scrollbackCount { out += scrollbackRow(index).text + "\n" }
            out += "---- screen ----\n"
        }
        for y in 0..<rows { out += row(y).text + "\n" }
        let cursor = cursor
        out += "---- cursor \(cursor.y + 1);\(cursor.x + 1)\(cursor.visible ? "" : " hidden") ----\n"
        if modes.reverseVideo { out += "---- reverse video ----\n" }
        guard styles else { return out }
        var styled = ""
        for y in 0..<rows {
            let runs = row(y).styleRuns
            if !runs.isEmpty { styled += "\(y + 1): " + runs.joined(separator: " · ") + "\n" }
        }
        if !styled.isEmpty { out += "---- styles ----\n" + styled }
        return out
    }
}

extension Row {
    /// The row as text: each character once (wide ones too), empty cells as spaces, trailing
    /// blanks trimmed.
    public var text: String {
        var out = ""
        for column in 0..<columns where cells[column].width != .spacerTail {
            let scalars = scalars(at: column)
            if scalars.isEmpty {
                out.unicodeScalars.append(" ")
            } else {
                for scalar in scalars { out.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}") }
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Runs of cells with the same style other than the default: `"3-10 1;38:5:208"`.
    var styleRuns: [String] {
        var runs: [String] = []
        var start = 0
        while start < columns {
            let style = style(of: cells[start])
            var end = start + 1
            while end < columns && self.style(of: cells[end]) == style { end += 1 }
            if style != .default {
                let span = end - start == 1 ? "\(start + 1)" : "\(start + 1)-\(end)"
                runs.append(span + " " + style.sgrParameters.joined(separator: ";"))
            }
            start = end
        }
        return runs
    }
}
