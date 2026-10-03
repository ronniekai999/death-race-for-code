extension Terminal {
    func controlSequence(_ csi: ControlSequence) {
        let repeating = csi.final == 0x62 && csi.privateMarker == 0 && csi.intermediates.count == 0
        defer { if !repeating { lastGraphic = nil } }

        let p = csi.params
        let s = screen
        switch (csi.privateMarker, csi.intermediates.count, csi.final) {
        // MARK: Cursor movement
        case (0, 0, 0x41): cursorUp(Int(p.value(at: 0, default: 1)))  // CUU
        case (0, 0, 0x42), (0, 0, 0x65): cursorDown(Int(p.value(at: 0, default: 1)))  // CUD, VPR
        case (0, 0, 0x43), (0, 0, 0x61): cursorForward(Int(p.value(at: 0, default: 1)))  // CUF, HPR
        case (0, 0, 0x44): cursorBackward(Int(p.value(at: 0, default: 1)))  // CUB
        case (0, 0, 0x45):  // CNL
            cursorDown(Int(p.value(at: 0, default: 1)))
            s.cursor.x = 0
        case (0, 0, 0x46):  // CPL
            cursorUp(Int(p.value(at: 0, default: 1)))
            s.cursor.x = 0
        case (0, 0, 0x47), (0, 0, 0x60):  // CHA, HPA
            setCursorColumn(Int(p.value(at: 0, default: 1)) - 1)
        case (0, 0, 0x48), (0, 0, 0x66):  // CUP, HVP
            setCursorPosition(row: Int(p.value(at: 0, default: 1)) - 1, column: Int(p.value(at: 1, default: 1)) - 1)
        case (0, 0, 0x64):  // VPA
            setCursorPosition(row: Int(p.value(at: 0, default: 1)) - 1, column: s.cursor.x)
        case (0, 0, 0x49):  // CHT
            for _ in 0..<Int(p.value(at: 0, default: 1)) { s.cursor.x = s.nextTabStop(after: s.cursor.x) }
            s.cursor.pendingWrap = false
        case (0, 0, 0x5A):  // CBT
            for _ in 0..<Int(p.value(at: 0, default: 1)) { s.cursor.x = s.previousTabStop(before: s.cursor.x) }
            s.cursor.pendingWrap = false

        // MARK: Erasing and editing
        case (0, 0, 0x4A): eraseInDisplay(Int(p[0]), selective: false)  // ED
        case (0x3F, 0, 0x4A): eraseInDisplay(Int(p[0]), selective: true)  // DECSED
        case (0, 0, 0x4B): eraseInLine(Int(p[0]), selective: false)  // EL
        case (0x3F, 0, 0x4B): eraseInLine(Int(p[0]), selective: true)  // DECSEL
        case (0, 0, 0x58):  // ECH
            let n = Int(p.value(at: 0, default: 1))
            s.erase(row: s.cursor.y, from: s.cursor.x, to: s.cursor.x + n, fill: s.cursor.pen.erasing)
            s.cursor.pendingWrap = false
        case (0, 0, 0x40):  // ICH
            s.insertBlanks(Int(p.value(at: 0, default: 1)), row: s.cursor.y, at: s.cursor.x, fill: s.cursor.pen.erasing)
            s.cursor.pendingWrap = false
        case (0, 0, 0x50):  // DCH
            s.deleteCells(Int(p.value(at: 0, default: 1)), row: s.cursor.y, at: s.cursor.x, fill: s.cursor.pen.erasing)
            s.cursor.pendingWrap = false
        case (0, 0, 0x4C):  // IL
            if s.cursor.y >= s.scrollTop && s.cursor.y <= s.scrollBottom {
                s.insertLines(Int(p.value(at: 0, default: 1)), at: s.cursor.y, fill: s.cursor.pen.erasing)
                s.cursor.x = 0
                s.cursor.pendingWrap = false
            }
        case (0, 0, 0x4D):  // DL
            if s.cursor.y >= s.scrollTop && s.cursor.y <= s.scrollBottom {
                s.deleteLines(Int(p.value(at: 0, default: 1)), at: s.cursor.y, fill: s.cursor.pen.erasing)
                s.cursor.x = 0
                s.cursor.pendingWrap = false
            }
        case (0, 0, 0x53):  // SU
            s.scrollUp(Int(p.value(at: 0, default: 1)), fill: s.cursor.pen.erasing)
        case (0, 0, 0x54) where p.count <= 1:  // SD (five parameters would be mouse highlighting)
            s.scrollDown(Int(p.value(at: 0, default: 1)), fill: s.cursor.pen.erasing)
        case (0, 0, 0x62):  // REP
            if let character = lastGraphic {
                let times = min(Int(p.value(at: 0, default: 1)), s.columns * s.rows)
                for _ in 0..<times { printScalar(character) }
            }

        // MARK: Tabs and margins
        case (0, 0, 0x67):  // TBC
            switch p[0] {
            case 0: s.tabStops[s.cursor.x] = false
            case 3: s.tabStops = [Bool](repeating: false, count: s.columns)
            default: break
            }
        case (0, 0, 0x72):  // DECSTBM
            setScrollRegion(
                top: Int(p.value(at: 0, default: 1)) - 1,
                bottom: Int(p.value(at: 1, default: UInt16(clamping: s.rows))) - 1)
        case (0, 0, 0x73) where p.isEmpty: saveCursor()  // SCOSC
        case (0, 0, 0x75) where p.isEmpty: restoreCursor()  // SCORC

        // MARK: Modes
        case (0, 0, 0x68), (0, 0, 0x6C):  // SM, RM
            for i in 0..<p.count { _ = modes.setANSI(p[i], csi.final == 0x68) }
        case (0x3F, 0, 0x68), (0x3F, 0, 0x6C):  // DECSET, DECRST
            for i in 0..<p.count { setPrivateMode(p[i], csi.final == 0x68) }
        case (0, 1, 0x70) where csi.intermediates.isOnly(0x21):  // DECSTR
            softReset()
        case (0, 1, 0x70) where csi.intermediates.isOnly(0x24):  // DECRQM (ANSI)
            let mode = p[0]
            let state = modes.ansi(mode).map { $0 ? 1 : 2 } ?? 0
            reply("\u{1B}[\(mode);\(state)$y")
        case (0x3F, 1, 0x70) where csi.intermediates.isOnly(0x24):  // DECRQM (DEC private)
            let mode = p[0]
            reply("\u{1B}[?\(mode);\(privateModeState(mode))$y")
        case (0, 1, 0x71) where csi.intermediates.isOnly(0x20):  // DECSCUSR
            setCursorStyle(Int(p[0]))
        case (0, 1, 0x71) where csi.intermediates.isOnly(0x22):  // DECSCA
            s.cursor.protected = p[0] == 1

        // MARK: Style
        case (0, 0, 0x6D): selectGraphicRendition(p)  // SGR

        // MARK: Reports
        case (0, 0, 0x63) where p[0] == 0:  // DA1
            reply("\u{1B}[?62;22c")
        case (0x3E, 0, 0x63) where p[0] == 0:  // DA2
            reply("\u{1B}[>1;10;0c")
        case (0x3D, 0, 0x63) where p[0] == 0:  // DA3
            reply("\u{1B}P!|00000000\u{1B}\\")
        case (0, 0, 0x6E):  // DSR
            switch p[0] {
            case 5: reply("\u{1B}[0n")
            case 6:
                let row = s.cursor.y - (modes.origin ? s.scrollTop : 0) + 1
                reply("\u{1B}[\(row);\(s.cursor.x + 1)R")
            default: break
            }
        case (0x3F, 0, 0x6E) where p[0] == 6:  // DECXCPR
            let row = s.cursor.y - (modes.origin ? s.scrollTop : 0) + 1
            reply("\u{1B}[?\(row);\(s.cursor.x + 1);1R")
        case (0x3E, 0, 0x71) where p[0] == 0:  // XTVERSION
            reply("\u{1B}P>|DeathRace \(configuration.version)\u{1B}\\")
        case (0, 0, 0x74):  // XTWINOPS
            windowOperation(p)
        case (0, 1, 0x79) where csi.intermediates.isOnly(0x2A):  // DECRQCRA
            if configuration.answersChecksumRequests { checksumRectangle(p) }

        // MARK: Kitty keyboard protocol
        case (0x3F, 0, 0x75):  // query
            reply("\u{1B}[?\(kittyKeyboardFlags)u")
        case (0x3E, 0, 0x75):  // push
            pushKittyFlags(UInt8(truncatingIfNeeded: p[0]))
        case (0x3C, 0, 0x75):  // pop
            popKittyFlags(Int(p.value(at: 0, default: 1)))
        case (0x3D, 0, 0x75):  // set
            setKittyFlags(UInt8(truncatingIfNeeded: p[0]), mode: Int(p.value(at: 1, default: 1)))

        default:
            break
        }
    }

    // MARK: - Cursor movement

    func cursorUp(_ n: Int) {
        let s = screen
        let limit = s.cursor.y >= s.scrollTop ? s.scrollTop : 0
        s.cursor.y = max(limit, s.cursor.y - max(n, 1))
        s.cursor.pendingWrap = false
    }

    func cursorDown(_ n: Int) {
        let s = screen
        let limit = s.cursor.y <= s.scrollBottom ? s.scrollBottom : s.rows - 1
        s.cursor.y = min(limit, s.cursor.y + max(n, 1))
        s.cursor.pendingWrap = false
    }

    func cursorForward(_ n: Int) {
        let s = screen
        s.cursor.x = min(s.columns - 1, s.cursor.x + max(n, 1))
        s.cursor.pendingWrap = false
    }

    func cursorBackward(_ n: Int) {
        let s = screen
        s.cursor.x = max(0, s.cursor.x - max(n, 1))
        s.cursor.pendingWrap = false
    }

    func setCursorColumn(_ x: Int) {
        let s = screen
        s.cursor.x = min(max(x, 0), s.columns - 1)
        s.cursor.pendingWrap = false
    }

    /// CUP: 0-based, relative to the scroll region in origin mode and clamped to it.
    func setCursorPosition(row: Int, column: Int) {
        let s = screen
        if modes.origin {
            s.cursor.y = min(max(s.scrollTop + row, s.scrollTop), s.scrollBottom)
        } else {
            s.cursor.y = min(max(row, 0), s.rows - 1)
        }
        s.cursor.x = min(max(column, 0), s.columns - 1)
        s.cursor.pendingWrap = false
    }

    func setScrollRegion(top: Int, bottom: Int) {
        let s = screen
        let top = max(top, 0)
        let bottom = min(bottom, s.rows - 1)
        guard top < bottom else { return }
        s.scrollTop = top
        s.scrollBottom = bottom
        setCursorPosition(row: 0, column: 0)
    }

    // MARK: - Erasing

    func eraseInDisplay(_ mode: Int, selective: Bool) {
        let s = screen
        let fill = s.cursor.pen.erasing
        switch mode {
        case 0:
            s.erase(row: s.cursor.y, from: s.cursor.x, to: s.columns, fill: fill, selective: selective)
            for y in (s.cursor.y + 1)..<max(s.cursor.y + 1, s.rows) {
                s.erase(row: y, from: 0, to: s.columns, fill: fill, selective: selective)
            }
        case 1:
            for y in 0..<s.cursor.y { s.erase(row: y, from: 0, to: s.columns, fill: fill, selective: selective) }
            s.erase(row: s.cursor.y, from: 0, to: s.cursor.x + 1, fill: fill, selective: selective)
        case 2:
            for y in 0..<s.rows { s.erase(row: y, from: 0, to: s.columns, fill: fill, selective: selective) }
        case 3:
            if !selective { s.clearScrollback() }
        default:
            break
        }
        s.cursor.pendingWrap = false
    }

    func eraseInLine(_ mode: Int, selective: Bool) {
        let s = screen
        let fill = s.cursor.pen.erasing
        switch mode {
        case 0: s.erase(row: s.cursor.y, from: s.cursor.x, to: s.columns, fill: fill, selective: selective)
        case 1: s.erase(row: s.cursor.y, from: 0, to: s.cursor.x + 1, fill: fill, selective: selective)
        case 2: s.erase(row: s.cursor.y, from: 0, to: s.columns, fill: fill, selective: selective)
        default: break
        }
        s.cursor.pendingWrap = false
    }

    // MARK: - Modes

    func setPrivateMode(_ mode: UInt16, _ on: Bool) {
        switch mode {
        case 47:
            if on {
                enterAlternateScreen(saveCursor: false, clear: false)
            } else {
                leaveAlternateScreen(restoreCursor: false)
            }
        case 1047:
            if on {
                enterAlternateScreen(saveCursor: false, clear: false)
            } else {
                if isAlternateScreen { eraseInDisplay(2, selective: false) }
                leaveAlternateScreen(restoreCursor: false)
            }
        case 1048:
            if on { saveCursor() } else { restoreCursor() }
        case 1049:
            if on {
                enterAlternateScreen(saveCursor: true, clear: true)
            } else {
                leaveAlternateScreen(restoreCursor: true)
            }
        case 3:
            break  // DECCOLM: 80/132 columns is the window's business; ignored, like most terminals.
        case 6:
            modes.origin = on
            setCursorPosition(row: 0, column: 0)
        default:
            _ = modes.setDEC(mode, on)
        }
    }

    /// DECRQM answer: 1 set, 2 reset, 0 unknown.
    func privateModeState(_ mode: UInt16) -> Int {
        switch mode {
        case 47, 1047, 1049: return isAlternateScreen ? 1 : 2
        case 1048: return 2
        default: return modes.dec(mode).map { $0 ? 1 : 2 } ?? 0
        }
    }

    func setCursorStyle(_ value: Int) {
        switch value {
        case 0, 1:
            cursorShape = .block
            cursorBlinks = value == 1 ? true : nil
        case 2:
            cursorShape = .block
            cursorBlinks = false
        case 3, 4:
            cursorShape = .underline
            cursorBlinks = value == 3
        case 5, 6:
            cursorShape = .bar
            cursorBlinks = value == 5
        default:
            break
        }
    }

    // MARK: - Window operations

    /// XTWINOPS: only the reports and the title stack. Requests to move, resize or raise the
    /// window are ignored; a program does not get to rearrange the desktop.
    func windowOperation(_ p: Params) {
        let s = screen
        switch p[0] {
        case 14:
            reply("\u{1B}[4;\(s.rows * configuration.cellPixelHeight);\(s.columns * configuration.cellPixelWidth)t")
        case 16:
            reply("\u{1B}[6;\(configuration.cellPixelHeight);\(configuration.cellPixelWidth)t")
        case 18, 19:
            reply("\u{1B}[\(p[0] == 18 ? 8 : 9);\(s.rows);\(s.columns)t")
        case 22:
            if titleStack.count >= 16 { titleStack.removeFirst() }
            titleStack.append((title, iconName))
        case 23:
            if let entry = titleStack.popLast() {
                let which = p[1]
                if which == 0 || which == 2 {
                    title = entry.title
                    emit(.titleChanged(title))
                }
                if which == 0 || which == 1 {
                    iconName = entry.iconName
                    emit(.iconNameChanged(iconName))
                }
            }
        default:
            break
        }
    }

    // MARK: - Kitty keyboard protocol

    private func withKittyStack(_ body: (inout [UInt8]) -> Void) {
        if isAlternateScreen { body(&kittyFlagsAlternate) } else { body(&kittyFlagsPrimary) }
    }

    func pushKittyFlags(_ flags: UInt8) {
        withKittyStack { stack in
            if stack.count >= 16 { stack.remove(at: 1) }
            stack.append(flags & 0x1F)
        }
    }

    func popKittyFlags(_ count: Int) {
        withKittyStack { stack in
            let removable = min(count, stack.count - 1)
            if removable > 0 { stack.removeLast(removable) }
            if count > removable { stack[0] = 0 }
        }
    }

    func setKittyFlags(_ flags: UInt8, mode: Int) {
        withKittyStack { stack in
            let current = stack[stack.count - 1]
            switch mode {
            case 2: stack[stack.count - 1] = current | (flags & 0x1F)
            case 3: stack[stack.count - 1] = current & ~flags
            default: stack[stack.count - 1] = flags & 0x1F
            }
        }
    }

    // MARK: - DECRQCRA

    /// `CSI Pid ; Pp ; Pt ; Pl ; Pb ; Pr * y`: a 16-bit checksum of a rectangle, in xterm's
    /// form, which esctest reads screens through. Off unless the configuration enables it.
    func checksumRectangle(_ p: Params) {
        let s = screen
        let id = p[0]
        let originRow = modes.origin ? s.scrollTop : 0
        let top = originRow + Int(p.value(at: 2, default: 1)) - 1
        let left = Int(p.value(at: 3, default: 1)) - 1
        let bottom = min(originRow + Int(p.value(at: 4, default: UInt16(clamping: s.rows))) - 1, s.rows - 1)
        let right = min(Int(p.value(at: 5, default: UInt16(clamping: s.columns))) - 1, s.columns - 1)
        var sum: UInt32 = 0
        if top <= bottom && left <= right {
            for y in max(top, 0)...bottom {
                let row = s.active[y]
                for x in max(left, 0)...right {
                    let cell = row.cells[x]
                    if cell.width == .spacerTail { continue }
                    sum &+= cell.isEmpty ? 0x20 : cell.scalar
                }
            }
        }
        let checksum = UInt16(truncatingIfNeeded: 0 &- sum)
        let hex = String(checksum, radix: 16, uppercase: true)
        reply("\u{1B}P\(id)!~\(String(repeating: "0", count: 4 - hex.count) + hex)\u{1B}\\")
    }
}
