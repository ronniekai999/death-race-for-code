extension Terminal {
    // MARK: - C0 controls

    func execute(_ control: UInt8) {
        let s = screen
        switch control {
        case 0x07:  // BEL
            emit(.bell)
        case 0x08:  // BS
            let reverseWrap = modes.reverseWraparound && modes.autowrap
            if s.cursor.pendingWrap && reverseWrap {
                // As in xterm: with reverse wraparound, BS first cancels the pending wrap.
                s.cursor.pendingWrap = false
            } else if s.cursor.x > 0 {
                s.cursor.x -= 1
                s.cursor.pendingWrap = false
            } else if reverseWrap && s.cursor.y > 0 && s.active[s.cursor.y - 1].isWrapped {
                s.cursor.y -= 1
                s.cursor.x = s.columns - 1
            }
        case 0x09:  // HT
            s.cursor.x = s.nextTabStop(after: s.cursor.x)
            s.cursor.pendingWrap = false
        case 0x0A, 0x0B, 0x0C:  // LF, VT, FF
            index()
            if modes.newline { s.cursor.x = 0 }
        case 0x0D:  // CR
            s.cursor.x = 0
            s.cursor.pendingWrap = false
        case 0x0E:  // SO: G1 into GL
            s.cursor.charsets.gl = 1
        case 0x0F:  // SI: G0 into GL
            s.cursor.charsets.gl = 0
        default:
            break
        }
        lastGraphic = nil
    }

    // MARK: - ESC sequences

    func escapeDispatch(_ sequence: EscapeSequence) {
        let s = screen
        let intermediates = sequence.intermediates
        defer { lastGraphic = nil }

        if intermediates.count == 1 {
            let i = intermediates.first
            switch i {
            case 0x28, 0x29, 0x2A, 0x2B:  // ( ) * +: designate G0...G3
                let slot = Int(i - 0x28)
                switch sequence.final {
                case 0x30: s.cursor.charsets[slot] = .decSpecialGraphics
                case 0x41: s.cursor.charsets[slot] = .british
                case 0x42: s.cursor.charsets[slot] = .ascii
                default: break
                }
            case 0x23 where sequence.final == 0x38:  // ESC # 8: DECALN
                screenAlignmentTest()
            default:
                break
            }
            return
        }
        guard intermediates.count == 0 else { return }

        switch sequence.final {
        case 0x37: saveCursor()  // ESC 7: DECSC
        case 0x38: restoreCursor()  // ESC 8: DECRC
        case 0x44: index()  // ESC D: IND
        case 0x45:  // ESC E: NEL
            index()
            s.cursor.x = 0
        case 0x48: s.tabStops[s.cursor.x] = true  // ESC H: HTS
        case 0x4D: reverseIndex()  // ESC M: RI
        case 0x4E: s.cursor.charsets.singleShift = 2  // ESC N: SS2
        case 0x4F: s.cursor.charsets.singleShift = 3  // ESC O: SS3
        case 0x63: fullReset()  // ESC c: RIS
        case 0x3D: modes.applicationKeypad = true  // ESC =: DECKPAM
        case 0x3E: modes.applicationKeypad = false  // ESC >: DECKPNM
        case 0x6E: s.cursor.charsets.gl = 2  // ESC n: LS2
        case 0x6F: s.cursor.charsets.gl = 3  // ESC o: LS3
        default: break  // ESC \ (ST) and the rest
        }
    }

    // MARK: - Cursor save and restore

    func saveCursor() {
        let s = screen
        let c = s.cursor
        s.savedCursor = SavedCursor(
            x: c.x, y: c.y, pendingWrap: c.pendingWrap, pen: c.pen, protected: c.protected,
            originMode: modes.origin, charsets: c.charsets)
    }

    func restoreCursor() {
        let s = screen
        guard let saved = s.savedCursor else {
            // Nothing saved: DECRC homes the cursor and resets what DECSC would have saved.
            s.cursor.x = 0
            s.cursor.y = 0
            s.cursor.pendingWrap = false
            s.cursor.pen = .default
            s.cursor.protected = false
            s.cursor.charsets = CharsetState()
            modes.origin = false
            return
        }
        s.cursor.x = min(saved.x, s.columns - 1)
        s.cursor.y = min(saved.y, s.rows - 1)
        s.cursor.pendingWrap = saved.pendingWrap && saved.x == s.columns - 1
        s.cursor.pen = saved.pen
        s.cursor.protected = saved.protected
        s.cursor.charsets = saved.charsets
        modes.origin = saved.originMode
    }

    // MARK: - Resets

    /// RIS: everything back to power-on, except the scrollback, which belongs to the user.
    func fullReset() {
        if isAlternateScreen { leaveAlternateScreen(restoreCursor: false) }
        for s in [primary, alternate] {
            for y in 0..<s.rows { s.erase(row: y, from: 0, to: s.columns, fill: .default) }
            s.active.forEach { $0.isWrapped = false }
            s.cursor = Cursor()
            s.savedCursor = nil
            s.scrollTop = 0
            s.scrollBottom = s.rows - 1
            s.tabStops = ScreenBuffer.defaultTabStops(columns: s.columns)
        }
        modes = TerminalModes()
        palette = configuration.palette
        title = ""
        iconName = ""
        titleStack.removeAll()
        cursorShape = .block
        cursorBlinks = nil
        kittyFlagsPrimary = [0]
        kittyFlagsAlternate = [0]
        lastGraphic = nil
        emit(.colorsChanged)
        bumpGeneration()
    }

    /// DECSTR: a soft reset of modes and the cursor, leaving the screen content alone.
    func softReset() {
        let s = screen
        modes.insert = false
        modes.origin = false
        modes.autowrap = true
        modes.cursorVisible = true
        modes.applicationCursorKeys = false
        modes.applicationKeypad = false
        s.scrollTop = 0
        s.scrollBottom = s.rows - 1
        s.cursor.pen = .default
        s.cursor.protected = false
        s.cursor.charsets = CharsetState()
        s.cursor.pendingWrap = false
        s.savedCursor = SavedCursor(
            x: 0, y: 0, pendingWrap: false, pen: .default, protected: false, originMode: false, charsets: CharsetState()
        )
    }

    /// DECALN: fills the screen with E, resets the margins and homes the cursor.
    func screenAlignmentTest() {
        let s = screen
        s.scrollTop = 0
        s.scrollBottom = s.rows - 1
        for y in 0..<s.rows {
            let row = s.active[y]
            row.graphemes.removeAll()
            for x in 0..<s.columns { row.cells[x] = Cell(scalar: 0x45, styleID: 0) }
            row.isWrapped = false
            s.touch(row)
        }
        s.cursor.x = 0
        s.cursor.y = 0
        s.cursor.pendingWrap = false
        modes.origin = false
    }

    // MARK: - Alternate screen

    func enterAlternateScreen(saveCursor save: Bool, clear: Bool) {
        if save { saveCursor() }
        guard !isAlternateScreen else { return }
        let pen = primary.cursor.pen
        alternate.cursor = primary.cursor
        alternate.cursor.pen = pen
        isAlternateScreen = true
        if clear {
            for y in 0..<alternate.rows { alternate.erase(row: y, from: 0, to: alternate.columns, fill: .default) }
        }
        bumpGeneration()
    }

    func leaveAlternateScreen(restoreCursor restore: Bool) {
        guard isAlternateScreen else {
            if restore { restoreCursor() }
            return
        }
        isAlternateScreen = false
        if restore { restoreCursor() }
        bumpGeneration()
    }
}
