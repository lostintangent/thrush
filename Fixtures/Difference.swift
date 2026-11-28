/// One way Thrush's checkpoint differs from the reference's, with both values as text.
package struct Difference: Codable, Equatable, Sendable, CustomStringConvertible {
    package var checkpoint: String
    package var path: String
    package var reference: String
    package var thrush: String

    package init(checkpoint: String, path: String, reference: String, thrush: String) {
        self.checkpoint = checkpoint
        self.path = path
        self.reference = reference
        self.thrush = thrush
    }

    package var description: String { "\(path): reference \(reference), Thrush \(thrush)" }
}

extension Checkpoint {
    /// Every observable difference from the reference's checkpoint, most fundamental first.
    ///
    /// Grids report at most one cell per row, the first that differs, so one shifted row reads as one difference.
    package func differences(from reference: Checkpoint) -> [Difference] {
        var result: [Difference] = []
        func compare(_ path: String, _ expected: String, _ actual: String) {
            if expected != actual {
                result.append(Difference(checkpoint: reference.name, path: path, reference: expected, thrush: actual))
            }
        }
        if let error = reference.error { compare("error", error, "none") }
        compare("size", "\(reference.size[0])×\(reference.size[1])", "\(size[0])×\(size[1])")
        compare("buffer", reference.buffer, buffer)
        for (name, expected, actual) in fields(reference.cursor, cursor) { compare("cursor.\(name)", expected, actual) }
        for (name, expected, actual) in fields(reference.modes, modes) { compare("modes.\(name)", expected, actual) }
        compare("title", reference.title.debugDescription, title.debugDescription)
        compare("replies", Self.printable(reference.replies ?? ""), Self.printable(replies ?? ""))
        result += Self.differences(in: "active", reference.active, active, checkpoint: reference.name)
        if let expected = reference.normal {
            result += Self.differences(in: "normal", expected, normal ?? Screen(history: [], visible: []),
                                       checkpoint: reference.name)
        }
        let expectedLinks = reference.links ?? [], actualLinks = links ?? []
        for index in 0..<max(expectedLinks.count, actualLinks.count) {
            func target(_ links: [String]) -> String { index < links.count ? links[index].debugDescription : "none" }
            compare("links[\(index + 1)]", target(expectedLinks), target(actualLinks))
        }
        // The reference draws every cell as it holds it, so a misdrawn cell differs from what it shows.
        if let misdrawn {
            result.append(Difference(checkpoint: reference.name, path: "drawn[\(misdrawn.row)][\(misdrawn.column)]",
                                     reference: Self.describe(misdrawn.holds), thrush: Self.describe(misdrawn.shows)))
        }
        return result
    }

    private static func differences(in path: String, _ reference: Screen, _ thrush: Screen, checkpoint: String) -> [Difference] {
        var result: [Difference] = []
        func lines(_ part: String, _ expected: [Line], _ actual: [Line]) {
            if expected.count != actual.count {
                result.append(Difference(checkpoint: checkpoint, path: "\(path).\(part).count",
                                         reference: "\(expected.count)", thrush: "\(actual.count)"))
            }
            // Align from the newest row so one missing history row reports once instead of shifting every line.
            let offset = part == "history" ? max(0, actual.count - expected.count) : 0
            for (row, line) in expected.enumerated() where row + offset < actual.count {
                let other = actual[row + offset]
                if line.wrapped != other.wrapped {
                    result.append(Difference(checkpoint: checkpoint, path: "\(path).\(part)[\(row)].wrapped",
                                             reference: "\(line.wrapped)", thrush: "\(other.wrapped)"))
                }
                if let column = (0..<max(line.cells.count, other.cells.count)).first(where: { line[$0] != other[$0] }) {
                    result.append(Difference(checkpoint: checkpoint, path: "\(path).\(part)[\(row)][\(column)]",
                                             reference: describe(line[column]), thrush: describe(other[column])))
                }
            }
        }
        if let history = reference.history { lines("history", history, thrush.history ?? []) }
        lines("visible", reference.visible, thrush.visible)
        return result
    }

    private static func describe(_ cell: Cell) -> String {
        if cell == .blank { return "blank" }
        var text = cell.text.isEmpty ? "empty" : cell.text.debugDescription
        if cell.width != 1 { text += " width \(cell.width)" }
        if !cell.style.isEmpty { text += " {\(cell.style)}" }
        return text
    }
}

private func fields<Value>(_ expected: Value, _ actual: Value) -> [(String, String, String)] {
    zip(Mirror(reflecting: expected).children, Mirror(reflecting: actual).children).map { expected, actual in
        (expected.label ?? "", "\(expected.value)", "\(actual.value)")
    }
}

extension Checkpoint {
    /// Bytes as tokens separated by spaces, with controls named the way terminal manuals write them,
    /// such as `thrush$ ESC[1P ESC]2;title BEL`. Text decodes as UTF-8, and malformed bytes show in hex.
    package static func printable(_ bytes: [UInt8]) -> String {
        let names: [UInt8: String] = [
            0x00: "NUL", 0x07: "BEL", 0x08: "BS", 0x09: "HT", 0x0a: "LF", 0x0b: "VT", 0x0c: "FF", 0x0d: "CR",
            0x0e: "SO", 0x0f: "SI", 0x18: "CAN", 0x1a: "SUB", 0x1b: "ESC", 0x7f: "DEL",
        ]
        enum State { case text, escape, control, string, stringEscape }
        var tokens: [String] = []
        var token = ""
        var state = State.text
        func finish() {
            if !token.isEmpty { tokens.append(token) }
            token = ""
            state = .text
        }
        for unit in units(bytes) {
            let byte: UInt8? = if case .scalar(let scalar) = unit, scalar.isASCII { UInt8(scalar.value) } else { nil }
            let name = switch unit {
            case .scalar(let scalar) where scalar.isASCII:
                names[UInt8(scalar.value)] ?? (scalar.value < 0x20 ? hex(scalar.value) : String(scalar))
            case .scalar(let scalar) where (0x80..<0xa0).contains(scalar.value): "U+" + hex(scalar.value).dropFirst(2)
            case .scalar(let scalar): String(scalar)
            case .malformed(let byte): hex(UInt32(byte))
            }
            switch state {
            case .escape:
                token += name
                if byte == UInt8(ascii: "[") { state = .control }
                else if let byte, "]P_^X".utf8.contains(byte) { state = .string }
                else if !(byte.map { (0x20...0x2f).contains($0) } ?? false) { finish() }
            case .control where byte == 0x1b:
                finish()
                token = "ESC"
                state = .escape
            case .control:
                if let byte, byte < 0x20 { token += " \(name) " }
                else { token += name }
                if let byte, (0x40...0x7e).contains(byte) || byte == 0x18 || byte == 0x1a { finish() }
            case .string, .stringEscape:
                if byte == 0x07 || (state == .stringEscape && byte == UInt8(ascii: "\\")) {
                    token += byte == 0x07 ? " BEL" : "\\"
                    finish()
                } else if byte == 0x1b {
                    token += " ESC"
                    state = .stringEscape
                } else {
                    token += name
                    state = .string
                }
            case .text:
                if byte == 0x1b {
                    finish()
                    token = "ESC"
                    state = .escape
                } else if let byte, byte < 0x20 || byte == 0x7f {
                    finish()
                    tokens.append(name)
                } else if case .malformed = unit {
                    finish()
                    tokens.append(name)
                } else {
                    token += name
                }
            }
        }
        finish()
        return tokens.joined(separator: " ")
    }

    package static func printable(_ replies: String) -> String {
        replies.isEmpty ? "none" : printable(replies.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    private static func hex(_ value: UInt32) -> String { "0x" + String(value, radix: 16, uppercase: true) }

    private enum Unit {
        case scalar(Unicode.Scalar)
        case malformed(UInt8)
    }

    /// Decoded scalars, or the single bytes that don't begin a valid UTF-8 sequence.
    private static func units(_ bytes: [UInt8]) -> [Unit] {
        var result: [Unit] = []
        var index = 0
        while index < bytes.count {
            var parser = Unicode.UTF8.ForwardParser()
            var iterator = bytes[index...].makeIterator()
            if case .valid(let encoded) = parser.parseScalar(from: &iterator) {
                result.append(.scalar(Unicode.UTF8.decode(encoded)))
                index += encoded.count
            } else {
                result.append(.malformed(bytes[index]))
                index += 1
            }
        }
        return result
    }

    /// The visible grid as text, one row per line, with each wide character in its two columns.
    package var grid: [String] {
        let columns = size[0]
        return active.visible.map { line in
            var text = ""
            for column in 0..<columns {
                let cell = line[column]
                if cell.width == 0 && column > 0 && line[column - 1].width == 2 { continue }
                text += cell.text.isEmpty ? " " : cell.text
            }
            return text
        }
    }
}
