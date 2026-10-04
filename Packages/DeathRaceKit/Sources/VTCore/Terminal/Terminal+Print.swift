extension Terminal {
    // MARK: - Printing

    /// Printable ASCII, a whole run at a time. Each row segment gets one style lookup and a
    /// bulk write; the slow path handles charsets and insert mode.
    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        let s = screen
        if !s.cursor.charsets.isPlainASCII || modes.insert {
            for byte in bytes { printScalar(UInt32(byte)) }
            return
        }
        let protectedBits: UInt32 = s.cursor.protected ? Cell.protectedBit : 0
        let count = bytes.count
        var index = 0
        while index < count {
            if s.cursor.pendingWrap {
                if modes.autowrap {
                    wrapLine(s)
                } else {
                    s.cursor.pendingWrap = false
                }
            }
            let row = s.active[s.cursor.y]
            let x = s.cursor.x
            let n = min(s.columns - x, count - index)
            let styleID = row.styleID(for: s.cursor.pen)
            s.splitWideCharacter(in: row, at: x)
            s.splitWideCharacter(in: row, at: x + n)
            if !row.graphemes.isEmpty {
                // The cell's grapheme bit says which columns have an entry; the dictionary
                // is only touched for those.
                for column in x..<(x + n) where row.cells[column].hasGrapheme { row.graphemes[column] = nil }
            }
            row.cells.withUnsafeMutableBufferPointer { cells in
                for k in 0..<n {
                    cells[x + k] = Cell(content: UInt32(base[index + k]) | protectedBits, styleID: styleID)
                }
            }
            index += n
            if x + n >= s.columns {
                s.cursor.x = s.columns - 1
                if modes.autowrap {
                    s.cursor.pendingWrap = true
                } else if index < count {
                    // Without autowrap the rest overwrites the last column; only the final
                    // character remains.
                    row.cells[s.columns - 1] = Cell(content: UInt32(base[count - 1]) | protectedBits, styleID: styleID)
                    index = count
                }
            } else {
                s.cursor.x = x + n
            }
            s.touch(row)
        }
        lastGraphic = UInt32(base[count - 1])
    }

    /// One character, through charsets, grapheme joining, wide-character placement and
    /// insert mode.
    func printScalar(_ input: UInt32) {
        let s = screen
        var scalar = input
        if scalar >= 0x20 && scalar < 0x7F {
            let set =
                s.cursor.charsets.singleShift.map { s.cursor.charsets[$0] } ?? s.cursor.charsets[s.cursor.charsets.gl]
            s.cursor.charsets.singleShift = nil
            scalar = Self.map(scalar, through: set)
        }

        let width = CharacterWidth.of(scalar)
        if let target = joinTarget(for: scalar, width: width, in: s) {
            attach(scalar, at: target, in: s)
            return
        }
        guard width > 0 else { return }  // nothing to combine with

        if s.cursor.pendingWrap {
            if modes.autowrap {
                wrapLine(s)
            } else {
                s.cursor.pendingWrap = false
            }
        }

        if width == 2 && s.cursor.x == s.columns - 1 {
            if modes.autowrap && s.columns > 1 {
                // Too wide for the last column: leave a spacer head and wrap.
                let row = s.active[s.cursor.y]
                s.splitWideCharacter(in: row, at: s.cursor.x)
                s.clearCell(row, s.cursor.x)
                row.cells[s.cursor.x].width = .spacerHead
                s.touch(row)
                wrapLine(s)
            } else if s.columns > 1 {
                s.cursor.x = s.columns - 2
            }
        }

        let row = s.active[s.cursor.y]
        let x = s.cursor.x
        if modes.insert {
            s.insertBlanks(width, row: s.cursor.y, at: x, fill: s.cursor.pen)
        }
        let cellWidth = min(width, s.columns - x)
        s.splitWideCharacter(in: row, at: x)
        s.splitWideCharacter(in: row, at: x + cellWidth)
        let styleID = row.styleID(for: s.cursor.pen)
        if row.cells[x].hasGrapheme { row.graphemes[x] = nil }
        row.cells[x] = Cell(
            scalar: scalar, width: cellWidth == 2 ? .wide : .narrow, styleID: styleID, protected: s.cursor.protected)
        if cellWidth == 2 {
            if row.cells[x + 1].hasGrapheme { row.graphemes[x + 1] = nil }
            row.cells[x + 1] = Cell(scalar: 0, width: .spacerTail, styleID: styleID, protected: s.cursor.protected)
        }
        s.touch(row)

        if x + cellWidth >= s.columns {
            s.cursor.x = s.columns - 1
            s.cursor.pendingWrap = modes.autowrap
        } else {
            s.cursor.x = x + cellWidth
        }
        lastGraphic = scalar
    }

    // MARK: - Graphemes

    /// The cell a character joins, if it continues the character before the cursor:
    /// combining marks always; with grapheme clustering (mode 2027) also emoji modifiers,
    /// ZWJ sequences and regional-indicator pairs.
    private func joinTarget(for scalar: UInt32, width: Int, in s: ScreenBuffer) -> (y: Int, x: Int)? {
        let clustering = modes.graphemeClustering
        guard
            width == 0
                || (clustering
                    && (CharacterWidth.isRegionalIndicator(scalar)
                        || CharacterWidth.isEmojiModifier(scalar) || CharacterWidth.isExtendedPictographic(scalar)))
        else { return nil }

        let y = s.cursor.y
        let row = s.active[y]
        var x: Int
        if s.cursor.pendingWrap {
            x = s.cursor.x
        } else {
            guard s.cursor.x > 0 else { return nil }
            x = s.cursor.x - 1
        }
        if row.cells[x].width == .spacerTail && x > 0 { x -= 1 }
        let cell = row.cells[x]
        guard !cell.isEmpty, cell.width != .spacerHead else { return nil }
        if width == 0 { return (y, x) }

        let extras = cell.hasGrapheme ? row.graphemes[x] ?? [] : []
        let last = extras.last ?? cell.scalar
        if CharacterWidth.isEmojiModifier(scalar) {
            return CharacterWidth.isExtendedPictographic(cell.scalar) && extras.isEmpty ? (y, x) : nil
        }
        if CharacterWidth.isRegionalIndicator(scalar) {
            return CharacterWidth.isRegionalIndicator(cell.scalar) && extras.isEmpty ? (y, x) : nil
        }
        // Extended_Pictographic joins only after a zero-width joiner.
        return last == CharacterWidth.zeroWidthJoiner ? (y, x) : nil
    }

    private func attach(_ scalar: UInt32, at target: (y: Int, x: Int), in s: ScreenBuffer) {
        let row = s.active[target.y]
        let x = target.x
        row.graphemes[x, default: []].append(scalar)
        row.cells[x].hasGrapheme = true

        // VS16 asks for emoji presentation: a narrow base becomes two columns wide when the
        // cursor sits right after it and there is room.
        if scalar == CharacterWidth.variationSelector16 && modes.graphemeClustering
            && row.cells[x].width == .narrow && x + 1 < s.columns
            && target.y == s.cursor.y && s.cursor.x == x + 1 && !s.cursor.pendingWrap
        {
            row.cells[x].width = .wide
            s.splitWideCharacter(in: row, at: x + 2)
            if row.cells[x + 1].hasGrapheme { row.graphemes[x + 1] = nil }
            row.cells[x + 1] = Cell(scalar: 0, width: .spacerTail, styleID: row.cells[x].styleID)
            if x + 2 >= s.columns {
                s.cursor.x = s.columns - 1
                s.cursor.pendingWrap = modes.autowrap
            } else {
                s.cursor.x = x + 2
            }
        }
        s.touch(row)
    }

    // MARK: - Line feeds

    /// Moves to the start of the next line after a character filled the last column,
    /// marking the row as soft-wrapped so reflow can join it again.
    func wrapLine(_ s: ScreenBuffer) {
        let row = s.active[s.cursor.y]
        row.isWrapped = true
        s.touch(row)
        s.cursor.pendingWrap = false
        s.cursor.x = 0
        index()
    }

    /// IND / LF: down one line, scrolling the region when the cursor sits on its bottom.
    func index() {
        let s = screen
        s.cursor.pendingWrap = false
        if s.cursor.y == s.scrollBottom {
            s.scrollUp(1, fill: s.cursor.pen.erasing)
        } else if s.cursor.y < s.rows - 1 {
            s.cursor.y += 1
        }
    }

    /// RI: up one line, scrolling the region down when the cursor sits on its top.
    func reverseIndex() {
        let s = screen
        s.cursor.pendingWrap = false
        if s.cursor.y == s.scrollTop {
            s.scrollDown(1, fill: s.cursor.pen.erasing)
        } else if s.cursor.y > 0 {
            s.cursor.y -= 1
        }
    }

    // MARK: - Character sets

    static func map(_ scalar: UInt32, through charset: Charset) -> UInt32 {
        switch charset {
        case .ascii:
            return scalar
        case .british:
            return scalar == 0x23 ? 0xA3 : scalar  // # → £
        case .decSpecialGraphics:
            guard scalar >= 0x5F && scalar <= 0x7E else { return scalar }
            return decSpecialGraphics[Int(scalar - 0x5F)]
        }
    }

    /// The VT100 line-drawing set, for 0x5F...0x7E.
    private static let decSpecialGraphics: [UInt32] = [
        0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518,
        0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534,
        0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
    ]
}
