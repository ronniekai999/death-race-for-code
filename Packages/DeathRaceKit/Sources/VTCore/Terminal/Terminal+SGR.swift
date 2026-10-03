extension Terminal {
    /// SGR: sets the pen. An empty SGR is a reset.
    func selectGraphicRendition(_ p: Params) {
        let s = screen
        var pen = s.cursor.pen
        if p.isEmpty {
            s.cursor.pen = .default
            return
        }
        var i = 0
        while i < p.count {
            let groupEnd = p.endOfGroup(startingAt: i)
            let code = p[i]
            switch code {
            case 0: pen = .default
            case 1: pen.attributes.insert(.bold)
            case 2: pen.attributes.insert(.faint)
            case 3: pen.attributes.insert(.italic)
            case 4:
                if p.colonFollows(i) {
                    // 4:0 none, 4:1 single, 4:2 double, 4:3 curly, 4:4 dotted, 4:5 dashed
                    pen.underline = UnderlineStyle(rawValue: UInt8(min(p[i + 1], 5))) ?? .single
                } else {
                    pen.underline = .single
                }
            case 5, 6: pen.attributes.insert(.blink)
            case 7: pen.attributes.insert(.inverse)
            case 8: pen.attributes.insert(.invisible)
            case 9: pen.attributes.insert(.strikethrough)
            case 21: pen.underline = .double
            case 22: pen.attributes.subtract([.bold, .faint])
            case 23: pen.attributes.remove(.italic)
            case 24: pen.underline = .none
            case 25: pen.attributes.remove(.blink)
            case 27: pen.attributes.remove(.inverse)
            case 28: pen.attributes.remove(.invisible)
            case 29: pen.attributes.remove(.strikethrough)
            case 30...37: pen.foreground = .indexed(UInt8(code - 30))
            case 38, 48, 58:
                let (color, next) = extendedColor(p, at: i, groupEnd: groupEnd)
                if let color {
                    switch code {
                    case 38: pen.foreground = color
                    case 48: pen.background = color
                    default: pen.underlineColor = color
                    }
                }
                i = next
                continue
            case 39: pen.foreground = .default
            case 40...47: pen.background = .indexed(UInt8(code - 40))
            case 49: pen.background = .default
            case 53: pen.attributes.insert(.overline)
            case 55: pen.attributes.remove(.overline)
            case 59: pen.underlineColor = .default
            case 90...97: pen.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: pen.background = .indexed(UInt8(code - 100 + 8))
            default: break
            }
            i = groupEnd
        }
        s.cursor.pen = pen
    }

    /// Parses the color after 38, 48 or 58: the color, or nil when it is malformed, and the
    /// index of the next parameter. Accepts both separators: `38;5;n` and `38;2;r;g;b` (each
    /// value its own parameter), `38:5:n`, `38:2::r:g:b` (with the colorspace slot) and
    /// `38:2:r:g:b` (without it, which many programs send). A malformed colon form skips its
    /// group; a malformed semicolon form takes the rest of the sequence with it, so its
    /// components are never read as attributes.
    private func extendedColor(_ p: Params, at i: Int, groupEnd: Int) -> (color: TerminalColor?, next: Int) {
        if p.colonFollows(i) {
            let kind = p[i + 1]
            let subs = groupEnd - i - 1  // values after 38
            switch kind {
            case 5 where subs >= 2:
                return (.indexed(UInt8(truncatingIfNeeded: p[i + 2])), groupEnd)
            case 2 where subs >= 5:
                return (.rgb(byte(p[i + 3]), byte(p[i + 4]), byte(p[i + 5])), groupEnd)
            case 2 where subs == 4:
                return (.rgb(byte(p[i + 2]), byte(p[i + 3]), byte(p[i + 4])), groupEnd)
            default:
                return (nil, groupEnd)
            }
        }
        switch p[i + 1] {
        case 5 where i + 2 < p.count:
            return (.indexed(UInt8(truncatingIfNeeded: p[i + 2])), i + 3)
        case 2 where i + 4 < p.count:
            return (.rgb(byte(p[i + 2]), byte(p[i + 3]), byte(p[i + 4])), i + 5)
        default:
            return (nil, p.count)
        }
    }

    @inline(__always)
    private func byte(_ value: UInt16) -> UInt8 {
        UInt8(min(value, 255))
    }

    /// The pen as an SGR parameter string, for DECRQSS.
    func describePen() -> String {
        let pen = screen.cursor.pen
        var parts = ["0"]
        let a = pen.attributes
        if a.contains(.bold) { parts.append("1") }
        if a.contains(.faint) { parts.append("2") }
        if a.contains(.italic) { parts.append("3") }
        switch pen.underline {
        case .none: break
        case .single: parts.append("4")
        case .double: parts.append("4:2")
        case .curly: parts.append("4:3")
        case .dotted: parts.append("4:4")
        case .dashed: parts.append("4:5")
        }
        if a.contains(.blink) { parts.append("5") }
        if a.contains(.inverse) { parts.append("7") }
        if a.contains(.invisible) { parts.append("8") }
        if a.contains(.strikethrough) { parts.append("9") }
        if a.contains(.overline) { parts.append("53") }
        parts += sgr(for: pen.foreground, base: 30, extended: 38)
        parts += sgr(for: pen.background, base: 40, extended: 48)
        if pen.underlineColor != .default { parts += sgr(for: pen.underlineColor, base: nil, extended: 58) }
        return parts.joined(separator: ";")
    }

    private func sgr(for color: TerminalColor, base: Int?, extended: Int) -> [String] {
        switch color.kind {
        case .default:
            return []
        case .indexed(let index):
            if let base, index < 8 { return ["\(base + Int(index))"] }
            if let base, index < 16 { return ["\(base + 60 + Int(index) - 8)"] }
            return ["\(extended):5:\(index)"]
        case .rgb(let r, let g, let b):
            return ["\(extended):2::\(r):\(g):\(b)"]
        }
    }
}
