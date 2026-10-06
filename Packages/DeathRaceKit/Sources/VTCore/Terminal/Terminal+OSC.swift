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
        case 8:
            hyperlink(rest)
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
            paletteOverrides.remove(Self.foregroundSlot)
            emit(.colorsChanged)
        case 111:
            palette.background = configuration.palette.background
            paletteOverrides.remove(Self.backgroundSlot)
            emit(.colorsChanged)
        case 112:
            palette.cursor = configuration.palette.cursor
            paletteOverrides.remove(Self.cursorSlot)
            emit(.colorsChanged)
        case 52:
            clipboard(rest)
        case 133:
            promptMark(text)
        case 633:
            vsCodeCommand(text)
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.first == "notify" {
                emit(
                    .notification(
                        title: parts.count > 1 ? String(parts[1]) : "", body: parts.count > 2 ? String(parts[2]) : ""))
            }
        default:
            break
        }
    }

    // MARK: - Hyperlinks

    /// OSC 8: `params;URI` opens a link the characters printed next belong to, and an empty
    /// URI closes it. The parameters are `key=value` pairs split by colons, of which only
    /// `id` means anything. A link past the limits, or with control characters in it, is
    /// not kept: what follows prints without one.
    private func hyperlink(_ bytes: [UInt8]) {
        currentLink = nil
        guard let separator = bytes.firstIndex(of: 0x3B) else { return }
        let uri = bytes[(separator + 1)...]
        guard !uri.isEmpty else { return }
        var id: ArraySlice<UInt8> = []
        for parameter in bytes[..<separator].split(separator: 0x3A) where parameter.starts(with: Self.idPrefix) {
            id = parameter.dropFirst(Self.idPrefix.count)
        }
        let name: [UInt8]
        if id.isEmpty {
            anonymousLinks += 1
            name = Array(":\(anonymousLinks)".utf8)
        } else {
            name = Array(id)
        }
        // The limits hold for the text as kept: decoding turns each byte that is not UTF-8 into
        // a three-byte U+FFFD, so the bytes as they came cannot be the measure.
        let link = Hyperlink(id: String(decoding: name, as: UTF8.self), uri: String(decoding: uri, as: UTF8.self))
        guard Hyperlink.isAcceptable(link) else { return }
        currentLink = link
    }

    private static let idPrefix = Array("id=".utf8)

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
                    paletteOverrides.insert(index)
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
            paletteOverrides = paletteOverrides.filter { $0 >= 256 }
        } else {
            for part in text.split(separator: ";") {
                if let index = Int(part), (0..<256).contains(index) {
                    palette.colors[index] = configuration.palette.colors[index]
                    paletteOverrides.remove(index)
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
                paletteOverrides.insert(Self.foregroundSlot + which - 10)
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
    ///
    /// `D` takes a parameter list, not a single value: the first bare number is the exit code
    /// and the rest are `key=value`. Reading only the first parameter as an `Int32`, as this
    /// did, silently dropped the exit code of every `OSC 133;D;aid=7` — iTerm2's own form —
    /// and a bare `OSC 133;D` cleared a code already on the row rather than leaving it be.
    /// Unknown keys are ignored, which is what lets us add `dur=` without breaking anyone.
    private func promptMark(_ text: String) {
        let s = screen
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        let mark: PromptMark
        var duration: UInt32?
        switch parts.first {
        case "A":
            mark = .promptStart
            // A new prompt starts: whatever command text was being held belongs to a command
            // whose `D` never came, and holding it would put it on the *next* command instead.
            pendingCommandText = nil
        case "B": mark = .commandStart
        case "C": mark = .outputStart
        case "D":
            var code: Int32?
            for parameter in parts.dropFirst() {
                guard let equals = parameter.firstIndex(of: "=") else {
                    // The first bare parameter is the exit code; later ones are not.
                    if code == nil { code = Int32(parameter) }
                    continue
                }
                let key = parameter[..<equals]
                let value = parameter[parameter.index(after: equals)...]
                if key == "dur" { duration = UInt32(value) }
            }
            mark = .commandEnd(exitCode: code)
        default: return
        }
        let row = s.active[s.cursor.y]
        switch mark {
        case .promptStart: row.promptMarks.insert(.promptStart)
        case .commandStart: row.promptMarks.insert(.commandStart)
        case .outputStart: row.promptMarks.insert(.outputStart)
        case .commandEnd(let exitCode):
            row.promptMarks.insert(.commandEnd)
            // Only what the shell actually said. A `D` with no exit code is a shell that does
            // not report one, not a shell saying the last one was wrong.
            var record = row.command ?? CommandRecord()
            if let exitCode { record.exitCode = exitCode }
            if let duration { record.durationMilliseconds = duration }
            if let pending = pendingCommandText {
                record.text = pending
                pendingCommandText = nil
            }
            row.command = record.isEmpty ? nil : record
        }
        s.touch(row)
        emit(.promptMark(mark, rowID: row.id))
    }

    /// OSC 633 (Visual Studio Code's shell integration): only `E;<command line>`, which is the
    /// one thing OSC 133 has no room for — the text of the command itself.
    ///
    /// Adopting VS Code's sequence rather than inventing one means a shell already set up for
    /// its terminal reports its command lines to ours. The text is held rather than written to
    /// a row, because it arrives while the cursor is still on the prompt and belongs with the
    /// `commandEnd` that comes after the output, which is usually a different row.
    ///
    /// Split on *every* `;` and the command is the second field, because VS Code's own form is
    /// `E;<command>;<nonce>` — taking the rest of the line would have put its nonce, and the
    /// separator before it, on the end of every command it reported. Nothing is lost by it:
    /// both escapers turn a `;` inside the command into `\x3b` precisely so this can be true.
    private func vsCodeCommand(_ text: String) {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.first == "E" else { return }
        guard parts.count > 1 else {
            pendingCommandText = nil
            return
        }
        pendingCommandText = Self.unescapeVSCode(String(parts[1]))
    }

    /// VS Code escapes its command line so a `;` in it cannot end the parameter: `\xHH` for a
    /// byte, `\\` for a backslash. Anything else after a backslash is taken literally rather
    /// than dropped, so a command line is never silently mangled.
    static func unescapeVSCode(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var rest = Substring(text)
        while let slash = rest.firstIndex(of: "\\") {
            out += rest[..<slash]
            let after = rest.index(after: slash)
            guard after < rest.endIndex else {
                out.append("\\")
                return CommandRecord.cleaned(out)
            }
            switch rest[after] {
            case "\\":
                out.append("\\")
                rest = rest[rest.index(after: after)...]
            case "x", "X":
                let digits = rest.index(after: after)
                let end = rest.index(digits, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
                // `isHexDigit` on both, because `UInt8(_:radix:)` accepts a leading sign: on
                // its own, `\x+3` would have been read as the byte 3 rather than left alone.
                if rest.distance(from: digits, to: end) == 2, rest[digits..<end].allSatisfy(\.isHexDigit),
                    let byte = UInt8(rest[digits..<end], radix: 16), let scalar = Unicode.Scalar(UInt32(byte))
                {
                    out.unicodeScalars.append(scalar)
                    rest = rest[end...]
                } else {
                    out.append(rest[after])
                    rest = rest[rest.index(after: after)...]
                }
            default:
                out.append(rest[after])
                rest = rest[rest.index(after: after)...]
            }
        }
        out += rest
        return CommandRecord.cleaned(out)
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
