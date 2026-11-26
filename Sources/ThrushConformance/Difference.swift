/// One way Thrush's checkpoint differs from the reference's, with both values as text.
struct Difference: Codable, Equatable, Sendable, CustomStringConvertible {
    var checkpoint: String
    var path: String
    var reference: String
    var thrush: String

    var description: String { "\(path): reference \(reference), Thrush \(thrush)" }
}

extension Checkpoint {
    /// Every observable difference from the reference's checkpoint, most fundamental first.
    ///
    /// Grids report at most one cell per row, the first that differs, so one shifted row reads as one difference.
    func differences(from reference: Checkpoint) -> [Difference] {
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
        compare("replies", Self.printable(reference.replies), Self.printable(replies))
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
    static func printable(_ bytes: [UInt8]) -> String {
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

    static func printable(_ replies: String) -> String {
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
    var grid: [String] {
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

extension ConformanceCase {
    /// The differences from the reference across every checkpoint, or none when Thrush matches.
    func differences(in actual: [Checkpoint]) -> [Difference] {
        guard let expected else { return [] }
        if actual.count != expected.count {
            return [Difference(checkpoint: "end", path: "checkpoints", reference: "\(expected.count)", thrush: "\(actual.count)")]
        }
        return zip(expected, actual).flatMap { $1.differences(from: $0) }
    }

    /// A readable account of the first checkpoint that differs, with both grids side by side.
    func report(_ actual: [Checkpoint]) -> String? {
        let differences = differences(in: actual)
        guard let first = differences.first, let expected,
              let reference = expected.first(where: { $0.name == first.checkpoint }),
              let thrush = actual.first(where: { $0.name == first.checkpoint }) else { return nil }
        let input = Checkpoint.printable(self.input)
        var lines = [
            "\(name) differs from the reference at checkpoint \"\(first.checkpoint)\".",
            "Input: \(input.count > 400 ? input.prefix(400) + "…" : input[...])",
            "",
        ]
        lines += differences.filter { $0.checkpoint == first.checkpoint }.prefix(12).map { "  \($0)" }
        // Grid rows are exactly one display column per cell, so the two grids line up.
        let blank = String(repeating: " ", count: reference.size[0])
        let header = "Reference" + String(repeating: " ", count: max(0, reference.size[0] - 9))
        lines += ["", "      \(header)    Thrush"]
        for row in 0..<max(reference.grid.count, thrush.grid.count) {
            let left = reference.grid[safe: row] ?? blank, right = thrush.grid[safe: row] ?? ""
            let marker = reference.active.visible[safe: row] == thrush.active.visible[safe: row] ? " " : "≠"
            lines.append("  \(String(row).leftPadded(to: 2)) │\(left)│ \(marker) │\(right)│")
        }
        lines.append("  cursor: reference row \(reference.cursor.row), column \(reference.cursor.column) · "
                     + "Thrush row \(thrush.cursor.row), column \(thrush.cursor.column)")
        return lines.joined(separator: "\n")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
