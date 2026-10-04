extension Terminal {
    /// Titles and other free text are capped; a program does not get to fill memory with them.
    static let maxTextLength = 4096

    func operatingSystemCommand(_ payload: UnsafeBufferPointer<UInt8>, terminatedByBEL: Bool) {
        lastGraphic = nil
        let bytes = Array(payload)
        let separator = bytes.firstIndex(of: 0x3B) ?? bytes.endIndex
        guard let command = Int(String(decoding: bytes[..<separator], as: UTF8.self)) else { return }
        let rest = separator < bytes.endIndex ? Array(bytes[(separator + 1)...]) : []
        let text = String(decoding: rest.prefix(Self.maxTextLength), as: UTF8.self)
        let terminator = terminatedByBEL ? "\u{07}" : "\u{1B}\\"

        switch command {
        case 0:
            title = text
            iconName = text
            emit(.titleChanged(text))
            emit(.iconNameChanged(text))
        case 1:
            iconName = text
            emit(.iconNameChanged(text))
        case 2:
            title = text
            emit(.titleChanged(text))
        case 4:
            paletteColors(text, terminator: terminator)
        case 104:
            resetPaletteColors(text)
        case 7:
            workingDirectory = text
            emit(.workingDirectoryChanged(text))
        case 9:
            if text.hasPrefix("4;") || text == "4" {
                progress(text)
            } else {
                emit(.notification(title: "", body: text))
            }
        case 10, 11, 12:
            dynamicColors(startingAt: command, text, terminator: terminator)
        case 110:
            palette.foreground = configuration.palette.foreground
            emit(.colorsChanged)
        case 111:
            palette.background = configuration.palette.background
            emit(.colorsChanged)
        case 112:
            palette.cursor = configuration.palette.cursor
            emit(.colorsChanged)
        case 52:
            clipboard(rest)
        case 133:
            promptMark(text)
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.first == "notify" {
                emit(
                    .notification(
                        title: parts.count > 1 ? String(parts[1]) : "", body: parts.count > 2 ? String(parts[2]) : ""))
            }
        default:
            break  // OSC 8 hyperlinks arrive in Phase 3; the rest is ignored.
        }
    }

    // MARK: - Colors

    /// OSC 4: `index;spec` pairs; a spec of `?` asks for the current color.
    private func paletteColors(_ text: String, terminator: String) {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        var changed = false
        var i = 0
        while i + 1 < parts.count {
            if let index = Int(parts[i]), (0..<256).contains(index) {
                let spec = parts[i + 1]
                if spec == "?" {
                    reply("\u{1B}]4;\(index);\(palette.colors[index].x11)\(terminator)")
                } else if let color = RGB(colorSpec: spec) {
                    palette.colors[index] = color
                    changed = true
                }
            }
            i += 2
        }
        if changed { emit(.colorsChanged) }
    }

    private func resetPaletteColors(_ text: String) {
        if text.isEmpty {
            palette.colors = configuration.palette.colors
        } else {
            for part in text.split(separator: ";") {
                if let index = Int(part), (0..<256).contains(index) {
                    palette.colors[index] = configuration.palette.colors[index]
                }
            }
        }
        emit(.colorsChanged)
    }

    /// OSC 10, 11, 12: foreground, background, cursor. xterm lets one OSC carry several, each
    /// spec applying to the next number: `OSC 10;fg;bg` sets 10 and 11.
    private func dynamicColors(startingAt command: Int, _ text: String, terminator: String) {
        var which = command
        var changed = false
        for spec in text.split(separator: ";", omittingEmptySubsequences: false) where which <= 12 {
            if spec == "?" {
                let color: RGB
                switch which {
                case 10: color = palette.foreground
                case 11: color = palette.background
                default: color = palette.cursor
                }
                reply("\u{1B}]\(which);\(color.x11)\(terminator)")
            } else if let color = RGB(colorSpec: spec) {
                switch which {
                case 10: palette.foreground = color
                case 11: palette.background = color
                default: palette.cursor = color
                }
                changed = true
            }
            which += 1
        }
        if changed { emit(.colorsChanged) }
    }

    // MARK: - Progress, clipboard, prompts

    /// OSC 9;4;state;percent (ConEmu, also Windows Terminal and Ghostty).
    private func progress(_ text: String) {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        let state = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let percent = parts.count > 2 ? Int(parts[2]).map { min(max($0, 0), 100) } : nil
        switch state {
        case 1: emit(.progress(.normal(percent: percent ?? 0)))
        case 2: emit(.progress(.error(percent: percent)))
        case 3: emit(.progress(.indeterminate))
        case 4: emit(.progress(.paused(percent: percent)))
        default: emit(.progress(.cleared))
        }
    }

    /// OSC 52;selection;base64. Writes go to the app; reads (`?`) are never answered, because
    /// a program that can read the clipboard can read your passwords.
    private func clipboard(_ bytes: [UInt8]) {
        guard let split = bytes.firstIndex(of: 0x3B) else { return }
        let selection = String(decoding: bytes[..<split], as: UTF8.self)
        let data = bytes[(split + 1)...]
        guard data.first != 0x3F else { return }
        guard let decoded = Base64.decode(data) else { return }
        emit(.clipboardWrite(selection: selection.isEmpty ? "c" : selection, contents: decoded))
    }

    /// OSC 133 (FinalTerm semantic prompts): A prompt, B command, C output, D;exit done.
    private func promptMark(_ text: String) {
        let s = screen
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        let mark: PromptMark
        switch parts.first {
        case "A": mark = .promptStart
        case "B": mark = .commandStart
        case "C": mark = .outputStart
        case "D": mark = .commandEnd(exitCode: parts.count > 1 ? Int32(parts[1]) : nil)
        default: return
        }
        let row = s.active[s.cursor.y]
        switch mark {
        case .promptStart: row.promptMarks.insert(.promptStart)
        case .commandStart: row.promptMarks.insert(.commandStart)
        case .outputStart: row.promptMarks.insert(.outputStart)
        case .commandEnd(let exitCode):
            row.promptMarks.insert(.commandEnd)
            row.exitCode = exitCode
        }
        s.touch(row)
        emit(.promptMark(mark, rowID: row.id))
    }

    // MARK: - DCS

    func deviceControlString(_ header: DeviceControlHeader, data: UnsafeBufferPointer<UInt8>) {
        lastGraphic = nil
        guard header.privateMarker == 0, header.intermediates.count == 1, header.final == 0x71 else { return }
        let text = String(decoding: data, as: UTF8.self)
        switch header.intermediates.first {
        case 0x24: requestStatusString(text)  // DECRQSS
        case 0x2B: requestTermcap(text)  // XTGETTCAP
        default: break
        }
    }

    /// DECRQSS: reports a setting as the sequence that would set it.
    private func requestStatusString(_ request: String) {
        let s = screen
        let answer: String?
        switch request {
        case "m": answer = "\(describePen())m"
        case " q":
            let base: Int
            switch cursorShape {
            case .block: base = 1
            case .underline: base = 3
            case .bar: base = 5
            }
            answer = "\(base + (cursorBlinks == false ? 1 : 0)) q"
        case "r": answer = "\(s.scrollTop + 1);\(s.scrollBottom + 1)r"
        case "\"q": answer = "\(s.cursor.protected ? 1 : 0)\"q"
        case "\"p": answer = "62;1\"p"
        case "*x": answer = "0*x"  // DECSACE: attribute changes run as a stream
        case "$}": answer = "0$}"  // DECSASD: writing to the main display
        case "$~": answer = "0$~"  // DECSSDT: no status line
        default: answer = nil
        }
        if let answer {
            reply("\u{1B}P1$r\(answer)\u{1B}\\")
        } else {
            reply("\u{1B}P0$r\u{1B}\\")
        }
    }

    /// XTGETTCAP: answers terminfo queries for capabilities beyond xterm-256color, so
    /// programs like Neovim and tmux discover truecolor, styled underlines and the rest.
    private func requestTermcap(_ request: String) {
        for name in request.split(separator: ";") {
            guard let decoded = Hex.decode(name) else { continue }
            let key = String(decoding: decoded, as: UTF8.self)
            if let value = Self.termcaps[key] {
                if value.isEmpty {
                    reply("\u{1B}P1+r\(name)\u{1B}\\")
                } else {
                    reply("\u{1B}P1+r\(name)=\(Hex.encode(Array(value.utf8)))\u{1B}\\")
                }
            } else {
                reply("\u{1B}P0+r\(name)\u{1B}\\")
            }
        }
    }

    /// Capabilities and their values; an empty value is a boolean capability.
    static let termcaps: [String: String] = [
        "TN": "xterm-256color",
        "name": "xterm-256color",
        "Co": "256",
        "colors": "256",
        "RGB": "8/8/8",
        "Tc": "",
        "Smulx": "\u{1B}[4:%p1%dm",
        "Setulc": "\u{1B}[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%d%;m",
        "Ss": "\u{1B}[%p1%d q",
        "Se": "\u{1B}[2 q",
        "Ms": "\u{1B}]52;%p1%s;%p2%s\u{07}",
        "Sync": "\u{1B}[?2026%?%p1%{1}%-%tl%eh%;",
        "kbs": "\u{7F}",
    ]
}

/// Hex digits as ASCII, for XTGETTCAP.
enum Hex {
    static func decode<S: StringProtocol>(_ text: S) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let hi = value(digits[i]), let lo = value(digits[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func encode(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func value(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x41...0x46: c - 0x41 + 10
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }
}

/// Standard base64, for OSC 52. Foundation-free, like the rest of the engine.
enum Base64 {
    static func decode<C: Collection>(_ input: C) -> [UInt8]? where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 3 / 4)
        var buffer: UInt32 = 0
        var bits = 0
        for c in input {
            let v: UInt32
            switch c {
            case 0x41...0x5A: v = UInt32(c - 0x41)
            case 0x61...0x7A: v = UInt32(c - 0x61 + 26)
            case 0x30...0x39: v = UInt32(c - 0x30 + 52)
            case 0x2B, 0x2D: v = 62
            case 0x2F, 0x5F: v = 63
            case 0x3D, 0x0A, 0x0D, 0x20: continue
            default: return nil
            }
            buffer = buffer << 6 | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return out
    }
}
