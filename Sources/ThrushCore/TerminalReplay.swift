// Describe a screen in the same VT bytes a program would use to draw it. The receiver
// starts with a blank terminal of the same size. This path runs only when a reader resumes.
extension Terminal {
    package func replayBytes() -> [UInt8] {
        var writer = ReplayWriter(links: screen.links)
        writer.output += "\u{1b}]2;" + title + "\u{1b}\\"
        if !programColors.isEmpty {
            var reports: [UInt8] = []
            for slot in (0...255).map(ColorSlot.indexed) + [.foreground, .background, .cursor] {
                if let color = programColors[slot] { slot.report(color, to: &reports) }
            }
            writer.output += String(decoding: reports, as: UTF8.self)
        }
        if let normal = screen.normalWhileAlternate {
            writer.draw(normal)
            writer.setStyle(.init())
            writer.output += "\u{1b}[?47h"
        }
        if !screen.isAlternate {
            writer.saveInactiveAlternate(screen.alternateSaved, size: size)
        }
        writer.draw(screen.active)
        let buffer = screen.active
        // Origin mode homes the cursor, so it comes before the cursor is placed.
        if modes.origin { writer.setOrigin(top: buffer.scrollTop) }
        let restoredSet = characterSets.active != characterSets.slots[characterSets.invoked]
        if restoredSet {
            // DECRC can restore a translation different from the invoked slot's designation.
            writer.setCharacterSets(characterSets)
            writer.restoreSaved(buffer.saved)
        }
        writer.position(row: buffer.row, column: buffer.column, in: buffer)
        if !followsText && buffer.column == size.columns {
            // A style or character-set control can leave the cursor just past the margin.
            // Paint the edge in replace mode with ASCII still active, then apply the controls.
            writer.finishGlyph(in: buffer, insert: false)
        }
        writer.setModes(modes)
        if !restoredSet { writer.setCharacterSets(characterSets) }
        writer.setStyle(style)
        if followsText {
            writer.finishGlyph(in: buffer, insert: modes.insert)
            writer.setStyle(style)
        } else {
            // An ignored SGR preserves the current style and pending wrap while ending the run of text.
            writer.output += "\u{1b}[999m"
        }
        return Array((writer.output + parser.replayPrefix).utf8) + parser.scanner.replayPrefix
    }

    private struct ReplayWriter {
        let links: Links
        var output = ""
        private var currentStyle = Style()
        private var originTop = 0
        private let escape = "\u{1b}"
        private let csi = "\u{1b}["

        mutating func restoreSaved(_ saved: SavedCursor) {
            output += escape + "8"
            let link = currentStyle.link
            currentStyle = saved.style
            currentStyle.link = link
        }

        mutating func saveInactiveAlternate(_ saved: SavedCursor, size: Size) {
            guard saved.row != 0 || saved.column != 0 || saved.style != .init() || saved.characterSet != .ascii else { return }
            output += csi + "?47h" + csi + "\(min(saved.row, size.rows - 1) + 1);\(min(saved.column, size.columns - 1) + 1)H"
            setRendition(saved.style)
            designate(saved.characterSet, slot: 0)
            output += escape + "7" + csi + "?47l"
            designate(.ascii, slot: 0)
        }

        mutating func draw(_ buffer: Buffer) {
            // A replay describes this shell. The app may also show older shells above it.
            let history = buffer.history
            let start = history.previousShellCount
            let count = history.currentShellCount
            let rows = buffer.visible
            setStyle(.init())
            output += csi + "H"
            var previous: Row?
            for index in 0..<(count + rows.count) {
                let row = index < count ? history[start + index] : rows[index - count]
                if index == 0 && row.isWrapped {
                    // The retained history can start in the middle of an evicted soft-wrapped line.
                    output += csi + "\(buffer.size.columns)Gxx" + csi + "H"
                    output += buffer.size.rows == 1 ? csi + "3J" : csi + "M"
                    output += csi + "X"
                }
                if let previous {
                    if row.isWrapped {
                        beginWrappedLine(after: previous, columns: buffer.size.columns)
                    } else {
                        setRendition(.init())
                        output += "\r\n"
                    }
                }
                draw(row, columns: buffer.size.columns)
                // A saved cursor can have scrolled into history. Save it while its row is visible.
                if index == min(buffer.saved.row, count + rows.count - 1) {
                    let saved = buffer.saved
                    setRendition(saved.style)
                    output += csi + "\(min(saved.column, buffer.size.columns - 1) + 1)G"
                    designate(saved.characterSet, slot: 0)
                    output += escape + "7"
                    designate(.ascii, slot: 0)
                }
                previous = row
            }
            if buffer.scrollTop != 0 || buffer.scrollBottom != buffer.size.rows - 1 {
                output += csi + "\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r"
            }
            let columns = buffer.size.columns
            if (0..<columns).contains(where: { buffer.tabs[$0] != $0.isMultiple(of: 8) }) {
                output += csi + "3g"
                for column in 0..<columns where buffer.tabs[column] {
                    output += csi + "\(column + 1)G" + escape + "H"
                }
            }
            position(row: buffer.row, column: buffer.column, in: buffer)
        }

        private mutating func draw(_ row: Row, columns: Int) {
            var column = 0
            while column < columns {
                let cell = row[column]
                // Shrinking the active logical line can clip one half of a wide glyph.
                // No printable VT sequence can place that glyph in the last column.
                if column + cell.width > columns { break }
                if !cell.text.isEmpty {
                    setStyle(cell.style)
                    if cell.width == 0 { output += csi + "999m" }
                    output += cell.text
                    column += max(1, cell.width)
                    continue
                }
                let start = column
                repeat { column += 1 }
                while column < columns && row[column].text.isEmpty && row[column].style == cell.style
                if cell.style != .init() {
                    setStyle(cell.style)
                    output += csi + "\(column - start)X"
                }
                if column < columns { output += csi + "\(column + 1)G" }
            }
        }

        // VT marks a row as a continuation only when printing crosses the right edge.
        // A wide glyph at an empty last column wraps without filling that column. Clear
        // the temporary glyph on the new row before writing its real contents.
        private mutating func beginWrappedLine(after row: Row, columns: Int) {
            let edge = row[columns - 1]
            if (edge.text.isEmpty && edge.width != 0) || edge.width == 2 {
                output += csi + "\(columns)G"
                setStyle(edge.style)
                output += "界"
            } else {
                let start = edge.width == 0 && edge.text.isEmpty ? columns - 2 : columns - 1
                let cell = row[start]
                output += csi + "\(start + 1)G"
                setStyle(cell.style)
                if cell.width == 0 { output += csi + "999m" }
                output += cell.text
                setRendition(.init())
                output += "x"
            }
            setRendition(.init())
            output += "\r" + csi + "2X"
        }

        mutating func setOrigin(top: Int) {
            output += csi + "?6h"
            originTop = top
        }

        mutating func position(row: Int, column: Int, in buffer: Buffer) {
            output += csi + "\(row - originTop + 1);\(min(column, buffer.size.columns - 1) + 1)H"
        }

        mutating func finishGlyph(in buffer: Buffer, insert: Bool) {
            let row = buffer.visible[buffer.row]
            guard buffer.column > 0 else { return }
            var start = buffer.column - 1
            if row[start].width == 0 && row[start].text.isEmpty && start > 0 { start -= 1 }
            let cell = row[start]
            guard !cell.text.isEmpty else { return }
            position(row: buffer.row, column: start, in: buffer)
            if insert { output += csi + "\(max(1, cell.width))P" }
            setStyle(cell.style)
            if cell.width == 0 { output += csi + "999m" }
            output += cell.text
        }

        mutating func setStyle(_ style: Style) {
            guard currentStyle != style else { return }
            setRendition(style)
            guard currentStyle.link != style.link else { return }
            currentStyle.link = style.link
            let link = links[style.link]
            output += escape + "]8;" + (link?.id.map { "id=" + $0 } ?? "") + ";" + (link?.uri ?? "") + escape + "\\"
        }

        /// Changes the rendition and keeps the open link. A receiver gives a link without an id a new
        /// number each time it opens, so a link that wraps or passes the saved cursor stays one link.
        private mutating func setRendition(_ style: Style) {
            var style = style
            style.link = currentStyle.link
            guard currentStyle != style else { return }
            currentStyle = style
            output += csi + style.renditionParameters + "m"
        }

        mutating func setModes(_ modes: Modes) {
            if modes.insert { output += csi + "4h" }
            if modes.newLine { output += csi + "20h" }
            if modes.applicationKeypad { output += escape + "=" }
            if !modes.wraparound { output += csi + "?7l" }
            if !modes.cursorVisible { output += csi + "?25l" }
            for (enabled, code) in [(modes.applicationCursorKeys, 1), (modes.cursorBlink, 12),
                                    (modes.reverseWraparound, 45), (modes.mouseTracking == .press, 1000),
                                    (modes.mouseTracking == .drag, 1002), (modes.mouseTracking == .all, 1003),
                                    (modes.sendFocus, 1004), (modes.mouseSGR, 1006),
                                    (modes.bracketedPaste, 2004), (modes.synchronizedOutput, 2026),
                                    (modes.reportAppearance, 2031)] where enabled {
                output += csi + "?\(code)h"
            }
            if let blink = modes.cursorBlinkOverride {
                output += csi + "\(CursorStyleParameter(modes.cursorShape, blinking: blink).rawValue) q"
            }
        }

        mutating func setCharacterSets(_ sets: CharacterSets) {
            for slot in 0..<4 where sets.slots[slot] != .ascii {
                designate(sets.slots[slot], slot: slot)
            }
            switch sets.invoked {
            case 1: output += "\u{0e}"
            case 2: output += escape + "n"
            case 3: output += escape + "o"
            default: break
            }
        }

        private mutating func designate(_ set: CharacterSet, slot: Int) {
            let final: String = switch set {
            case .ascii: "B"; case .lineDrawing: "0"; case .british: "A"; case .dutch: "4"
            case .finnish: "C"; case .french: "R"; case .frenchCanadian: "Q"; case .german: "K"
            case .italian: "Y"; case .norwegianDanish: "E"; case .spanish: "Z"; case .swedish: "H"; case .swiss: "="
            }
            output += escape + ["(", ")", "*", "+"][slot] + final
        }
    }
}

// A socket can detach in the middle of a control or scalar. End the repaint with an
// equivalent unfinished prefix so the next live PTY byte completes the same operation.
private extension Parser {
    var replayPrefix: String {
        if state == .ground { return "" }
        let esc = "\u{1b}"
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: collected >> $0) }.filter { $0 != 0 }
        let prefix = String(decoding: bytes.filter { $0 >= 0x3c }, as: UTF8.self)
        let intermediates = String(decoding: bytes.filter { $0 < 0x3c }, as: UTF8.self)
        switch state {
        case .escape, .escapeIntermediate: return esc + intermediates
        case .csiEntry: return esc + "["
        case .dcsEntry: return esc + "P"
        case .csiParameters, .csiIntermediate, .dcsParameters, .dcsIntermediate:
            let introducer = state == .csiParameters || state == .csiIntermediate ? "[" : "P"
            return esc + introducer + prefix + parameters.description + intermediates
        case .csiIgnore: return esc + "[1?"
        case .dcsIgnore: return esc + "P1?"
        case .oscIdentifier: return esc + "]" + (oscIdentifier < 0 ? "" : String(oscIdentifier))
        case .oscPayload:
            guard payload.isKept else { return esc + "]999;" }
            return esc + "]" + String(oscIdentifier) + ";" + payload.text
        case .invalidOSC: return esc + "]!"
        case .dcsPayload:
            // The function's intermediate and final byte start the payload read so far.
            guard payload.isKept, case .dcs(let function) = string else { return esc + "Pq" }
            let bytes = [8, 0].map { UInt8(truncatingIfNeeded: function.rawValue >> $0) }
            return esc + "P" + String(decoding: bytes, as: UTF8.self) + payload.text
        case .ignoredString: return esc + "_"
        default: return ""
        }
    }
}

private extension TextScanner {
    var replayPrefix: [UInt8] {
        guard !isComplete else { return [] }
        // Several UTF-8 prefixes can have the same accumulated bits. Choose the one
        // with the same remaining length and accepted range for the next byte.
        for (length, tag, mask): (Int, UInt8, UInt32) in [(2, 0xc0, 31), (3, 0xe0, 15), (4, 0xf0, 7)] where length > remaining {
            let consumed = length - remaining
            let leading = value >> (6 * (consumed - 1))
            guard leading <= mask else { continue }
            var bytes = [tag | UInt8(leading)]
            for i in 1..<consumed {
                bytes.append(0x80 | UInt8((value >> (6 * (consumed - i - 1))) & 63))
            }
            var check = Self()
            for byte in bytes { _ = check.decode(byte) }
            if check.remaining == remaining && check.nextRange == nextRange { return bytes }
        }
        preconditionFailure("Invalid partial UTF-8 scalar")
    }
}
